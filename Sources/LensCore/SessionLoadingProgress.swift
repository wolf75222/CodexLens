import Foundation

/// Work measured within the current stage, never a time-based estimate for the
/// entire opening. Byte totals describe one journal and can grow during live use.
public struct SessionLoadingProgress: Sendable, Equatable {
    public enum Stage: Sendable, Hashable { case discoveringSessions, readingMetadata, restoringIndex, readingHistory, organizingEvents, linkingEvents, savingIndex, restoringWorkspace }
    public let stage: Stage
    public let completed: Int64
    public let total: Int64?
    public let fileName: String?

    public init(stage: Stage, completed: Int64 = 0, total: Int64? = nil, fileName: String? = nil) {
        self.stage = stage
        let completed = max(0, completed)
        self.completed = completed
        self.total = total.flatMap { $0 > 0 ? max($0, completed) : nil }
        self.fileName = fileName
    }

    public var fraction: Double? { total.map { min(1, Double(completed) / Double($0)) } }
}

public typealias SessionProgressHandler = @Sendable (SessionLoadingProgress) -> Void

/// Confined to one engine operation. Bound publications before crossing to the
/// reader/UI; stage changes and measured stage completion are always delivered.
final class SessionProgressReporter {
    private let handler: SessionProgressHandler?
    private var previous: SessionLoadingProgress?
    private var publishedAt: ContinuousClock.Instant?

    init(_ handler: SessionProgressHandler?) { self.handler = handler }
    func send(_ progress: SessionLoadingProgress) {
        guard let handler, progress != previous else { return }
        let now = ContinuousClock.now
        let changedStage = previous?.stage != progress.stage || previous?.fileName != progress.fileName
        let completedStage = progress.total != nil && progress.completed == progress.total
        guard changedStage || completedStage || publishedAt.map({ now - $0 >= .milliseconds(100) }) ?? true else { return }
        previous = progress; publishedAt = now
        handler(progress)
    }
}
