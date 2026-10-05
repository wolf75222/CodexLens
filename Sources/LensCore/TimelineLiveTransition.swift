import Foundation

/// A short display transition, separate from the recorded timestamps and clock.
/// Explicit navigation, zoom and clock jumps are applied immediately.
public struct TimelineLiveTransition: Sendable {
    public let source: TimelineWindow
    public let target: TimelineWindow
    public let queryWindow: TimelineWindow

    public init?(source: TimelineWindow, target: TimelineWindow) {
        let advance = target.end.timeIntervalSince(source.end)
        guard advance > 0, advance <= 2.5,
              abs(source.duration - target.duration) <= 0.000_01,
              let query = try? TimelineWindow(start: source.start, end: target.end) else { return nil }
        self.source = source; self.target = target; queryWindow = query
    }

    public func window(at progress: Double) -> TimelineWindow {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        if p == 0 { return source }
        if p == 1 { return target }
        let eased = p * (2 - p)
        let end = source.end.addingTimeInterval(target.end.timeIntervalSince(source.end) * eased)
        return (try? TimelineWindow(start: end.addingTimeInterval(-target.duration), end: end)) ?? target
    }
}
