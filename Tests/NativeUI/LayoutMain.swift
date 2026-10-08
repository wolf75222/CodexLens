import AppKit
import SwiftUI
import Foundation
import CryptoKit
import LensCore

@main struct NativeLayoutMain {
    @MainActor static func main() {
        let app=NSApplication.shared; app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await LayoutRun().run() } catch { fputs("LAYOUT_FAILED: \(error)\n",stderr);exit(1) }
            app.terminate(nil)
        }
        app.run()
    }
}
@MainActor final class LayoutRun {
    func run() async throws {
        let a=CommandLine.arguments
        func value(_ key:String)throws->String {guard let i=a.firstIndex(of:key),i+1<a.count else{throw NSError(domain:"LayoutProbe",code:1)};return a[i+1]}
        let output=URL(fileURLWithPath:try value("--output")), home=URL(fileURLWithPath:try value("--empty-home")), archive=URL(fileURLWithPath:try value("--archive"))
        for p in [output,home,archive]{try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true)}
        guard Bundle.main.bundleIdentifier == "fr.codexlens.qualityprobe",try FileManager.default.contentsOfDirectory(atPath:home.path).isEmpty else{throw NSError(domain:"LayoutProbe",code:2)}
        UserDefaults.standard.removePersistentDomain(forName:"fr.codexlens.qualityprobe")
        let store=LensStore(sourceHome:home,investigationArchive:InvestigationArchive(directory:archive));store.setNavigationScope(UUID().uuidString)
        var snapshot=LensDemoFixtures.snapshot(eventCount:24)
        let longDiff=a.contains("--long-diff")
        let rows=longDiff ? (0..<1500).map{"-let oldValue\($0) = \($0)\n+let newValue\($0) = \($0+1)\n"}.joined() : "-let oldValue = 1\n+let newValue = 2\n"
        let patch="*** Begin Patch\n*** Update File: Sources/Example.swift\n@@\n"+rows+"*** End Patch"
        let object:[String:Any]=["timestamp":"2026-10-02T00:00:01Z","type":"response_item","payload":["type":"custom_tool_call","name":"apply_patch","call_id":"layout-call","input":patch]]
        var bytes=try JSONSerialization.data(withJSONObject:object);bytes.append(10)
        let path=output.appendingPathComponent("own-recorded-patch.jsonl");try bytes.write(to:path)
        let source=SourceRef(path:path.path,length:bytes.count,line:1,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
        let call=LensEvent(id:"layout-patch",agentID:snapshot.root.id,kind:.toolCall,title:"Synthetic requested patch",toolName:"apply_patch",callID:"layout-call",environmentID:"/fixture/worktrees/alpha",source:source)
        let change=ChangeRecord(id:"layout-change",path:"/fixture/worktrees/alpha/Sources/Example.swift",environmentID:"/fixture/worktrees/alpha",agentID:snapshot.root.id,eventID:call.id,kind:.requestedPatch,evidence:"Synthetic recorded request only; no modification or complete historical file versions claimed.")
        snapshot.events.append(call);snapshot.changes.append(change);store.snapshot=snapshot;store.showSessionPicker=false;store.inspectorVisible=false;await store.waitForPresentation()
        let detail=try await store.engine.sourceDetail(for:call), selection=try RecordedChangeEvidence.select(change:change,event:call)
        let document=try RecordedChangeEvidence.documents(change:change,selection:selection,detail:detail)[0]
        let hunk=document.files[0].hunks[0],line=hunk.lines[0]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:660),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:AnyView(EmptyView()));host.sizingOptions=[];host.clipsToBounds=true;window.contentView=host;window.makeKeyAndOrderFront(nil)
        var captures:[[String:Any]]=[]
        let views:[(String,NSSize,AnyView)]=[
            ("change-context-expanded",NSSize(width:570,height:320),AnyView(RecordedChangeView(change:change,initialContextExpanded:true).environmentObject(store))),
            ("diff-expanded",NSSize(width:570,height:300),AnyView(RecordedDiffView(document:document,initialProvenanceExpanded:true,initialSelectedHunk:hunk,initialSelectedLine:line,initialLineContextExpanded:true).environmentObject(store)))
        ]
        for (name,size,view) in views {
            for dark in [false,true] {
                let theme=dark ? "dark":"light"
                window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.setContentSize(size);host.frame=NSRect(origin:.zero,size:size)
                host.rootView=AnyView(view.background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light).frame(width:size.width,height:size.height,alignment:.topLeading))
                try await Task.sleep(nanoseconds:300_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded();CATransaction.flush()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw NSError(domain:"LayoutProbe",code:3)}
                host.cacheDisplay(in:host.bounds,to:bitmap);let filename="compact-\(name)-\(Int(size.width))x\(Int(size.height))-\(theme).png"
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(filename))
                captures.append(["filename":filename,"width":host.bounds.width,"height":host.bounds.height,"requestedWidth":size.width,"requestedHeight":size.height,"theme":theme,"exactViewport":host.bounds.size==size])
                if name == "diff-expanded" {
                    let scrolls=descendants(host).compactMap{$0 as? NSScrollView}
                    if let scroll=scrolls.max(by:{($0.documentView?.bounds.height ?? 0)-$0.contentView.bounds.height < ($1.documentView?.bounds.height ?? 0)-$1.contentView.bounds.height}),let documentView=scroll.documentView {
                        let offset=max(0,documentView.bounds.height-scroll.contentView.bounds.height)
                        for _ in 0..<3 {
                            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,documentView.bounds.height-scroll.contentView.bounds.height)));scroll.reflectScrolledClipView(scroll.contentView)
                            try await Task.sleep(nanoseconds:150_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded();CATransaction.flush()
                        }
                        if let final=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                            host.cacheDisplay(in:host.bounds,to:final)
                            let filename="compact-diff-footer-after-own-scroll-570x300-\(theme).png"
                            try final.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(filename))
                            captures.append(["filename":filename,"width":host.bounds.width,"height":host.bounds.height,"theme":theme,"ownComponentScrollAPI":true,"requestedOffset":offset,"actualOffset":scroll.contentView.bounds.minY,"documentHeight":documentView.bounds.height,"viewportHeight":scroll.contentView.bounds.height])
                        }
                    }
                }
            }
        }
        let identityChecks=try await identityRegression(host:host,window:window,store:store,output:output)
        let standalone=await weakProbe(hosted:false,home:home,archive:archive,main:window)
        let hosted=await weakProbe(hosted:true,home:home,archive:archive,main:window)
        let receipt:[String:Any]=["captures":captures,"diffIdentityRegression":identityChecks,"weakLifetimeDiagnostic":["standalone":standalone,"hostAfterExplicitEmptyRootDisplay":hosted],"sourceLabel":try value("--source-label"),"longDiff":longDiff,"diffRowCount":hunk.lines.count,"modelRequests":0,"apiKeySupplied":false,"realSessionRead":false,"networkDeniedByOS":true,"context":"Real frozen components with anonymous exact recorded request. RecordedChange context and standalone RecordedDiff provenance/line context qualified separately; nested RecordedChange diff provenance is not forcibly opened.","interactionQualified":false,"voiceOverQualified":false]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("compact-layout-receipt.json"))
        window.contentView=nil;window.close();store.stopObserving()
        guard identityChecks.values.allSatisfy({$0}) else {throw NSError(domain:"LayoutProbe",code:4,userInfo:[NSLocalizedDescriptionKey:"Diff identity/menu checks failed; see compact-layout-receipt.json and native menu diagnostics."])}
        print("LAYOUT_COMPLETE \(output.path)")
    }
    func identityRegression(host:NSHostingView<AnyView>,window:NSWindow,store:LensStore,output:URL) async throws -> [String:Bool] {
        let old=try RecordedDiff.parse("--- a/State.swift\n+++ b/State.swift\n@@ -1 +1 @@\n-old text\n+new text\n",provenance:DiffProvenance(environmentID:"/fixture/alpha",beforeReference:"before-v1",afterReference:"after-v1"),kind:.recordedDiff)
        let prepared=try await Task.detached {try RecordedDiffPresentation(document:old)}.value
        let hunk=old.files[0].hunks[0],line=hunk.lines[0]
        func view(_ value:RecordedDiffPresentation,selected:Bool)->AnyView {
            let component=selected ? RecordedDiffView(document:value.document,initialSelectedHunk:hunk,initialSelectedLine:line,initialLineContextExpanded:true) : RecordedDiffView(document:value.document)
            return AnyView(component.id(value.identity).environmentObject(store).background(Color(nsColor:.windowBackgroundColor)).frame(width:1080,height:660))
        }
        func settle() async {try? await Task.sleep(nanoseconds:200_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded();CATransaction.flush()}
        // The selected footer's text-selection-enabled body exposes native
        // accessibility text even when this standalone host does not expose
        // the pure SwiftUI DisclosureGroup heading. This fixture has no author
        // evidence, so the exact fallback appears only in its selected context.
        func selectedFooter()->Bool {accessibilityLabels(host).contains(LensL10n.text("Auteur de la ligne non établi par cette observation."))}
        func menuItems(_ menu:NSMenu)->[NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
        }
        func modeMenu()->NSMenu? {
            // Recent SDKs expose SwiftUI Menu as an NSButton whose menu is
            // materialized only during native tracking, not NSPopUpButton.
            for button in descendants(host).compactMap({$0 as? NSButton}) {
                let roles=([button as Any]+accessibleChildren(button)).compactMap {($0 as? any NSAccessibilityProtocol)?.accessibilityRole()?.rawValue}
                guard roles.contains("AXMenuButton") || roles.contains("AXPopUpButton") else {continue}
                var result:NSMenu?
                let inspect:@MainActor @Sendable ()->Void = {
                        guard let menu=button.menu else {return}
                        let titles=Set(menuItems(menu).map(\.title))
                        if titles.contains(LensL10n.text("Unifié")),titles.contains(LensL10n.text("Côte à côte")) {result=menu}
                        menu.cancelTracking()
                }
                let timer=Timer(timeInterval:0.05,repeats:false) { _ in MainActor.assumeIsolated {inspect()} }
                RunLoop.main.add(timer,forMode:.eventTracking)
                button.performClick(nil);timer.invalidate()
                if let result {return result}
            }
            return nil
        }
        func selectedMode(_ sideBySide:Bool)->Bool {
            guard let menu=modeMenu(),let unified=menuItems(menu).first(where:{$0.title==LensL10n.text("Unifié")}),
                  let comparison=menuItems(menu).first(where:{$0.title==LensL10n.text("Côte à côte")}) else{return false}
            return unified.state==(sideBySide ? .off:.on) && comparison.state==(sideBySide ? .on:.off)
        }
        func chooseMode(_ sideBySide:Bool)->Bool {
            guard let menu=modeMenu(),let item=menuItems(menu).first(where:{$0.title==LensL10n.text(sideBySide ? "Côte à côte":"Unifié")}),
                  item.isEnabled,item.action != nil,let owner=item.menu else{return false}
            let index=owner.index(of:item);guard index>=0 else{return false}
            // Dispatch the production SwiftUI menu item; changing a native
            // checkmark alone would not demonstrate that the binding changed.
            owner.performActionForItem(at:index);return true
        }
        func textFrames(_ node:Any,_ text:String,depth:Int=0)->[NSRect] {
            guard depth<30,let element=node as? any NSAccessibilityProtocol else{return []}
            let exact=[element.accessibilityLabel(),element.accessibilityTitle(),element.accessibilityValue() as? String].contains(text)
            let children=accessibleChildren(node).flatMap{textFrames($0,text,depth:depth+1)}
            return (exact ? [element.accessibilityFrame()] : [])+children
        }
        func renderedMode(_ sideBySide:Bool)->Bool {
            guard let before=textFrames(host,"old text").first(where:{$0.width>0 && $0.height>0}),
                  let after=textFrames(host,"new text").first(where:{$0.width>0 && $0.height>0}) else{return false}
            let separation=abs(before.minX-after.minX)
            return sideBySide ? separation>200 : separation<20
        }
        window.setContentSize(NSSize(width:1080,height:660));host.frame=NSRect(x:0,y:0,width:1080,height:660)
        host.rootView=view(prepared,selected:true);await settle()
        let oldTexts=accessibilityLabels(host)
        try JSONSerialization.data(withJSONObject:oldTexts,options:[.prettyPrinted]).write(to:output.appendingPathComponent("identity-own-accessibility-text.json"))
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds){host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("identity-old-selected.png"))}
        let footerEstablished=selectedFooter()
        var checks=["oldSelectedFooterExposed":footerEstablished,"directSelectedFooterQualified":footerEstablished]
        let modeAvailable=modeMenu() != nil
        checks["nativeUnifiedMenuCheckedInitially"]=selectedMode(false) && renderedMode(false)
        checks["visibleDiffModeSegmentRemoved"]=descendants(host).compactMap{$0 as? NSSegmentedControl}.allSatisfy {
            ![LensL10n.text("Unifié"),LensL10n.text("Côte à côte")].contains($0.label(forSegment:0) ?? "")
        }
        let sideDispatched=chooseMode(true);await settle()
        checks["nativeSideBySideMenuActionChangesRendering"]=sideDispatched && selectedMode(true) && renderedMode(true)
        host.rootView=view(prepared,selected:false);await settle()
        checks["identicalDocumentKeepsSelectedFooter"]=selectedFooter()
        checks["nativeSideBySideControlAvailable"]=modeAvailable
        checks["identicalDocumentKeepsSideBySide"]=sideDispatched && selectedMode(true) && renderedMode(true)
        let unifiedDispatched=chooseMode(false);await settle()
        checks["nativeUnifiedMenuActionChangesRendering"]=unifiedDispatched && selectedMode(false) && renderedMode(false)
        var text=old;text.files[0].hunks[0].lines[0].text="CHANGED TEXT SAME PARSER ID"
        var before=old;before.provenance.beforeReference="before-v2"
        var after=old;after.provenance.afterReference="after-v2"
        var environment=old;environment.provenance.environmentID="/fixture/beta"
        for (name,document) in [("text",text),("before-reference",before),("after-reference",after),("environment",environment)] {
            host.rootView=view(prepared,selected:true);await settle()
            let oldDispatched=chooseMode(true);await settle()
            checks[name+"OldNativeModeEstablished"]=oldDispatched && selectedMode(true) && renderedMode(true)
            let next=try await Task.detached {try RecordedDiffPresentation(document:document)}.value
            checks[name+"InvalidatesPresentationIdentity"]=next.identity != prepared.identity
            checks[name+"KeepsParserLineID"]=document.files[0].hunks[0].lines[0].id==line.id
            host.rootView=view(next,selected:false);await settle()
            checks[name+"RemovesStaleSelectedFooter"] = footerEstablished && !selectedFooter()
            checks[name+"ResetsNativeSideBySideState"]=selectedMode(false)
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds){host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("identity-"+name+"-changed.png"))}
        }
        let diagnostics:[String:Any]=["method":"Own NSButton.performClick opens the production menu; event-tracking timer inspects/cancels only that menu, followed by its NSMenuItem action/checkmark. Rendered mode uses before/after native text frames. Selected-footer presence uses its exact native text-selection-enabled body fallback; pure SwiftUI heading accessibility and VoiceOver remain unqualified. No physical input or system accessibility automation.",
            "nativeViews":descendants(host).map{String(describing:type(of:$0))},
            "nativeButtons":descendants(host).compactMap{$0 as? NSButton}.map{["class":String(describing:type(of:$0)),"title":$0.title,"identifier":$0.accessibilityIdentifier(),"label":$0.accessibilityLabel() ?? "none","action":$0.action.map(NSStringFromSelector) ?? "none","target":$0.target.map{String(describing:type(of:$0))} ?? "none","menu":$0.menu?.items.map(\.title) ?? []] as [String:Any]},
            "menuItems":modeMenu().map{menuItems($0).map{["title":$0.title,"state":$0.state.rawValue,"enabled":$0.isEnabled,"action":$0.action.map(NSStringFromSelector) ?? "none"] as [String:Any]}} ?? [],
            "ownAccessibilityText":accessibilityLabels(host)]
        try JSONSerialization.data(withJSONObject:diagnostics,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("identity-native-menu-diagnostic.json"))
        return checks
    }
    func accessibilityLabels(_ node:Any,depth:Int=0)->[String] {
        guard depth<30,let element=node as? any NSAccessibilityProtocol else{return []}
        return [element.accessibilityLabel() ?? "",element.accessibilityTitle() ?? "",element.accessibilityValue() as? String ?? ""]+accessibleChildren(node).flatMap{accessibilityLabels($0,depth:depth+1)}
    }
    func accessibleChildren(_ node:Any)->[Any] {
        let children=(node as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []
        return children.isEmpty ? (node as? NSView)?.subviews.map{$0 as Any} ?? [] : children
    }
    func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    func weakProbe(hosted:Bool,home:URL,archive:URL,main:NSWindow) async -> [String:Bool] {
        let references=await makeWeakProbe(hosted:hosted,home:home,archive:archive)
        main.makeKeyAndOrderFront(nil);main.makeFirstResponder(main.contentView);main.displayIfNeeded();CATransaction.flush()
        for _ in 0..<25 {
            if references.released()["storeReleased"] == true { break }
            try? await Task.sleep(nanoseconds:100_000_000)
        }
        return references.released()
    }
    func makeWeakProbe(hosted:Bool,home:URL,archive:URL) async -> LayoutWeakReferences {
        var temporary:LensStore?=LensStore(sourceHome:home,investigationArchive:InvestigationArchive(directory:archive.appendingPathComponent(hosted ? "weak-hosted":"weak-only")))
        temporary!.setNavigationScope(UUID().uuidString);temporary!.snapshot=LensDemoFixtures.snapshot(eventCount:24);temporary!.showSessionPicker=false;await temporary!.waitForPresentation()
        let references=LayoutWeakReferences();references.store=temporary
        if hosted {
            autoreleasepool {
                var peer:NSWindow?=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                peer!.isReleasedWhenClosed=false
                var view:NSHostingView<AnyView>?=NSHostingView(rootView:AnyView(MainView().environmentObject(temporary!)))
                peer!.contentView=view;peer!.makeKeyAndOrderFront(nil);view!.layoutSubtreeIfNeeded();view!.displayIfNeeded();CATransaction.flush()
                references.host=view;references.window=peer
                temporary!.stopObserving()
                view!.rootView=AnyView(EmptyView());view!.layoutSubtreeIfNeeded();view!.displayIfNeeded();CATransaction.flush()
                peer!.contentView=nil;peer!.close();view=nil;peer=nil
            }
        } else {temporary!.stopObserving()}
        temporary=nil
        return references
    }
}
@MainActor final class LayoutWeakReferences {
    weak var store:LensStore?
    weak var host:NSView?
    weak var window:NSWindow?
    @inline(never) func released()->[String:Bool] {["storeReleased":store == nil,"hostReleased":host == nil,"windowReleased":window == nil]}
}
