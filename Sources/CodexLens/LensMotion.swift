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

/// Compact native bar. Unknown totals stay indeterminate; Reduce Motion keeps
/// the track stationary without claiming a measured completion fraction.
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
            LensLoadingBar(animationEnabled: !(override ?? systemReduceMotion), fraction: nil)
                .frame(width: 64, height: 12)
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
    var operationID: UUID? = nil
    var progress: SessionLoadingProgress? = nil
    var showsOpeningSteps = false
    var workProgress: OperationProgress? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lensReduceMotionOverride) private var override

    var body: some View {
        VStack(spacing: 12) {
            Text(currentTitle).font(.callout.weight(.medium)).foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            LensLoadingBar(animationEnabled: !(override ?? systemReduceMotion), fraction: workProgress?.fraction ?? progress?.fraction)
                        // A new measured stage/file resets AppKit's retained fill.
                        .id(LoadingBarIdentity(operationID: operationID, stage: progress?.stage, phase: progress?.phase, fileName: progress?.history == nil ? progress?.fileName : nil, totalBytes: progress?.history?.totalBytes, workStage: workProgress?.stage, workDetail: workProgress?.detail))
                        // The small AppKit control reserves 12 pt for its thin track.
                        .frame(height: 12)
                        .accessibilityIdentifier("lens-progress-long-running")
                        .accessibilityLabel(currentTitle)
                        .accessibilityValue(currentCounter ?? LensL10n.text("En cours"))
            .frame(maxWidth: 240)
            .frame(height: 20)
            if let counter = currentCounter {
                Text(counter).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("lens-progress-counter")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                if let detail = progress.fileDetailTitle {
                    Text(detail).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true).help(progress.fileName ?? detail)
                }
                if let fileName = progress.fileName {
                    Text(fileName).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320).help(fileName)
                }
                if showsOpeningSteps {
                    DisclosureGroup(LensL10n.text("Étape {0} sur {1}", progress.openingStep.formatted(), "4")) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(SessionLoadingProgress.openingTitles.enumerated()), id: \.offset) { index, label in
                                HStack(spacing: 8) {
                                    Image(systemName: LensSymbols.name(index + 1 < progress.openingStep ? "checkmark" : index + 1 == progress.openingStep ? "arrow.right" : "circle"))
                                        .frame(width: 14).accessibilityHidden(true)
                                    Text(label).foregroundStyle(index + 1 == progress.openingStep ? .primary : .secondary)
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.caption).frame(maxWidth: 280)
                }
            } else if let workProgress {
                if let detail = workProgress.detailTitle {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(2).truncationMode(.middle).frame(maxWidth: 360).help(detail)
                }
                if let step = workProgress.step, let total = workProgress.stepCount {
                    Text(LensL10n.text("Étape {0} sur {1}", step.formatted(), total.formatted()))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let cancelTitle, let onCancel {
                Button(cancelTitle, action: onCancel).controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
    private var currentTitle: String { workProgress?.stageTitle ?? progress?.phaseTitle ?? title }
    private var currentCounter: String? { workProgress?.counterTitle ?? progress?.counterTitle }
}

private struct LoadingBarIdentity: Hashable {
    var operationID: UUID? = nil
    let stage: SessionLoadingProgress.Stage?
    var phase: SessionLoadingProgress.Phase? = nil
    let fileName: String?
    var totalBytes: Int64? = nil
    var workStage: OperationProgress.Stage? = nil
    var workDetail: String? = nil
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
                .id(LoadingBarIdentity(stage: progress.stage, phase: progress.phase, fileName: progress.history == nil ? progress.fileName : nil, totalBytes: progress.history?.totalBytes))
                .frame(width: 120, height: 12)
                .accessibilityLabel(progress.phaseTitle)
                .accessibilityValue(progress.counterTitle ?? LensL10n.text("En cours"))
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.phaseTitle)
                if let counter = progress.counterTitle { Text(counter).monospacedDigit() }
            }.font(.caption)
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct LensOperationProgressLine: View {
    let progress: OperationProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lensReduceMotionOverride) private var override
    var body: some View {
        HStack(spacing: 10) {
            LensLoadingBar(animationEnabled: !(override ?? reduceMotion), fraction: progress.fraction)
                .id(LoadingBarIdentity(stage: nil, fileName: nil, workStage: progress.stage, workDetail: progress.detail))
                .frame(width: 96, height: 12)
                .accessibilityLabel(progress.stageTitle)
                .accessibilityValue(progress.counterTitle ?? LensL10n.text("En cours"))
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.stageTitle)
                if let counter = progress.counterTitle { Text(counter).monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain)
    }
}

