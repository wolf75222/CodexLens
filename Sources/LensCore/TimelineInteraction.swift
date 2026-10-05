import Foundation

/// An explicit navigation intent, separate from the selected event and live data.
/// A new token permits revealing the same event again after the user has panned.
public struct TimelineFocusRequest: Sendable, Equatable {
    public let eventID: String
    public let zoomToEvent: Bool
    public let token: UUID
    public init(eventID: String, zoomToEvent: Bool = false, token: UUID = UUID()) {
        self.eventID = eventID; self.zoomToEvent = zoomToEvent; self.token = token
    }
}

public struct TimelineZoomPlacement: Sendable, Equatable {
    public let zoom: Double
    public let originX: Double
    public let anchorDate: Date
    public let anchorViewportX: Double
}

/// Constant-time presentation math; neither events nor source traces are parsed here.
public enum TimelineInteraction {
    public static let zoomRange = 1.0...80.0
    /// Explicit framing can inspect a small interval in a long session. The
    /// document stays virtualized; this bound prevents unbounded frame sizes.
    public static let maximumFocusZoom = 1_000_000.0

    /// Frame a range on the session's original axis, rather than replacing the
    /// axis with the range. Reducing zoom can then recover the same overview.
    public static func focusPlacement(window: TimelineWindow, within bounds: TimelineWindow,
                                      baseContentWidth: Double, viewportWidth: Double) -> TimelineZoomPlacement? {
        guard [baseContentWidth, viewportWidth].allSatisfy(\.isFinite),
              baseContentWidth >= viewportWidth, viewportWidth > 165,
              window.start >= bounds.start, window.end <= bounds.end,
              let base = try? TimelineGeometry(window: bounds, contentWidth: baseContentWidth, minimumTimeSpan: 0.001) else { return nil }
        let plotWidth = viewportWidth - base.labelWidth - base.rightInset
        let timeWidth = plotWidth * base.window.duration / max(0.001, window.duration)
        let zoom = min(maximumFocusZoom, max(1, (timeWidth + base.labelWidth + base.rightInset) / baseContentWidth))
        guard let next = try? TimelineGeometry(window: base.window, contentWidth: baseContentWidth * zoom, minimumTimeSpan: 0.001) else { return nil }
        let center = window.start.addingTimeInterval(window.duration / 2)
        let focal = base.labelWidth + plotWidth / 2
        let origin = min(max(0, next.x(for: center) - focal), max(0, next.contentWidth - viewportWidth))
        return TimelineZoomPlacement(zoom: zoom, originX: origin, anchorDate: center, anchorViewportX: focal)
    }

    /// Keep the recorded instant under the fingers at the same viewport position.
    /// At a document edge, clamping wins: the result never exposes an empty document.
    /// The sticky agent labels are not a temporal coordinate, so a pinch over them
    /// anchors at the first visible position of the plot instead.
    public static func anchoredZoom(geometry: TimelineGeometry, baseContentWidth: Double,
                                    viewportWidth: Double, originX: Double,
                                    focalViewportX: Double, targetZoom: Double,
                                    maximumZoom: Double = zoomRange.upperBound) -> TimelineZoomPlacement? {
        guard [baseContentWidth, viewportWidth, originX, focalViewportX, targetZoom, maximumZoom].allSatisfy(\.isFinite),
              maximumZoom >= zoomRange.lowerBound, maximumZoom <= maximumFocusZoom,
              viewportWidth > geometry.labelWidth + geometry.rightInset,
              baseContentWidth >= viewportWidth,
              baseContentWidth > geometry.labelWidth + geometry.rightInset else { return nil }
        let zoom = min(maximumZoom, max(zoomRange.lowerBound, targetZoom))
        let focalX = min(viewportWidth - 8, max(geometry.labelWidth + 8, focalViewportX))
        let origin = min(max(0, originX), max(0, geometry.contentWidth - viewportWidth))
        let date = geometry.date(atX: origin + focalX, clamped: false)
        guard let next = try? TimelineGeometry(window: geometry.window,
                                               contentWidth: baseContentWidth * zoom,
                                               labelWidth: geometry.labelWidth, rightInset: geometry.rightInset,
                                               rulerHeight: geometry.rulerHeight, laneHeight: geometry.laneHeight,
                                               barHeight: geometry.barHeight, barInset: geometry.barInset,
                                               minimumMarkerWidth: geometry.minimumMarkerWidth, minimumTimeSpan: geometry.minimumTimeSpan) else { return nil }
        let nextOrigin = min(max(0, next.x(for: date) - focalX), max(0, next.contentWidth - viewportWidth))
        return TimelineZoomPlacement(zoom: zoom, originX: nextOrigin, anchorDate: date, anchorViewportX: focalX)
    }

    /// Frame the known interval with context. Padding belongs to the viewing axis;
    /// it is never recorded as an event duration. Unknown/reversed ends stay points.
    public static func focusWindow(for item: TimelineItem, within bounds: TimelineWindow) -> TimelineWindow? {
        guard item.start >= bounds.start, item.effectiveEnd <= bounds.end else { return nil }
        let duration = item.effectiveEnd.timeIntervalSince(item.start)
        let padding = max(5, duration * 0.5)
        return try? TimelineWindow(start: max(bounds.start, item.start.addingTimeInterval(-padding)),
                                   end: min(bounds.end, item.effectiveEnd.addingTimeInterval(padding)))
    }
}
