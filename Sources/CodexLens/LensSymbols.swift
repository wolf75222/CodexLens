import AppKit
import LensCore

/// Names belong to the UI, never to recorded traces. Resolve this small fixed
/// catalogue once against the running OS; an unavailable glyph keeps a label
/// and a conservative fallback rather than leaving an empty control.
enum LensSymbols {
    static let catalogue = [
        "archivebox", "arrow.clockwise", "arrow.down", "arrow.left.arrow.right", "arrow.right",
        "arrow.down.forward.and.arrow.up.backward", "checkmark", "checkmark.circle",
        "arrow.triangle.2.circlepath", "arrow.triangle.branch", "arrow.turn.down.right",
        "arrow.up", "arrow.up.right", "arrow.up.right.circle", "book", "bookmark", "bookmark.fill", "bubble.left.and.bubble.right",
        "chevron.down", "chevron.left", "chevron.right", "chevron.up",
        "circle.dotted", "clock", "clock.badge.exclamationmark", "cursorarrow.click",
        "doc", "doc.badge.ellipsis", "doc.questionmark", "doc.on.doc",
        "doc.richtext", "doc.text", "doc.text.magnifyingglass",
        "dot.radiowaves.left.and.right", "eye", "ellipsis", "ellipsis.circle", "exclamationmark.circle",
        "exclamationmark.triangle", "folder", "folder.badge.questionmark",
        "gearshape", "hammer", "hourglass", "info.circle", "keyboard",
        "point.3.connected.trianglepath.dotted",
        "line.3.horizontal.decrease", "line.3.horizontal.decrease.circle", "link", "lock", "magnifyingglass",
        "minus.circle", "paperclip", "pause.circle", "pause.fill", "person.2", "person.3",
        "person.crop.circle", "photo", "pin.fill", "play.circle", "play.fill",
        "plus.forwardslash.minus", "plus.square.on.square", "questionmark.circle",
        "rectangle.compress.vertical", "rectangle.stack", "sidebar.left", "sidebar.right",
        "square.and.arrow.down", "square.and.arrow.up", "square.and.pencil", "square.grid.2x2", "stop.circle", "stop.fill",
        "text.alignleft", "text.bubble", "testtube.2", "textformat.size.larger", "textformat.size.smaller",
        "tray.and.arrow.down", "viewfinder", "waveform.path", "wrench",
        "xmark", "xmark.circle", "xmark.circle.fill"
    ]
    private static let fallbacks = [
        "keyboard": "gearshape", "point.3.connected.trianglepath.dotted": "link",
        "doc.badge.ellipsis": "doc.text", "doc.questionmark": "doc",
        "folder.badge.questionmark": "folder", "clock.badge.exclamationmark": "clock",
        "doc.text.magnifyingglass": "magnifyingglass", "cursorarrow.click": "info.circle",
        "rectangle.compress.vertical": "chevron.up", "dot.radiowaves.left.and.right": "info.circle",
        "textformat.size.larger": "plus.forwardslash.minus", "textformat.size.smaller": "plus.forwardslash.minus"
    ]
    static func resolvedName(_ requested: String, available: (String) -> Bool) -> String {
        if catalogue.contains(requested), available(requested) { return requested }
        if let fallback = fallbacks[requested], available(fallback) { return fallback }
        return "questionmark.circle" // SF Symbols 1; the deployment target is macOS 14.
    }
    private static let resolvedNames = Dictionary(uniqueKeysWithValues: catalogue.map { name in
        (name, resolvedName(name) { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
    })
    static func name(_ requested: String) -> String { resolvedNames[requested] ?? "questionmark.circle" }

    static func agent(_ relation: RelationKind) -> String {
        switch relation {
        case .root: return name("person.crop.circle")
        case .subagent: return name("arrow.turn.down.right")
        case .fork: return name("arrow.triangle.branch")
        case .continuation: return name("arrow.clockwise")
        case .unknown: return name("questionmark.circle")
        }
    }
}
