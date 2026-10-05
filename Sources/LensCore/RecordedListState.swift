import Foundation

/// An empty projection says nothing about activity that was never recorded.
public enum RecordedListEmptyState: Equatable, Sendable {
    case preparing
    case sourcesUnavailable
    case noRecordedEvents(partial: Bool)
    case noRecordedCalls(partial: Bool)
    case noMatches

    public static func resolve(isPreparing: Bool, sourcesAvailable: Bool, recordedEventCount: Int, recordedCallCount: Int, callsOnly: Bool, hasCoverageIssues: Bool) -> Self {
        if isPreparing { return .preparing }
        if recordedEventCount == 0 {
            return sourcesAvailable ? .noRecordedEvents(partial: hasCoverageIssues) : .sourcesUnavailable
        }
        if callsOnly && recordedCallCount == 0 { return .noRecordedCalls(partial: hasCoverageIssues) }
        return .noMatches
    }
}

/// Date picker input is validated before forming a ClosedRange, which otherwise
/// traps for reversed bounds. Never silently swap a person's entered dates.
public struct TimelinePeriodSelection: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var range: ClosedRange<Date>? {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start <= end else { return nil }
        return start...end
    }
}
