import AppKit
import SwiftUI
import Foundation
import LensCore
import CryptoKit

/// Own native windows/model APIs, anonymous fixtures, no external UI automation.
@main struct NativeScenariosMain {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await ScenarioRun().run() }
            catch { fputs("SCENARIO_FAILED: \(error)\n",stderr) }
            app.terminate(nil)
        }
        app.run()
    }
}
@MainActor final class ScenarioRun {
    var observations:[[String:Any]]=[]
    var checks:[String:Any]=[:]
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var store:LensStore!
    var output:URL!
    var emptyHome:URL!
    var archive:URL!
    let clock=ContinuousClock()
    func run() async throws {
        func value(_ key:String)throws->String {let a=CommandLine.arguments;guard let i=a.firstIndex(of:key),i+1<a.count else{throw fail("Missing \(key)")};return a[i+1]}
        guard Bundle.main.bundleIdentifier == "fr.codexlens.qualityprobe" else{throw fail("Own bundle required")}
        output=URL(fileURLWithPath:try value("--output"));emptyHome=URL(fileURLWithPath:try value("--empty-home"));archive=URL(fileURLWithPath:try value("--archive"))
        for path in [output!,emptyHome!,archive!]{try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
        guard try FileManager.default.contentsOfDirectory(atPath:emptyHome.path).isEmpty else{throw fail("Injected home must be empty")}
        UserDefaults.standard.removePersistentDomain(forName:"fr.codexlens.qualityprobe")
        let corpus=await Task.detached{LensDemoFixtures.snapshot(eventCount:10_000)}.value
        store=LensStore(sourceHome:emptyHome,investigationArchive:InvestigationArchive(directory:archive))
        store.setNavigationScope(UUID().uuidString);store.snapshot=corpus;store.inspectorVisible=false;store.showSessionPicker=false;store.follow=false
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1500,height:900),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
        host=NSHostingView(rootView:AnyView(MainView().environmentObject(store).background(Color(nsColor:.windowBackgroundColor))))
        window.contentView=host;window.title="Codex Lens — synthetic scenario qualification";window.makeKeyAndOrderFront(nil)
        await store.waitForPresentation();await settle()
        try capture("scenarios-main-before-light.png")
        try await captureSizes(view:AnyView(MainView().environmentObject(store)),prefix:"main")
        window.appearance=NSAppearance(named:.darkAqua);host.rootView=AnyView(MainView().environmentObject(store).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.dark));await settle();try capture("scenarios-main-before-dark.png")
        window.appearance=NSAppearance(named:.aqua);host.rootView=AnyView(MainView().environmentObject(store).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.light));await settle()
        let trigger=URL(fileURLWithPath:try value("--trigger-file"));let readyURL=URL(fileURLWithPath:try value("--ready-file"))
        try write(["pid":ProcessInfo.processInfo.processIdentifier,"bundleIdentifier":"fr.codexlens.qualityprobe","fixturePreparationComplete":true,"networkDeniedByOS":true,"eventCount":10_000,"triggerFile":trigger.path,"actionCount":0,"scenarioHarness":true],to:readyURL)
        print("SCENARIOS_READY pid=\(ProcessInfo.processInfo.processIdentifier)");fflush(stdout)
        if CommandLine.arguments.contains("--run-now"){try Data("own probe\n".utf8).write(to:trigger)}
        while !FileManager.default.fileExists(atPath:trigger.path){try await Task.sleep(nanoseconds:100_000_000)}
        try await nativeTableAndScope(corpus)
        try await longDiff()
        try await currentGitDiff()
        try await fileSearchAndReader()
        try await preparedInvestigation(corpus)
        try await lifecycle(corpus)
        #if LENS_QUALITY_V04
        try await directAndSessionSwitch()
        #else
        checks["realSyntheticPollerQualified"]=false
        checks["pollerLimitation"]="v03 store lacks private cache injection; synthetic poller intentionally not started against production cache"
        #endif
        guard store.investigation.apiKey.isEmpty,!store.investigation.sending,
             try FileManager.default.contentsOfDirectory(atPath:emptyHome.path).isEmpty else{throw fail("Source/key boundary changed")}
        try write(["schemaVersion":1,"observations":observations,"functionalChecks":checks,"modelRequests":0,"realSessionRead":false,"apiKeySupplied":false,"networkDeniedByOS":true,"interactionMethod":"Own store and AppKit component APIs; no CUA click/system key injection","measurementContract":"ContinuousClock mutation/await presentation/native layout+display+flush; explicit Core search durations where named. New process/cache means cold application state, not purged OS cache. No compositor latency or global leak guarantee.","sourceLabel":try value("--source-label")],to:output.appendingPathComponent("quality-report.json"))
        print("SCENARIOS_COMPLETE");fflush(stdout)
        window.contentView=nil;window.close();host=nil;store=nil
    }
    func nativeTableAndScope(_ corpus:SessionSnapshot) async throws {
        store.section = .activity;store.resetFilters();await store.waitForPresentation();await settle()
        guard let table=descendants(host).compactMap({$0 as? NSTableView}).first(where:{$0.numberOfRows==corpus.events.count}) else{checks["nativeTableAvailable"]=false;return}
        checks["nativeTableAvailable"]=true
        let target=corpus.events[8].id
        await measure("native_table_selection",cycle:0){
            table.selectRowIndexes(IndexSet(integer:8),byExtendingSelection:false)
            table.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:table))
            await Task.yield();await self.waitForSelection(.event(target))
        }
        checks["nativeTableSelectsCorrectEvent"] = store.selection == .event(target)
        let event=corpus.events.first(where:{$0.kind == .user})!
        store.kindFilter = .user;await store.waitForPresentation();await settle()
        checks["userFilterKeepsOnlyUsers"] = !store.events.isEmpty && store.events.allSatisfy{$0.kind == .user}
        let users=store.events
        if let filtered=descendants(host).compactMap({$0 as? NSTableView}).first(where:{$0.numberOfRows==users.count}) {
            filtered.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            filtered.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:filtered))
            let previousSelection=store.selection
            store.fontSize += 1
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();CATransaction.flush()
            checks["nativeReconfigurationRequestedBeforeDeferredPublication"] = store.selection == previousSelection
            await waitForSelection(.event(users[0].id))
            checks["filteredNativeSelectionIdentity"] = store.selection == .event(users[0].id)
            if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36){filtered.keyDown(with:event);await Task.yield();await Task.yield();checks["filteredReturnKeepsSelectedUserIdentity"]=store.selection == .event(users[0].id)}
        }
        if users.count>2,let filtered=descendants(host).compactMap({$0 as? NSTableView}).first(where:{$0.numberOfRows==users.count}) {
            filtered.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            filtered.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:filtered))
            store.navigate(.event(users[2].id));host.layoutSubtreeIfNeeded();await settle()
            checks["explicitNavigationWinsPendingNativeSelection"] = store.selection == .event(users[2].id)
        }
        store.resetFilters();store.navigate(.event(event.id));await store.waitForPresentation();await settle()
        // Queue an own table callback then change root before deferred publication.
        if let current=descendants(host).compactMap({$0 as? NSTableView}).first(where:{$0.numberOfRows==corpus.events.count}) {
            current.selectRowIndexes(IndexSet(integer:10),byExtendingSelection:false)
            current.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:current))
            var second=LensDemoFixtures.snapshot(eventCount:24);second.root.id="fixture-session-beta"
            store.snapshot=second;store.selection=nil
            await store.waitForPresentation();await settle()
            checks["queuedNativeSelectionDoesNotCrossRoot"] = store.selection == nil
        }
        store.snapshot=corpus;await store.waitForPresentation();await settle()
    }
    func longDiff() async throws {
        let text="--- a/Sources/Long.swift\n+++ b/Sources/Long.swift\n@@ -1,1500 +1,1500 @@\n"+(0..<1500).map{"-let old\($0) = \($0)\n+let new\($0) = \($0+1)\n"}.joined()
        let provenance=DiffProvenance(environmentID:"/fixture/worktrees/alpha",eventIDs:["fixture-recorded-patch"],agentID:"fixture-agent",authorEvidence:"Synthetic recorded request")
        for cycle in 0..<3 {
            try await measure("long_diff_parse_render",cycle:cycle){
                let document=try await Task.detached{try RecordedDiff.parse(text,provenance:provenance,kind:.requestedPatch)}.value
                self.checks["longDiff3000RowsPreserved"] = document.files.first?.hunks.first?.lines.count == 3000
                self.host.rootView=AnyView(RecordedDiffView(document:document).environmentObject(self.store).background(Color(nsColor:.windowBackgroundColor)))
            }
        }
        try capture("scenarios-long-diff-light.png")
        #if LENS_QUALITY_V04
        let document=try RecordedDiff.parse(text,provenance:provenance,kind:.requestedPatch)
        if let hunk=document.files.first?.hunks.first,let line=hunk.lines.first {
            try await captureSizes(view:AnyView(RecordedDiffView(document:document,initialProvenanceExpanded:true,initialSelectedHunk:hunk,initialSelectedLine:line,initialLineContextExpanded:true).environmentObject(store)),prefix:"diff-expanded")
        }
        try await recordedChangeExpanded()
        #endif
        host.rootView=AnyView(MainView().environmentObject(store).background(Color(nsColor:.windowBackgroundColor)));await settle()
    }
    #if LENS_QUALITY_V04
    func recordedChangeExpanded() async throws {
        let saved=store.snapshot!
        let path=output.appendingPathComponent("own-recorded-patch.jsonl")
        let patch="*** Begin Patch\n*** Update File: Sources/Example.swift\n@@\n-let oldValue = 1\n+let newValue = 2\n*** End Patch"
        let object:[String:Any] = ["timestamp":"2026-10-02T00:00:01Z","type":"response_item","payload":["type":"custom_tool_call","name":"apply_patch","call_id":"own-expanded-call","input":patch]]
        var bytes=try JSONSerialization.data(withJSONObject:object);bytes.append(10);try bytes.write(to:path)
        let source=SourceRef(path:path.path,length:bytes.count,line:1,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
        let call=LensEvent(id:"own-expanded-patch",timestamp:ISO8601DateFormatter().date(from:"2026-10-02T00:00:01Z")!,agentID:saved.root.id,kind:.toolCall,title:"Synthetic requested patch",toolName:"apply_patch",callID:"own-expanded-call",environmentID:"/fixture/worktrees/alpha",source:source)
        let change=ChangeRecord(id:"own-expanded-change",path:"/fixture/worktrees/alpha/Sources/Example.swift",environmentID:"/fixture/worktrees/alpha",agentID:saved.root.id,eventID:call.id,kind:.requestedPatch,evidence:"Synthetic recorded request only. No file modification or complete historical versions claimed.")
        var snapshot=saved;snapshot.events.append(call);snapshot.changes.append(change);store.snapshot=snapshot;await store.waitForPresentation()
        let detail=try await store.engine.sourceDetail(for:call)
        let selected=try RecordedChangeEvidence.select(change:change,event:call)
        checks["expandedChangeExactRecordedPatchLoads"] = try RecordedChangeEvidence.documents(change:change,selection:selected,detail:detail).count == 1
        try await captureSizes(view:AnyView(RecordedChangeView(change:change,initialContextExpanded:true).environmentObject(store)),prefix:"change-context-expanded")
        store.snapshot=saved;await store.waitForPresentation()
    }
    #endif
    func currentGitDiff() async throws {
        let root=output.appendingPathComponent("own-git-fixture")
        try await Task.detached {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            func git(_ arguments:[String]) throws {
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/git")
                process.arguments=["-c","user.name=Synthetic Fixture","-c","user.email=fixture@example.invalid","-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null"]+arguments
                process.currentDirectoryURL=root
                process.environment=["PATH":"/usr/bin:/bin","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null"]
                process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run();process.waitUntilExit()
                if process.terminationStatus != 0 {throw NSError(domain:"OwnGitFixture",code:Int(process.terminationStatus))}
            }
            try git(["init","-q"])
            try Data((0..<1500).map{"let value\($0) = \($0)\n"}.joined().utf8).write(to:root.appendingPathComponent("Example.swift"))
            try git(["add","Example.swift"]);try git(["commit","-qm","Synthetic baseline"])
            try Data((0..<1500).map{"let value\($0) = \($0+1)\n"}.joined().utf8).write(to:root.appendingPathComponent("Example.swift"))
        }.value
        let environment=EnvironmentRecord(path:root.path,evidence:"Own manual modification, not attributed to Codex")
        for cycle in 0..<3 {
            let start=clock.now, diff=try await store.files.currentDiff(environment:environment,relativePath:"Example.swift")
            observe(cycle==0 ? "current_git_diff_cold_application":"current_git_diff_warm",cycle:cycle,duration:ms(start.duration(to:clock.now)))
            let provenance=DiffProvenance(environmentID:root.path,beforeReference:diff.reference)
            let document=try RecordedDiff.parse(diff.text,provenance:provenance,kind:.currentGit)
            checks["currentGitManualDiffSeparateFromAgent"] = !diff.text.isEmpty && document.kind == .currentGit && document.provenance.agentID == nil && !diff.reference.isEmpty
        }
    }
    func fileSearchAndReader() async throws {
        let root=output.appendingPathComponent("own-search-fixture");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let text=(0..<100).map{$0 == 49 ? "let needle_fixture = \"texte français\"" : "let sample\($0) = \($0)"}.joined(separator:"\n")+"\n"
        for i in 0..<200{try Data(text.utf8).write(to:root.appendingPathComponent(String(format:"File%03d.swift",i)))}
        let environment=EnvironmentRecord(path:root.path,evidence:"Own synthetic filesystem fixture")
        let search=FileSearch()
        for cycle in 0..<3 {
            let start=clock.now;let result=try await search.search(environment:environment,query:"needle_fixture",options:FileSearchOptions(maxMatches:1000))
            observe(cycle==0 ? "file_search_cold_application" : "file_search_warm",cycle:cycle,duration:ms(start.duration(to:clock.now)))
            checks["search200FilesExactCoordinates"] = result.hits.count==200 && result.hits.allSatisfy{$0.line==50 && $0.column==5 && !$0.snippetTruncated} && !result.cancelled
            if cycle==2,let hit=result.hits.first {
                let page=try await store.files.readText(path:hit.path,expectedVersion:hit.version)
                host.rootView=AnyView(CodeDocumentView(text:page.text,path:hit.path,versionLabel:"Own captured current version",scrollToLine:hit.line).background(Color(nsColor:.windowBackgroundColor)))
                await settle();try capture("scenarios-search-code-light.png")
            }
        }
        host.rootView=AnyView(MainView().environmentObject(store).background(Color(nsColor:.windowBackgroundColor)));await settle()
    }
    func preparedInvestigation(_ corpus:SessionSnapshot) async throws {
        store.investigation.clear()
        let piece=EvidencePiece(id:"E001",kind:"user-provided",title:"Synthetic supplied document",text:"Instructions conservées : vérifier les preuves [E001].",eventID:corpus.events.first?.id)
        for cycle in 0..<3 {
            try await measure("prepare_capsule_local",cycle:cycle){
                self.store.investigation.clear();try self.store.investigation.append([piece],rootID:corpus.root.id,cut:corpus.collectedAt)
                self.store.section = .investigation
            }
        }
        guard let capsule=store.investigation.capsule else{throw fail("Capsule missing")}
        checks["preparedCapsuleDigestValid"]=try capsule.verifyDigest()
        let digest=capsule.digestSHA256
        store.investigation.reviewed=true;store.investigation.model="";store.investigation.apiKey="";store.investigation.send()
        await Task.yield();checks["emptyKeySendRefusedLocally"] = !store.investigation.sending && store.investigation.issue != nil
        var advanced=corpus;advanced.events.append(LensEvent(id:"own-scenario-new-event",agentID:corpus.root.id,kind:.assistant,title:"Synthetic new event",source:SourceRef(path:"/fixture/absent.jsonl")))
        store.snapshot=advanced;await store.waitForPresentation()
        checks["preparedCapsuleSurvivesAppend"] = store.investigation.capsule?.digestSHA256 == digest
        let valid=try EvidenceAddress(rootID:corpus.root.id,capsuleID:capsule.id,pieceID:"E001");await store.openEvidence(valid)
        checks["preparedCitationShowsFrozenText"] = store.investigation.capsule?.pieces.first?.text == piece.text && store.investigation.inspectedPiece == "E001"
        await settle();try capture("scenarios-capsule-light.png")
        checks["realModelResponseQualified"]=false
    }
    func lifecycle(_ corpus:SessionSnapshot) async throws {
        let box=await closedWindowStore(corpus)
        let start=clock.now
        while box.value != nil && ms(start.duration(to:clock.now))<2500 {try await Task.sleep(nanoseconds:100_000_000)}
        checks["closedWindowStoreReleasedWithin2500ms"]=box.value == nil
        checks["releaseContract"]="Legacy unflushed host teardown within 2.5 s; separate LayoutMain records flushed teardown/focus/standalone store. Not whole-process heap leak analysis"
    }
    func closedWindowStore(_ corpus:SessionSnapshot) async -> WeakStoreBox {
        var temporary:LensStore?=LensStore(sourceHome:emptyHome,investigationArchive:InvestigationArchive(directory:archive.appendingPathComponent("lifecycle")))
        temporary!.setNavigationScope(UUID().uuidString);temporary!.snapshot=corpus;temporary!.showSessionPicker=false
        await temporary!.waitForPresentation()
        let box=WeakStoreBox(temporary!)
        var view:NSHostingView<AnyView>?=NSHostingView(rootView:AnyView(MainView().environmentObject(temporary!)))
        let peer=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.titled,.closable],backing:.buffered,defer:false);peer.isReleasedWhenClosed=false;peer.contentView=view;peer.makeKeyAndOrderFront(nil)
        view?.layoutSubtreeIfNeeded();view?.displayIfNeeded()
        #if LENS_QUALITY_V04
        temporary!.stopObserving()
        #endif
        view?.rootView=AnyView(EmptyView());peer.contentView=nil;peer.close();view=nil;temporary=nil
        return box
    }
    #if LENS_QUALITY_V04
    func directAndSessionSwitch() async throws {
        let base=output.appendingPathComponent("own-live-fixture"),home=base.appendingPathComponent("home"),folder=home.appendingPathComponent("sessions/2026/10/02"),environment=base.appendingPathComponent("environment")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:environment,withIntermediateDirectories:true)
        let a="bbbbbbbb-0000-4000-8000-000000000001",b="bbbbbbbb-0000-4000-8000-000000000002"
        func record(_ type:String,_ payload:[String:Any])throws->Data {var data=try JSONSerialization.data(withJSONObject:["timestamp":"2026-10-02T00:00:00.000Z","type":type,"payload":payload],options:[.sortedKeys]);data.append(10);return data}
        func message(_ text:String)throws->Data{try record("response_item",["type":"message","role":"assistant","content":[["type":"output_text","text":text]]])}
        var paths:[String:URL]=[:]
        for id in [a,b]{let path=folder.appendingPathComponent("rollout-2026-10-02T00-00-00-"+id+".jsonl");var bytes=try record("session_meta",["id":id,"cwd":environment.path,"source":"cli"]);bytes.append(try message("Synthetic session "+id));try bytes.write(to:path);paths[id]=path}
        UserDefaults.standard.removeObject(forKey:"lastSessionID")
        let live=LensStore(sourceHome:home,investigationArchive:InvestigationArchive(directory:base.appendingPathComponent("archive")),cacheDirectory:base.appendingPathComponent("cache"));live.setNavigationScope(UUID().uuidString)
        await live.start();await live.open(a);await live.waitForPresentation()
        guard let original=live.snapshot,let event=original.events.first else{throw fail("Own live session absent")}
        live.navigate(.event(event.id));live.toggleFollow()
        let handle=try FileHandle(forWritingTo:paths[a]!);try handle.seekToEnd();try handle.write(contentsOf:message("Synthetic natural append"));try handle.close()
        let start=clock.now
        while live.waitingEvents==0 && ms(start.duration(to:clock.now))<6000 {try await Task.sleep(nanoseconds:100_000_000)}
        checks["realSyntheticPollerQualified"]=true
        checks["pauseKeepsSelectionWhileCollecting"] = live.waitingEvents>0 && live.snapshot?.events.count==original.events.count && live.selection == .event(event.id)
        live.present();await live.waitForPresentation();checks["presentPublishesCollectedAppend"] = live.snapshot?.events.count==original.events.count+1 && live.waitingEvents==0
        let switchStart=clock.now;await live.open(b);await live.waitForPresentation();observe("real_synthetic_session_switch",cycle:0,duration:ms(switchStart.duration(to:clock.now)))
        checks["sessionSwitchClearsForeignSelection"] = live.snapshot?.root.id==b && live.selection == nil
        live.stopObserving();checks["stopObservingInvoked"]=true
    }
    #endif
    func captureSizes(view:AnyView,prefix:String) async throws {
        var geometries:[[String:Any]]=[]
        let savedSize=host.frame.size
        // Disable intrinsic sizing only in our native host, to render an exact
        // requested content viewport even if it exceeds this display's height.
        host.sizingOptions=[];host.clipsToBounds=true
        for size in [NSSize(width:1080,height:660),NSSize(width:1480,height:900)] {
            for dark in [false,true] {
                let theme=dark ? "dark" : "light"
                window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
                window.setContentSize(size);host.frame=NSRect(origin:.zero,size:size)
                host.rootView=AnyView(view.background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light).frame(width:size.width,height:size.height,alignment:.topLeading))
                await settle()
                let name="geometry-\(prefix)-\(Int(size.width))x\(Int(size.height))-\(theme).png"
                try capture(name)
                geometries.append(["filename":name,"requestedWidth":size.width,"requestedHeight":size.height,"hostWidth":host.bounds.width,"hostHeight":host.bounds.height,"windowContentWidth":window.contentView?.bounds.width ?? 0,"windowContentHeight":window.contentView?.bounds.height ?? 0,"nativeHostExactViewport":host.bounds.size==size,"theme":theme,"interactionQualified":false,"voiceOverQualified":false])
            }
        }
        try write(["view":prefix,"captures":geometries,"contract":"Native NSHostingView bitmap at explicit content sizes; host intrinsic sizing disabled. Viewport may extend outside physical display. Not CUA click, VoiceOver or compositor presentation qualification."],to:output.appendingPathComponent("geometry-"+prefix+"-receipt.json"))
        window.setContentSize(savedSize);host.frame=NSRect(origin:.zero,size:savedSize);window.appearance=NSAppearance(named:.aqua)
    }
    func waitForSelection(_ selection:Destination) async {
        let start=clock.now
        while store.selection != selection && ms(start.duration(to:clock.now))<1500 {try? await Task.sleep(nanoseconds:10_000_000)}
    }
    func measure(_ name:String,cycle:Int,body:() async throws->Void) async rethrows {
        let start=clock.now;try await body();await store.waitForPresentation();await Task.yield();host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded();CATransaction.flush();observe(name,cycle:cycle,duration:ms(start.duration(to:clock.now)))
    }
    func observe(_ name:String,cycle:Int,duration:Double){observations.append(["action":name,"cycle":cycle,"milliseconds":duration]);print("SCENARIO_ACTION name=\(name) ms=\(duration)");fflush(stdout);try? write(["observations":observations,"functionalChecks":checks,"complete":false],to:output.appendingPathComponent("scenario-progress.json"))}
    func settle()async{try? await Task.sleep(nanoseconds:200_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded();CATransaction.flush()}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    func capture(_ name:String)throws{guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw fail("Bitmap unavailable")};host.cacheDisplay(in:host.bounds,to:bitmap);guard let bytes=bitmap.representation(using:.png,properties:[:]) else{throw fail("PNG unavailable")};try bytes.write(to:output.appendingPathComponent(name))}
    func ms(_ value:Duration)->Double{let c=value.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15}
    func write(_ object:[String:Any],to url:URL)throws{try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
    func fail(_ text:String)->NSError{NSError(domain:"CodexLensScenarios",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
}
@MainActor final class WeakStoreBox {weak var value:LensStore?;init(_ store:LensStore){value=store}}