extension OperationProgress {
    var stageTitle: String {
        switch stage {
        case .indexingConversation: LensL10n.text("Classement de la conversation…")
        case .readingMessages: LensL10n.text("Lecture des messages…")
        case .writingMessages: LensL10n.text("Écriture des messages…")
        case .savingExport: LensL10n.text("Enregistrement de l’export…")
        case .indexingEvents: LensL10n.text("Préparation de la liste des événements…")
        case .inspectingContext: LensL10n.text("Préparation du contexte…")
        case .inspectingCommunications: LensL10n.text("Préparation des échanges…")
        case .indexingChanges: LensL10n.text("Préparation des modifications…")
        case .inspectingOrigin: LensL10n.text("Association des sources…")
        case .preparingTrends: LensL10n.text("Préparation des courbes…")
        case .filteringEvents: LensL10n.text("Préparation de la sélection…")
        case .preparingTimeline: LensL10n.text("Préparation de la chronologie…")
        case .searchingFiles: LensL10n.text("Recherche dans les fichiers…")
        }
    }
    var counterTitle: String? {
        if unit == .steps, total == 1 { return nil }
        guard let total, let remaining else {
            return completed > 0 ? LensL10n.text("{0} éléments traités", completed.formatted()) : nil
        }
        if unit == .bytes {
            return LensL10n.text("{0} / {1} · {2} restants", Self.bytes(completed), Self.bytes(total), Self.bytes(remaining))
        }
        return LensL10n.text("{0} / {1} · {2} restants", completed.formatted(), total.formatted(), remaining.formatted())
    }
    var detailTitle: String? {
        guard let detail else { return nil }
        switch detail {
        case "presentation.reuse": return LensL10n.text("Réutilisation de la vue préparée")
        case "presentation.events": return LensL10n.text("Classement des événements")
        case "presentation.relatedFilters": return LensL10n.text("Filtrage des éléments associés")
        case "timeline.cache": return LensL10n.text("Vérification de la chronologie préparée")
        case "timeline.validate": return LensL10n.text("Vérification des horodatages")
        case "timeline.sort": return LensL10n.text("Tri chronologique")
        case "timeline.build": return LensL10n.text("Placement des événements")
        case "timeline.lanes": return LensL10n.text("Préparation des lignes par agent")
        case "timeline.fingerprint": return LensL10n.text("Vérification de la version")
        case "timeline.retention": return LensL10n.text("Enregistrement de la chronologie préparée")
        default: return detail
        }
    }
    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

extension SessionLoadingProgress {
    static var openingTitles: [String] {
        [LensL10n.text("Retrouver la session"), LensL10n.text("Lire les historiques"),
         LensL10n.text("Organiser les actions"), LensL10n.text("Restaurer la session")]
    }
    var phaseTitle: String {
        guard let phase else { return stageTitle }
        return switch phase {
        case .filteringSessions: LensL10n.text("Classement des sessions…")
        case .readingTitles: LensL10n.text("Lecture des titres…")
        case .savingCatalog: LensL10n.text("Enregistrement du catalogue…")
        case .sortingEvents: LensL10n.text("Tri chronologique…")
        case .deduplicatingEvents: LensL10n.text("Regroupement des événements…")
        case .indexingCalls: LensL10n.text("Classement des appels…")
        case .linkingResults: LensL10n.text("Association des résultats…")
        case .checkingCalls: LensL10n.text("Vérification des appels…")
        case .indexingEnvironments: LensL10n.text("Classement des environnements…")
        case .indexingResources: LensL10n.text("Classement des ressources…")
        case .preparingAgents: LensL10n.text("Préparation des agents…")
        case .checkingEnvironments: LensL10n.text("Vérification des environnements…")
        case .checkingResources: LensL10n.text("Vérification des ressources…")
        case .checkingIndexSize: LensL10n.text("Préparation de l’index…")
        case .encodingIndex: LensL10n.text("Encodage de l’index…")
        case .writingIndex: LensL10n.text("Écriture de l’index…")
        case .preparingEventLookup: LensL10n.text("Indexation des événements…")
        case .preparingSourceLookup: LensL10n.text("Indexation des sources…")
        }
    }
    var stageTitle: String {
        switch stage {
        case .discoveringSessions: LensL10n.text("Recherche des sessions…")
        case .readingMetadata: LensL10n.text("Lecture du catalogue…")
        case .finalizingCatalog: LensL10n.text("Finalisation du catalogue…")
        case .restoringIndex: LensL10n.text("Chargement de l’index…")
        case .readingHistory: LensL10n.text("Lecture de l’historique…")
        case .organizingEvents: LensL10n.text("Organisation des événements…")
        case .linkingEvents: LensL10n.text("Association des actions…")
        case .savingIndex: LensL10n.text("Enregistrement de l’index…")
        case .restoringWorkspace: LensL10n.text("Restauration de la session…")
        }
    }

