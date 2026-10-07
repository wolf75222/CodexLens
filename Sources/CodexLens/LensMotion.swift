import SwiftUI
import AppKit
import LensCore

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

/// Measured stages use a native determinate bar immediately. Unknown totals use
/// an indeterminate indicator; elapsed time never invents a completion fraction.
struct LensLoadingState: View {
    let title: String
    var cancelTitle: String? = nil
    var onCancel: (() -> Void)? = nil
    var longRunningDelay: Duration = .milliseconds(1500)
    var operationID: UUID? = nil
    var progress: SessionLoadingProgress? = nil
    @State private var showsProgressBar = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lensReduceMotionOverride) private var override

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if showsProgressBar || progress?.fraction != nil {
                    LensLoadingBar(animationEnabled: !(override ?? systemReduceMotion), fraction: progress?.fraction)
                        // A new measured stage/file resets AppKit's retained fill.
                        .id(LoadingBarIdentity(stage: progress?.stage, fileName: progress?.fileName))
                        // The small AppKit control reserves 12 pt for its thin track.
                        .frame(height: 12)
                        .accessibilityIdentifier("lens-progress-long-running")
                        .accessibilityLabel(progress?.stageTitle ?? title)
                        .accessibilityValue(progress?.counterTitle ?? LensL10n.text("En cours"))
                } else {
                    LensProgressIndicator(accessibilityLabel: title)
                }
            }
            .frame(maxWidth: 240)
            .frame(height: 20)
            Text(progress?.stageTitle ?? title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let progress {
                if let counter = progress.counterTitle {
                    Text(counter).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("lens-progress-counter")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fileName = progress.fileName {
                    Text(fileName).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320).help(fileName)
                }
            }
            if let cancelTitle, let onCancel {
                Button(cancelTitle, action: onCancel).controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .task(id: LoadingIdentity(title: title, operationID: operationID, delay: longRunningDelay)) {
            showsProgressBar = false
            do {
                try await Task.sleep(for: longRunningDelay)
                try Task.checkCancellation()
                showsProgressBar = true
            } catch { return }
        }
    }

    private struct LoadingIdentity: Equatable {
        let title: String
        let operationID: UUID?
        let delay: Duration
    }
}

private struct LoadingBarIdentity: Hashable {
    let stage: SessionLoadingProgress.Stage?
    let fileName: String?
}

/// Native animation stays in AppKit, with no repeating SwiftUI timer or extra I/O.
/// Keeping an indeterminate control stopped also respects Reduce Motion without
/// falsely presenting a measured fraction of completion.
private struct LensLoadingBar: NSViewRepresentable {
    let animationEnabled: Bool
    let fraction: Double?

    func makeNSView(context: Context) -> LensLoadingBarIndicator {
        let indicator = LensLoadingBarIndicator()
        indicator.style = .bar
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = true
        indicator.stopAnimation(nil)
        return indicator
    }

    func updateNSView(_ indicator: LensLoadingBarIndicator, context: Context) {
        indicator.isIndeterminate = fraction == nil
        indicator.minValue = 0; indicator.maxValue = 1
        if let fraction { indicator.doubleValue = fraction }
        indicator.setAnimationEnabled(animationEnabled && fraction == nil)
    }

    static func dismantleNSView(_ indicator: LensLoadingBarIndicator, coordinator: ()) {
        indicator.setAnimationEnabled(false)
    }
}

/// A refresh keeps valid rows available while reporting its measured work.
struct LensSessionProgressLine: View {
    let progress: SessionLoadingProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            LensLoadingBar(animationEnabled: !reduceMotion, fraction: progress.fraction)
                .id(LoadingBarIdentity(stage: progress.stage, fileName: progress.fileName))
                .frame(width: 120, height: 12)
                .accessibilityLabel(progress.stageTitle)
                .accessibilityValue(progress.counterTitle ?? LensL10n.text("En cours"))
            Text(progress.counterTitle ?? progress.stageTitle).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension SessionLoadingProgress {
    var stageTitle: String {
        switch stage {
        case .discoveringSessions: LensL10n.text("Recherche des sessions…")
        case .readingMetadata: LensL10n.text("Lecture du catalogue…")
        case .restoringIndex: LensL10n.text("Chargement de l’index…")
        case .readingHistory: LensL10n.text("Lecture de l’historique…")
        case .organizingEvents: LensL10n.text("Organisation des événements…")
        case .linkingEvents: LensL10n.text("Association des actions…")
        case .savingIndex: LensL10n.text("Enregistrement de l’index…")
        case .restoringWorkspace: LensL10n.text("Restauration de la session…")
        }
    }

    var counterTitle: String? {
        switch stage {
        case .discoveringSessions:
            completed > 0 ? LensL10n.text("{0} fichiers trouvés", completed.formatted()) : nil
        case .readingMetadata:
            total.map { LensL10n.text("{0} / {1} fichiers traités", completed.formatted(), $0.formatted()) }
        case .readingHistory:
            total.map { LensL10n.text("{0} / {1} · fichier en cours", ByteCountFormatter.string(fromByteCount: completed, countStyle: .file), ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) }
        case .organizingEvents:
            total.map { LensL10n.text("{0} / {1} événements traités", completed.formatted(), $0.formatted()) }
        default: nil
        }
    }
}

final class LensLoadingBarIndicator: NSProgressIndicator {
    private(set) var animationEnabled = false

    func setAnimationEnabled(_ enabled: Bool) {
        guard animationEnabled != enabled else { return }
        animationEnabled = enabled
        if enabled { startAnimation(nil) } else { stopAnimation(nil) }
    }
}
