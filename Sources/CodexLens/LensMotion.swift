import SwiftUI

private struct LensReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
    /// Explicit native-fixture input. Production leaves nil and uses the system
    /// preference; tests never write the user's global accessibility settings.
    var lensReduceMotionOverride: Bool? {
        get { self[LensReduceMotionOverrideKey.self] }
        set { self[LensReduceMotionOverrideKey.self] = newValue }
    }
}

/// Read the system preference at the view that receives the transaction. This does
/// not write preferences or disable gestures, selection, native scrolling or collection.
struct LensMotionAwareModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lensReduceMotionOverride) private var override
    func body(content: Content) -> some View {
        content.transaction { transaction in
            if override ?? systemReduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

/// Data changes are immediate, even when an enclosing control has an animation.
/// Evidence, log rows and streaming text must not move through intermediate states.
struct LensStableContentModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

extension View {
    func lensMotionAware() -> some View { modifier(LensMotionAwareModifier()) }
    func lensStableContent() -> some View { modifier(LensStableContentModifier()) }
}

/// The same loading state is conveyed with text and an accessible value in both
/// modes. Reduce Motion replaces the indefinite spinner with a stationary symbol.
struct LensProgressIndicator: View {
    let title: String?
    let accessibilityLabel: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lensReduceMotionOverride) private var override

    init(_ title: String? = nil, accessibilityLabel: String? = nil) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel ?? title ?? LensL10n.text("Chargement en cours")
    }

    var body: some View {
        HStack(spacing: 8) {
            if override ?? systemReduceMotion {
                Image(systemName: LensSymbols.name("hourglass")).imageScale(.small)
            } else {
                ProgressView().fixedSize()
            }
            if let title { Text(title).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier((override ?? systemReduceMotion) ? "lens-progress-stationary" : "lens-progress-standard")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(LensL10n.text("En cours"))
        .symbolRenderingMode(.monochrome)
    }
}

/// A content-area loading state. Inline indicators remain compact; the title,
/// spinner and optional cancellation here share the same horizontal centre.
struct LensLoadingState: View {
    let title: String
    var cancelTitle: String? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            LensProgressIndicator(accessibilityLabel: title)
            Text(title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let cancelTitle, let onCancel {
                Button(cancelTitle, action: onCancel).controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
