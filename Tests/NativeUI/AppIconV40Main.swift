import AppKit

@main struct AppIconV40Probe {
    @MainActor static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "fr.codexlens.icon-probe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalIcon = application.applicationIconImage
        let originalAppearance = application.appearance
        defer { application.applicationIconImage = originalIcon; application.appearance = originalAppearance }
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAILED: " + name) }
            checks.append(name)
        }
        func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        for systemDark in [false, true] {
            for lens in ["system", "light", "dark", "invalid"] {
                for choice in ["appearance", "light", "dark", "invalid"] {
                    let expected = ["light", "dark"].contains(choice) ? choice :
                        choice != "appearance" ? "dark" :
                        ["light", "dark"].contains(lens) ? lens : systemDark ? "dark" : "light"
                    check(LensAppIconController.resolve(choice: choice, lensAppearance: lens, systemIsDark: systemDark) == expected,
                          "Appearance precedence: \(choice)/\(lens)/\(systemDark)")
                }
            }
            for lens in ["system", "light", "dark", "invalid"] {
                check(LensAppIconController.resolve(choice: nil, lensAppearance: lens, systemIsDark: systemDark) == "dark",
                      "Default remains dark: \(lens)/\(systemDark)")
            }
        }
        check(LensAppIconController.resolve(choice: nil, lensAppearance: nil, systemIsDark: false) == "dark", "Absent preferences")
        check(LensAppIconController.resolve(choice: "appearance", lensAppearance: nil, systemIsDark: false) == "dark", "Follow Lens uses the dark first-launch default")
        application.appearance = NSAppearance(named: .aqua)
        let controller = LensAppIconController(defaults: defaults, resources: resources, application: application)
        controller.start()
        check(controller.appliedAppearance == "dark", "Startup uses dark icon in light appearance")
        let darkPixels = application.applicationIconImage?.tiffRepresentation
        check(darkPixels != nil, "AppKit decodes bundled dark icon")
        controller.start()
        check(controller.imageLoadCount == 1, "Startup is idempotent")
        defaults.set("light", forKey: LensAppIconController.preferenceKey)
        await settle()
        check(controller.appliedAppearance == "light", "Explicit light preference changes running icon")
        let lightPixels = application.applicationIconImage?.tiffRepresentation
        check(lightPixels != nil && lightPixels != darkPixels, "AppKit light and dark images differ")
        defaults.set("appearance", forKey: LensAppIconController.preferenceKey)
        defaults.set("dark", forKey: "lensAppearance")
        await settle()
        check(controller.appliedAppearance == "dark", "Automatic icon follows Lens dark override")
        defaults.set("light", forKey: "lensAppearance")
        await settle()
        check(controller.appliedAppearance == "light", "Automatic icon follows Lens light override")
        defaults.set("system", forKey: "lensAppearance")
        application.appearance = NSAppearance(named: .darkAqua)
        await settle()
        check(controller.appliedAppearance == "dark", "Effective appearance observation")
        defaults.set("light", forKey: LensAppIconController.preferenceKey)
        for _ in 0..<30 { controller.apply() }
        await settle()
        check(controller.appliedAppearance == "light" && controller.imageLoadCount == 2, "Only two cached bundled icons")
        let previousIcon = application.applicationIconImage
        let missing = LensAppIconController(defaults: defaults,
            resources: resources.appendingPathComponent("unavailable"), application: application)
        missing.start()
        check(missing.appliedAppearance == nil && missing.imageLoadCount == 0, "Missing resource keeps current icon")
        check(application.applicationIconImage === previousIcon, "Missing resource does not replace icon")
        missing.stop()
        controller.stop()
        defaults.set("dark", forKey: LensAppIconController.preferenceKey)
        await settle()
        check(controller.appliedAppearance == nil && application.applicationIconImage === previousIcon, "Stopped controller has no late update")
        controller.start()
        check(controller.appliedAppearance == "dark", "Restart restores saved choice")
        controller.stop()
        let receipt: [String: Any] = ["passed": true, "checkCount": checks.count, "checks": checks,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "limits": ["No OS Dock or Finder compositor screenshot", "No macOS 14 or Intel runtime"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native AppKit icon checks passed: \(checks.count)")
    }
}
