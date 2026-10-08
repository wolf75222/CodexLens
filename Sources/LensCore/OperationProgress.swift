import Foundation

/// Completed work within one named phase. No elapsed-time estimate or weighted
/// whole-operation percentage is inferred from phases with different costs.
public struct OperationProgress: Sendable, Equatable {
    public enum Stage: Sendable, Hashable {
        case indexingConversation, readingMessages, writingMessages, savingExport
        case indexingEvents, inspectingContext, inspectingCommunications
        case indexingChanges, inspectingOrigin, preparingTrends, filteringEvents
        case preparingTimeline, searchingFiles
    }
    public enum Unit: Sendable, Hashable { case events, messages, files, bytes, steps }
    public let stage: Stage
    public let completed: Int64
    public let total: Int64?
    public let unit: Unit
    public let detail: String?
    public let step: Int?
    public let stepCount: Int?

    public init(stage: Stage, completed: Int64 = 0, total: Int64? = nil,
                unit: Unit = .steps, detail: String? = nil, step: Int? = nil, stepCount: Int? = nil) {
        let completed = max(0, completed)
        self.stage = stage; self.completed = completed
        self.total = total.flatMap { $0 > 0 ? max($0, completed) : nil }
        self.unit = unit; self.detail = detail
        self.step = step; self.stepCount = stepCount
    }
    public var fraction: Double? { total.map { Double(completed) / Double($0) } }
    public var remaining: Int64? { total.map { max(0, $0 - completed) } }
}

public typealias OperationProgressHandler = @Sendable (OperationProgress) -> Void

/// Operation-confined and bounded before crossing to the UI. A completed phase
/// is forced only on its first completion, not on every growing-total update.
final class OperationProgressReporter {
    private let handler: OperationProgressHandler?
    private var previous: OperationProgress?
    private var publishedAt: ContinuousClock.Instant?
    init(_ handler: OperationProgressHandler?) { self.handler = handler }
    func send(_ progress: OperationProgress) {
        guard let handler, progress != previous else { return }
        let now = ContinuousClock.now
        let changed = previous?.stage != progress.stage || previous?.detail != progress.detail
        let completed = progress.remaining == 0 && previous?.remaining != 0
        guard changed || completed || publishedAt.map({ now - $0 >= .milliseconds(100) }) ?? true else { return }
        previous = progress; publishedAt = now; handler(progress)
    }
}
