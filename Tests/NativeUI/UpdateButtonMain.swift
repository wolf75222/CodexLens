import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// Source-matched button/controller checks with an owned in-memory driver.
/// Replacement and signatures are qualified separately by verify-updates.sh.
@main struct UpdateButtonMain {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Update button qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor private static func qualify() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--output")! + 1])
        var checks: [[String: Any]] = [], renders: [String] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let driver = UpdateButtonDriver()
        let updater = LensUpdateController(driver: driver)
        updater.start(); updater.start()
        check("one-controller-starts-driver-once", driver.starts == 1 && updater.canCheck)
        driver.afterCheck = .init(canCheck: false, sessionInProgress: true, automaticChecks: false, lastChecked: nil)
        updater.check(); updater.check()
        check("rapid-second-click-cannot-start-another-check", driver.checks == 1 && !updater.canCheck && updater.sessionInProgress)
        driver.afterCheck = nil
        // Deliberately don't publish: check() must use current backend state.
        driver.value = .init(canCheck: true, sessionInProgress: true, automaticChecks: false, lastChecked: nil)
        updater.recordAvailableVersion("9.1")
        updater.check()
        check("active-update-can-be-focused", driver.checks == 2 && updater.sessionInProgress)
        check("focus-preserves-available-version-and-status", updater.availableVersion == "9.1" && updater.status.isEmpty)
        driver.value = .init(canCheck: false, sessionInProgress: true, automaticChecks: false, lastChecked: nil)
        updater.check()
        check("fresh-unpublished-can-check-false-is-respected", driver.checks == 2 && !updater.canCheck)
        driver.publish(.init(canCheck: true, sessionInProgress: false, automaticChecks: false, lastChecked: Date(timeIntervalSince1970: 10)))
        check("session-and-last-check-publication-reaches-controller", !updater.sessionInProgress && updater.lastChecked == Date(timeIntervalSince1970: 10))
        updater.check()
        check("new-check-clears-old-offer-and-reports-checking", driver.checks == 3 && updater.availableVersion == nil && updater.status == "Recherche de mises à jour…")
        updater.setAutomaticChecks(true)
        check("automatic-check-choice-routes-to-single-driver", driver.value.automaticChecks && updater.automaticChecks)
        let failed = UpdateButtonDriver(); failed.failStart = true
        let broken = LensUpdateController(driver: failed)
        broken.check(); broken.check()
        check("startup-failure-never-dispatches-a-check", failed.starts == 1 && failed.checks == 0 && broken.unavailableReason != nil && !broken.canCheck)

        for language in [LensL10n.Language.en, .fr] {
            LensL10n.language = language
            for iconOnly in [false, true] {
                driver.afterCheck = .init(canCheck: true, sessionInProgress: true, automaticChecks: true, lastChecked: nil)
                driver.publish(.init(canCheck: true, sessionInProgress: false, automaticChecks: true, lastChecked: nil))
                let name = "update-button-\(language.rawValue)-\(iconOnly ? "toolbar" : "settings")"
                let identifier = "lens-update-button-test"
                let host = NSHostingView(rootView: AnyView(
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LensL10n.text("Mises à jour")).font(.headline)
                        LensUpdateButton(updater: updater, iconOnly: iconOnly, identifier: identifier)
                            .buttonStyle(.bordered)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, language == .en ? .dark : .light)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: -6000, width: 420, height: 160),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: language == .en ? .darkAqua : .aqua)
                window.setAccessibilityIdentifier("UpdateButton-" + UUID().uuidString)
                host.sizingOptions = []; host.autoresizingMask = [.width, .height]
                window.contentView = host; window.orderBack(nil)
                let nodes = try await ownNodes(window, identifier: identifier)
                let buttons = nodes.filter { attribute($0, kAXIdentifierAttribute) as? String == identifier }
                check(name + "-one-accessible-button", buttons.count == 1)
                if let button = buttons.first {
                    let label = attribute(button, kAXDescriptionAttribute) as? String ?? attribute(button, kAXTitleAttribute) as? String
                    check(name + "-label-explains-action", label == LensL10n.text("Mettre à jour l’app…"))
                    let before = driver.checks
                    let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    check(name + "-press-routes-one-native-action", pressed && driver.checks == before + 1 && driver.starts == 1)
                    updater.recordAvailableVersion("9.1")
                    let active = try await ownNodes(window, identifier: identifier)
                    let next = active.first { attribute($0, kAXIdentifierAttribute) as? String == identifier }
                    if let next {
                        let old = driver.checks
                        let focused = AXUIElementPerformAction(next, kAXPressAction as CFString) == .success
                        check(name + "-repeat-focuses-preserving-offer", focused && driver.checks == old + 1
                              && updater.availableVersion == "9.1" && updater.status.isEmpty)
                    } else { check(name + "-repeat-focuses-preserving-offer", false) }
                }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output.appendingPathComponent(name + ".png")); renders.append(name + ".png")
                window.contentView = nil; window.close()
            }
        }
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "captureMethod": "Owned offscreen AppKit views and exact own-window public AX actions; in-memory updater driver.",
            "productionAppModified": false, "networkRequests": 0,
            "unqualified": ["Physical clicks", "Production HTTPS feed", "Standard Sparkle dialogs and installation"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }
    @MainActor private static func ownNodes(_ window: NSWindow, identifier: String) async throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 0.5)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var nodes: [AXUIElement] = []
        repeat {
            if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
               let own = windows.first(where: { attribute($0, kAXIdentifierAttribute) as? String == window.accessibilityIdentifier() }) {
                nodes = []; var seen: [CFHashCode: [AXUIElement]] = [:]
                func walk(_ node: AXUIElement, depth: Int) {
                    guard depth < 40, nodes.count < 4000 else { return }
                    let hash = CFHash(node)
                    guard !(seen[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
                    seen[hash, default: []].append(node); nodes.append(node)
                    for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
                }
                walk(own, depth: 0)
                if nodes.contains(where: { attribute($0, kAXIdentifierAttribute) as? String == identifier }) { return nodes }
            }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nodes
    }
}

@MainActor private final class UpdateButtonDriver: LensUpdateDriving {
    var value = LensUpdateDriverSnapshot(canCheck: true, sessionInProgress: false, automaticChecks: false, lastChecked: nil)
    var snapshot: LensUpdateDriverSnapshot { value }
    var afterCheck: LensUpdateDriverSnapshot?
    var starts = 0, checks = 0
    var failStart = false
    private var receive: (@MainActor () -> Void)?
    func start() throws { starts += 1; if failStart { throw CocoaError(.fileReadUnknown) } }
    func check() { checks += 1; if let afterCheck { value = afterCheck } }
    func setAutomaticChecks(_ enabled: Bool) {
        value = .init(canCheck: value.canCheck, sessionInProgress: value.sessionInProgress,
                      automaticChecks: enabled, lastChecked: value.lastChecked)
    }
    func observeChanges(_ receive: @escaping @MainActor () -> Void) { self.receive = receive }
    func publish(_ snapshot: LensUpdateDriverSnapshot) { value = snapshot; receive?() }
}