    var counterTitle: String? {
        if let phase, let total {
            let remaining = max(0, total - completed)
            if phase == .writingIndex {
                return LensL10n.text("{0} / {1} · {2} restants", ByteCountFormatter.string(fromByteCount: completed, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file), ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file))
            }
            return LensL10n.text("{0} / {1} · {2} restants", completed.formatted(), total.formatted(), remaining.formatted())
        }
        switch stage {
        case .discoveringSessions:
            return completed > 0 ? LensL10n.text("{0} fichiers trouvés", completed.formatted()) : nil
        case .readingMetadata:
            return total.map { LensL10n.text("{0} / {1} fichiers · {2} restants", completed.formatted(), $0.formatted(), max(0, $0 - completed).formatted()) }
        case .readingHistory:
            if let history {
                if let total = history.totalBytes {
                    return LensL10n.text("{0} / {1} · {2} restants", ByteCountFormatter.string(fromByteCount: history.completedBytes, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file), ByteCountFormatter.string(fromByteCount: max(0, total - history.completedBytes), countStyle: .file))
                }
                return LensL10n.text("{0} / {1} fichiers · {2} restants", history.completedFiles.formatted(), history.totalFiles.formatted(), max(0, history.totalFiles - history.completedFiles).formatted())
            }
            return total.map { LensL10n.text("{0} / {1} · {2} restants", ByteCountFormatter.string(fromByteCount: completed, countStyle: .file), ByteCountFormatter.string(fromByteCount: $0, countStyle: .file), ByteCountFormatter.string(fromByteCount: max(0, $0 - completed), countStyle: .file)) }
        case .organizingEvents:
            return total.map { LensL10n.text("{0} / {1} événements · {2} restants", completed.formatted(), $0.formatted(), max(0, $0 - completed).formatted()) }
        default: return nil
        }
    }

    var fileDetailTitle: String? {
        guard let history, let total, stage == .readingHistory else { return nil }
        return LensL10n.text("Fichier {0}/{1} · {2} / {3}", history.currentFile.formatted(), history.totalFiles.formatted(), ByteCountFormatter.string(fromByteCount: completed, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
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
