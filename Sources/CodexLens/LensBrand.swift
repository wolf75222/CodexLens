import AppKit
import SwiftUI
import LensCore

/// Lens uses one violet ink and quiet semantic surfaces. Event colors decorate
/// shapes only: their names, symbols and statuses carry meaning independently.
enum LensControlAccent: String, CaseIterable, Identifiable {
    case lens, system, slate, sage
    var id: String { rawValue }
    var title: String { title(in: LensL10n.language) }
    func title(in language: LensL10n.Language) -> String {
        switch self { case .lens: return LensL10n.text("Violet Lens", in: language); case .system: return LensL10n.text("Système", in: language); case .slate: return LensL10n.text("Bleu ardoise", in: language); case .sage: return LensL10n.text("Vert sauge", in: language) }
    }
    var nsColor: NSColor {
        switch self { case .lens: return LensBrand.inkNSColor; case .system: return .controlAccentColor; case .slate: return LensBrand.slateInkNSColor; case .sage: return LensBrand.sageInkNSColor }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// Link ink becomes pale in dark mode. Filled controls need a separate
    /// shade because the native prominent/segmented label is white.
    var filledNSColor: NSColor {
        switch self {
        case .lens: return NSColor(srgbRed: 0.36, green: 0.32, blue: 0.54, alpha: 1)
        case .slate: return NSColor(srgbRed: 0.29, green: 0.39, blue: 0.54, alpha: 1)
        case .sage: return NSColor(srgbRed: 0.27, green: 0.43, blue: 0.34, alpha: 1)
        case .system: return .controlAccentColor
        }
    }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "lensControlAccent") ?? "lens") ?? .lens }
}

private struct LensFilledControlAccentStyle: ViewModifier {
    @AppStorage("lensControlAccent") private var preference = "lens"
    func body(content: Content) -> some View {
        content.tint(Color(nsColor: (LensControlAccent(rawValue: preference) ?? .lens).filledNSColor))
    }
}

private struct LensControlAccentStyle: ViewModifier {
    let accent: LensControlAccent
    func body(content: Content) -> some View {
        // macOS List selections and Color.accentColor still use the accent
        // environment, while segmented controls use tint. Keep both aligned.
        // accentColor is a soft deprecation in the current macOS SDK.
        content.tint(accent.color).accentColor(accent.color)
    }
}

/// The event table keeps its native selection, focus and accessibility while
/// drawing the same quiet selection surface as the other content lists.
final class LensTableSelectionRowView: NSTableRowView {
    var accent: LensControlAccent = .lens { didSet { if accent != oldValue { needsDisplay = true } } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        accent.nsColor.withAlphaComponent(isEmphasized ? 0.14 : 0.08).setFill(); path.fill()
        accent.nsColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX, y: frame.minY + 6, width: 2, height: max(0, frame.height - 12)), xRadius: 1, yRadius: 1).fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            accent.nsColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

enum LensBrand {
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
    static let inkNSColor = adaptive((0.36, 0.32, 0.54), (0.73, 0.68, 0.90))
    static let ink = Color(nsColor: inkNSColor)
    static let slateInkNSColor = adaptive((0.29, 0.39, 0.54), (0.63, 0.74, 0.88))
    static let sageInkNSColor = adaptive((0.27, 0.43, 0.34), (0.62, 0.79, 0.68))
    static let lavender = adaptive((0.72, 0.69, 0.82), (0.45, 0.41, 0.57))
    static let slate = adaptive((0.68, 0.73, 0.82), (0.39, 0.44, 0.55))
    static let sage = adaptive((0.65, 0.76, 0.70), (0.36, 0.49, 0.42))
    static let sand = adaptive((0.81, 0.75, 0.60), (0.55, 0.47, 0.31))
    static let rose = adaptive((0.82, 0.67, 0.68), (0.55, 0.36, 0.39))
    static let mist = adaptive((0.73, 0.74, 0.77), (0.43, 0.44, 0.48))
    static let sidebarNSColor = adaptive((0.973, 0.974, 0.978), (0.112, 0.114, 0.125))
    static let sidebar = Color(nsColor: sidebarNSColor)
    static let chrome = Color(nsColor: adaptive((0.990, 0.991, 0.994), (0.125, 0.127, 0.139)))
    static let controlHover = Color(nsColor: adaptive((0.937, 0.935, 0.955), (0.210, 0.204, 0.255)))
    static var selection: Color { Color.accentColor.opacity(0.12) }
    static var addition: Color { Color(nsColor: sage).opacity(0.20) }
    static var removal: Color { Color(nsColor: rose).opacity(0.20) }
    static func eventNSColor(_ kind: EventKind) -> NSColor {
        switch kind {
        case .user, .delegation: return lavender
        case .assistant: return slate
        case .toolCall, .toolResult: return sage
        case .wait: return sand
        case .error: return rose
        default: return mist
        }
    }
}

