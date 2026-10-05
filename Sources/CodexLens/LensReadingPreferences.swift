import AppKit
import Combine
import SwiftUI

/// Fixed, installed macOS choices; unknown stored values fall back to the system.
/// A font change affects rendering only, never syntax analysis or captured bytes.
enum LensCodeFont: String, CaseIterable, Identifiable {
    case system, menlo, monaco
    var id: String { rawValue }
    var title: String { title(in: LensL10n.language) }
    func title(in language: LensL10n.Language) -> String {
        switch self { case .system: return LensL10n.text("Monospace système", in: language); case .menlo: return "Menlo"; case .monaco: return "Monaco" }
    }
    func nativeFont(size: Double) -> NSFont {
        let points = LensUI.readingSize(size)
        switch self {
        case .system: return .monospacedSystemFont(ofSize: points, weight: .regular)
        case .menlo: return NSFont(name: "Menlo", size: points) ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        case .monaco: return NSFont(name: "Monaco", size: points) ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        }
    }
    func font(size: Double) -> Font { Font(nativeFont(size: size)) }
}

struct LensReadingConfiguration: Equatable {
    var codeFont: LensCodeFont = .system
    var defaultSize: Double = 13
    var textStep: Double = 1
    var timelineStep: Double = 0.25
    var timelineShortcuts = true
    var pinchEnabled = true
}

/// App-wide defaults; each window keeps its own reading size and timeline.
/// Only explicit settings changes propagate to other windows.
@MainActor final class LensReadingPreferences: ObservableObject {
    static let shared = LensReadingPreferences()
    @Published private(set) var configuration: LensReadingConfiguration
    private let defaults: UserDefaults
    private static let prefix = "lens.reading."
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard let value = defaults.object(forKey: Self.prefix + key) as? NSNumber,
                  value.doubleValue.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, value.doubleValue))
        }
        configuration = LensReadingConfiguration(
            codeFont: LensCodeFont(rawValue: defaults.string(forKey: Self.prefix + "codeFont") ?? "") ?? .system,
            defaultSize: number("defaultSize", fallback: 13, range: 10...24),
            textStep: number("textStep", fallback: 1, range: 0.5...4),
            timelineStep: number("timelineStep", fallback: 0.25, range: 0.05...1),
            timelineShortcuts: defaults.object(forKey: Self.prefix + "timelineShortcuts") as? Bool ?? true,
            pinchEnabled: defaults.object(forKey: Self.prefix + "pinchEnabled") as? Bool ?? true)
    }
    func setCodeFont(_ value: LensCodeFont) { update { $0.codeFont = value } }
    func setDefaultSize(_ value: Double) { update { $0.defaultSize = Self.bounded(value, fallback: 13, range: 10...24) } }
    func setTextStep(_ value: Double) { update { $0.textStep = Self.bounded(value, fallback: 1, range: 0.5...4) } }
    func setTimelineStep(_ value: Double) { update { $0.timelineStep = Self.bounded(value, fallback: 0.25, range: 0.05...1) } }
    func setTimelineShortcuts(_ value: Bool) { update { $0.timelineShortcuts = value } }
    func setPinchEnabled(_ value: Bool) { update { $0.pinchEnabled = value } }
    func reset() { update { $0 = LensReadingConfiguration() } }
    private static func bounded(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    private func update(_ change: (inout LensReadingConfiguration) -> Void) {
        var next = configuration; change(&next)
        guard next != configuration else { return }
        defaults.set(next.codeFont.rawValue, forKey: Self.prefix + "codeFont")
        defaults.set(next.defaultSize, forKey: Self.prefix + "defaultSize")
        defaults.set(next.textStep, forKey: Self.prefix + "textStep")
        defaults.set(next.timelineStep, forKey: Self.prefix + "timelineStep")
        defaults.set(next.timelineShortcuts, forKey: Self.prefix + "timelineShortcuts")
        defaults.set(next.pinchEnabled, forKey: Self.prefix + "pinchEnabled")
        configuration = next
    }
}

enum LensZoomAction { case increase, decrease, reset }

/// A visible timeline does not steal commands from the focused reader or field.
@MainActor protocol LensTimelineZoomTarget: AnyObject {
    func canAdjustTimelineZoom(_ action: LensZoomAction) -> Bool
    func adjustTimelineZoom(_ action: LensZoomAction)
}
extension LensWindowContext {
    func handleZoomShortcut(_ event: NSEvent) -> Bool {
        guard window != nil, event.type == .keyDown, event.window === window, !hasMarkedText,
              !operationBusy, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.option, .control]).isEmpty else { return false }
        let character = event.characters ?? ""
        let action: LensZoomAction
        switch character {
        case "+", "=": action = .increase
        case "-", "−": action = .decrease
        case "0": action = .reset
        default: return false
        }
        adjustZoom(action)
        return true
    }
    private var timelineZoomTarget: LensTimelineZoomTarget? {
        guard store.readingPreferences.configuration.timelineShortcuts else { return nil }
        var responder = window?.firstResponder
        while let current = responder {
            if let target = current as? LensTimelineZoomTarget { return target }
            responder = current.nextResponder
        }
        return nil
    }
    func canAdjustZoom(_ action: LensZoomAction) -> Bool {
        guard window != nil, !operationBusy else { return false }
        if let timelineZoomTarget { return timelineZoomTarget.canAdjustTimelineZoom(action) }
        switch action {
        case .increase: return store.canPerform(.largerText)
        case .decrease: return store.canPerform(.smallerText)
        case .reset: return store.fontSize != store.readingPreferences.configuration.defaultSize
        }
    }
    func adjustZoom(_ action: LensZoomAction) {
        guard canAdjustZoom(action) else { return }
        if let timelineZoomTarget { timelineZoomTarget.adjustTimelineZoom(action); return }
        switch action {
        case .increase: store.perform(.largerText)
        case .decrease: store.perform(.smallerText)
        case .reset: store.fontSize = store.readingPreferences.configuration.defaultSize
        }
    }
}
