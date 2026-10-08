import Foundation

/// Work measured within the current stage, never a time-based estimate for the
/// entire opening. Byte totals describe one journal and can grow during live use.
public struct SessionLoadingProgress: Sendable, Equatable {
    public struct History: Sendable, Equatable {
        public let completedBytes: Int64
        public let totalBytes: Int64?
        public let completedFiles: Int
        public let totalFiles: Int
        public let currentFile: Int
        public init(completedBytes: Int64, totalBytes: Int64?, completedFiles: Int, totalFiles: Int, currentFile: Int? = nil) {
            self.completedBytes = completedBytes; self.totalBytes = totalBytes
            self.completedFiles = completedFiles; self.totalFiles = totalFiles
            self.currentFile = currentFile ?? min(completedFiles + 1, totalFiles)
        }
        public var fraction: Double? {
            totalBytes.flatMap { $0 > 0 ? min(1, Double(completedBytes) / Double($0)) : nil }
        }
    }
    public enum Stage: Sendable, Hashable { case discoveringSessions, readingMetadata, finalizingCatalog, restoringIndex, readingHistory, organizingEvents, linkingEvents, savingIndex, restoringWorkspace }
    /// The counter belongs to this passage alone; passages are not time weights
    /// and cannot be combined into a percentage for the entire opening.
    public enum Phase: Sendable, Hashable {
        case filteringSessions, readingTitles, savingCatalog
        case sortingEvents, deduplicatingEvents
        case indexingCalls, linkingResults, checkingCalls, indexingEnvironments, indexingResources, preparingAgents, checkingEnvironments, checkingResources
        case checkingIndexSize, encodingIndex, writingIndex, preparingEventLookup, preparingSourceLookup
    }
    public let stage: Stage
    public let completed: Int64
    public let total: Int64?
    public let fileName: String?
    public let history: History?
    public let phase: Phase?

    public init(stage: Stage, completed: Int64 = 0, total: Int64? = nil, fileName: String? = nil, history: History? = nil, phase: Phase? = nil) {
        self.stage = stage
        let completed = max(0, completed)
        self.completed = completed
        self.total = total.flatMap { $0 > 0 ? max($0, completed) : nil }
        self.fileName = fileName
        self.history = history
        self.phase = phase
    }

    public var fraction: Double? {
        if let history { return history.fraction }
        return total.map { min(1, Double(completed) / Double($0)) }
    }

    public var openingStep: Int {
        switch stage {
        case .discoveringSessions, .readingMetadata, .finalizingCatalog, .restoringIndex: 1
        case .readingHistory: 2
        case .organizingEvents, .linkingEvents: 3
        case .savingIndex, .restoringWorkspace: 4
        }
    }
}

/// Operation-confined accounting. Register newly discovered journals without
/// rereading them; update aggregate byte counters in constant time per chunk.
final class SessionHistoryProgress {
    private struct Entry { var total: Int64?; var completed: Int64 = 0; var finished = false }
    private var entries: [String: Entry] = [:]
    private var completed: Int64 = 0, total: Int64 = 0
    private var unknown = 0, finished = 0
    private var currentPath: String?, ordinal = 0
    func contains(path: String) -> Bool { entries[path] != nil }

    func register(path: String, bytes: Int64?) {
        guard entries[path] == nil else { return }
        entries[path] = Entry(total: bytes)
        if let bytes { total = Self.add(total, max(0, bytes)) } else { unknown += 1 }
    }
    func update(path: String, completedBytes: Int64, totalBytes: Int64) {
        if entries[path] == nil { register(path: path, bytes: totalBytes) }
        guard var entry = entries[path] else { return }
        if currentPath != path { currentPath = path; ordinal = finished + 1 }
        if entry.total == nil { unknown -= 1 }
        total = Self.add(total - (entry.total ?? 0), totalBytes)
        completed = Self.add(completed - entry.completed, completedBytes)
        entry.total = totalBytes; entry.completed = completedBytes; entries[path] = entry
    }
    func finish(path: String) {
        guard var entry = entries[path], !entry.finished else { return }
        entry.finished = true; entries[path] = entry; finished += 1
    }
    var snapshot: SessionLoadingProgress.History {
        .init(completedBytes: completed, totalBytes: unknown == 0 ? total : nil,
              completedFiles: finished, totalFiles: entries.count, currentFile: ordinal)
    }
    private static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

public typealias SessionProgressHandler = @Sendable (SessionLoadingProgress) -> Void

/// Confined to one engine operation. Bound publications before crossing to the
/// reader/UI; stage changes and measured stage completion are always delivered.
final class SessionProgressReporter {
    private let handler: SessionProgressHandler?
    private var previous: SessionLoadingProgress?
    private var publishedAt: ContinuousClock.Instant?

    init(_ handler: SessionProgressHandler?) { self.handler = handler }
    var isEnabled: Bool { handler != nil }
    func send(_ value: @autoclosure () -> SessionLoadingProgress) {
        // Unobserved refreshes should not allocate progress values or snapshots.
        guard let handler else { return }
        let progress = value()
        guard progress != previous else { return }
        let now = ContinuousClock.now
        let changedStage = previous?.stage != progress.stage || previous?.phase != progress.phase || previous?.fileName != progress.fileName
        let completedStage = progress.total != nil && progress.completed == progress.total
        let previouslyCompleted = previous.map { $0.total != nil && $0.completed == $0.total } ?? false
        let completedFile = progress.history.map { $0.completedFiles > (previous?.history?.completedFiles ?? 0) } ?? false
        // A growing journal can keep completed == total for several chunks. Only
        // its first completion bypasses coalescing; each finished file still does.
        guard changedStage || (completedStage && !previouslyCompleted) || completedFile || publishedAt.map({ now - $0 >= .milliseconds(100) }) ?? true else { return }
        previous = progress; publishedAt = now
        handler(progress)
    }
}
