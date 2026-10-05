import Foundation

/// A viewing clock, separate from recorded events and from collection state.
/// Advancing this window never implies that an agent is currently active.
public struct TimelineLiveState: Sendable, Equatable {
    public static let defaultSpan: TimeInterval = 300
    public static let spanRange: ClosedRange<TimeInterval> = 10...3600
    public static let suggestedSpans: [TimeInterval] = [60, 300, 900]

    public private(set) var span: TimeInterval
    public private(set) var window: TimelineWindow?
    public private(set) var following = false

    public init(span: TimeInterval = Self.defaultSpan) {
        self.span = Self.normalizedSpan(span)
    }

    /// An explicit resume uses the supplied instant, including an earlier date.
    /// Invalid or unrepresentable dates leave the previous state unchanged.
    public mutating func resume(at date: Date) {
        guard let next = makeWindow(endingAt: date) else { return }
        window = next
        following = true
    }

    /// Collection can continue independently while the visible period stays fixed.
    public mutating func pause() {
        following = false
    }

    /// Clock corrections cannot move a running viewing window backwards.
    /// No timestamps are rounded; one-second cadence belongs to the caller.
    public mutating func tick(at date: Date) {
        guard following, date.timeIntervalSince1970.isFinite,
              let end = window?.end, date > end,
              let next = makeWindow(endingAt: date) else { return }
        window = next
    }

    /// A paused window remains fixed; the preference applies on the next resume.
    /// During follow, the end stays monotone even if the supplied clock recedes.
    public mutating func setSpan(_ value: TimeInterval, at date: Date) {
        span = Self.normalizedSpan(value)
        guard following, date.timeIntervalSince1970.isFinite else { return }
        let end = window.map { max($0.end, date) } ?? date
        guard let next = makeWindow(endingAt: end) else { return }
        window = next
    }

    /// User navigation selects its exact period without changing the live span.
    public mutating func inspect(window: TimelineWindow) {
        self.window = window
        following = false
    }

    /// Changing sessions clears the period while retaining the chosen live span.
    public mutating func reset() {
        window = nil
        following = false
    }

    private static func normalizedSpan(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultSpan }
        return min(spanRange.upperBound, max(spanRange.lowerBound, value))
    }

    private func makeWindow(endingAt end: Date) -> TimelineWindow? {
        guard end.timeIntervalSince1970.isFinite,
              let result = try? TimelineWindow(start: end.addingTimeInterval(-span), end: end),
              result.duration > 0,
              abs(result.duration - span) <= max(0.000_001, span * 0.000_000_001) else { return nil }
        // Finite extreme dates may have too little precision for the desired span.
        // Reject them instead of presenting a zero-width or differently sized window.
        return result
    }
}
