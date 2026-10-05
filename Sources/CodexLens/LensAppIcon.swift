import AppKit

/// Two bundled icon variants, selected once at launch and when appearance changes.
/// Finder keeps the bundle icon; AppKit applies this preference to the running app.
@MainActor final class LensAppIconController {
    static let shared = LensAppIconController()
    static let preferenceKey = "lensAppIconAppearance"
    static let defaultAppearance = "dark"
    private let defaults: UserDefaults
    private let resources: URL?
    private let application: NSApplication
    private var defaultsObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    private var pendingUpdate: Task<Void, Never>?
    private var images: [String: NSImage] = [:] // At most the two bundled ICNS images.
    private var started = false
    private(set) var appliedAppearance: String?
    private(set) var imageLoadCount = 0

    init(defaults: UserDefaults = .standard, resources: URL? = Bundle.main.resourceURL,
         application: NSApplication? = nil) {
        self.defaults = defaults
        self.resources = resources
        self.application = application ?? .shared
    }

    static func resolve(choice: String?, lensAppearance: String?, systemIsDark: Bool) -> String {
        if let choice, choice == "light" || choice == "dark" { return choice }
        guard choice == "appearance" else { return defaultAppearance }
        if let lensAppearance, lensAppearance == "light" || lensAppearance == "dark" { return lensAppearance }
        return systemIsDark ? "dark" : "light"
    }

    func start() {
        guard !started else { return }
        started = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleUpdate() } }
        appearanceObserver = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleUpdate() }
        }
        apply()
    }

    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.pendingUpdate = nil
            self?.apply()
        }
    }

    func apply() {
        guard started else { return }
        let variant = Self.resolve(choice: defaults.string(forKey: Self.preferenceKey),
            lensAppearance: defaults.string(forKey: "lensAppearance"),
            systemIsDark: application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        guard variant != appliedAppearance else { return }
        if images[variant] == nil {
            let name = variant == "dark" ? "CodexLens-Dark" : "CodexLens-Light"
            guard let url = resources?.appendingPathComponent(name + ".icns"),
                  let image = NSImage(contentsOf: url), image.isValid else { return }
            images[variant] = image
            imageLoadCount += 1
        }
        application.applicationIconImage = images[variant]
        appliedAppearance = variant
    }

    func stop() {
        started = false
        pendingUpdate?.cancel()
        pendingUpdate = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        images.removeAll()
        appliedAppearance = nil
    }
}