/// Small navigation controls share geometry; recorded content keeps its own surface.
enum LensChromeMetrics {
    static let spacing: CGFloat = 8
    static let radius: CGFloat = 8
    static let minimumControlHeight: CGFloat = 28
    static let feedback = Animation.easeOut(duration: 0.14)
}

/// The custom control layer follows accessibility before the user's material choice.
enum LensNavigationMaterialPolicy {
    static func usesGlass(available: Bool, preference: String, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        available && preference != "opaque" && !reduceTransparency && !increasedContrast
    }
}

private struct LensNavigationMaterial: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("lensTabMaterial") private var preference = "system"
    var usesGlass: Bool {
        let available: Bool
        if #available(macOS 26.0, *) { available = true } else { available = false }
        return LensNavigationMaterialPolicy.usesGlass(available: available, preference: preference,
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
    }
}

struct LensNavigationEffectGroup<Content: View>: View {
    private var material = LensNavigationMaterial()
    private let spacing: CGFloat
    private let content: Content
    init(spacing: CGFloat = LensChromeMetrics.spacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing; self.content = content()
    }
    var body: some View {
        if #available(macOS 26.0, *), material.usesGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

private struct LensNavigationItem: ViewModifier {
    let selected: Bool
    private var material = LensNavigationMaterial()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: LensChromeMetrics.radius, style: .continuous)
    init(selected: Bool) { self.selected = selected }
    func body(content: Content) -> some View {
        surface(content.overlay(alignment: .bottom) {
            if selected { Capsule().fill(Color.accentColor).frame(width: 18, height: 2).padding(.bottom, 3).accessibilityHidden(true) }
        })
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : LensChromeMetrics.feedback, value: selected)
            .animation(reduceMotion ? nil : LensChromeMetrics.feedback, value: hovering)
    }
    @ViewBuilder private func surface<V: View>(_ content: V) -> some View {
        if #available(macOS 26.0, *), material.usesGlass, selected {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.08)).interactive(), in: shape)
        } else {
            content.background {
                if selected || hovering {
                    shape.fill(LensBrand.chrome)
                        .overlay(shape.fill(selected ? LensBrand.selection : LensBrand.controlHover))
                        .overlay(shape.strokeBorder(contrast == .increased ? Color.primary : .clear, lineWidth: 1))
                }
            }
        }
    }
}
extension View {
    func lensControlAccent(_ accent: LensControlAccent) -> some View { modifier(LensControlAccentStyle(accent: accent)) }
    func lensFilledControlAccent() -> some View { modifier(LensFilledControlAccentStyle()) }
    /// A group of native tab actions, after sizing and appearance. Never recorded content.
    func lensNavigationItem(selected: Bool) -> some View { modifier(LensNavigationItem(selected: selected)) }
    /// Use on a native Button, after its label has been sized. Native focus,
    /// hover, disabled and pressed feedback are preserved on both OS paths.
    func lensChromeButton(prominent: Bool = false) -> some View { modifier(LensChromeButton(prominent: prominent)) }
    /// An icon Menu needs a visible hit surface, but keeps its native menu action.
    func lensChromeMenu() -> some View { modifier(LensChromeMenu()) }
}

private struct LensChromeButton: ViewModifier {
    let prominent: Bool
    private var material = LensNavigationMaterial()
    init(prominent: Bool) { self.prominent = prominent }
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), material.usesGlass {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct LensChromeMenu: ViewModifier {
    private var material = LensNavigationMaterial()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: LensChromeMetrics.radius, style: .continuous)
    func body(content: Content) -> some View {
        surface(content.padding(.horizontal, 6).frame(minWidth: 30, minHeight: LensChromeMetrics.minimumControlHeight)
            .foregroundStyle(.primary))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : LensChromeMetrics.feedback, value: hovering)
    }
    @ViewBuilder private func surface<V: View>(_ content: V) -> some View {
        if #available(macOS 26.0, *), material.usesGlass {
            content.glassEffect(.regular.interactive(isEnabled), in: shape)
        } else {
            content.background(isEnabled && hovering ? LensBrand.controlHover : Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}
