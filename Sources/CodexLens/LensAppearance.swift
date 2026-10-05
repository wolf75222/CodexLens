import AppKit
import SwiftUI

/// Small text uses system hues tempered by the semantic label color. Keep the
/// result dynamic: resolving a CGColor or blending once would freeze a theme.
/// Content, token ranges and recorded states are not affected by this palette.
enum LensAppearance {
    static let codeKeyword = readableText(.systemPurple)
    static let codeString = readableText(.systemRed)
    static let codeNumber = readableText(.systemBlue)
    static let codeComment = readableText(.systemGreen)
    static let warning = readableText(.systemOrange)
    static let error = readableText(.systemRed)

    static var warningText: Color { Color(nsColor: warning) }
    static var errorText: Color { Color(nsColor: error) }

    private static func readableText(_ hue: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var color: NSColor = .labelColor
            appearance.performAsCurrentDrawingAppearance {
                color = hue.blended(withFraction: 0.65, of: .labelColor) ?? .labelColor
            }
            return color
        }
    }
}
