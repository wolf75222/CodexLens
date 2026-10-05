import SwiftUI
import LensCore

/// Shared reading scale for session content and its supporting metadata.
enum LensUI {
    static let body = Font.body
    static let metadata = Font.subheadline
    static let header = Font.body.weight(.semibold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let paneTitle = Font.system(size: 13, weight: .semibold)

    // macOS has no Dynamic Type. The per-window reading commands scale content,
    // while native controls and navigation retain their normal system metrics.
    static let defaultReadingSize: Double = 13
    static func readingSize(_ requested: Double) -> CGFloat {
        CGFloat(requested.isFinite ? max(10, min(24, requested)) : defaultReadingSize)
    }
    static func readingFont(_ requested: Double, monospaced: Bool = false) -> Font {
        .system(size: readingSize(requested), design: monospaced ? .monospaced : .default)
    }
    static let compact: CGFloat = 4
    static let small: CGFloat = 8
    static let standard: CGFloat = 12
    static let spacious: CGFloat = 16

    /// The supplied words are known UI labels; recorded identifiers and content are never counted here.
    static func count(_ value: Int, singular: String, plural: String) -> String {
        LensL10n.text("{0} {1}", String(value), LensL10n.display(value == 1 ? singular : plural))
    }

    /// UI duration formatting follows Lens's selected language, not a C format
    /// or the language of the captured log. Technical IDs are never formatted.
    static func duration(_ seconds: TimeInterval, fractionDigits: Int = 2) -> String {
        let number = seconds.formatted(.number.precision(.fractionLength(fractionDigits))
            .locale(Locale(identifier: LensL10n.resolvedLanguage == .fr ? "fr" : "en")))
        return LensL10n.text("{0} s", number)
    }

    static func fileSymbol(_ path: String, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "swift", "py", "c", "h", "cpp", "hpp", "js", "ts", "rs", "sh": return "doc.text"
        default: return "doc"
        }
    }

    /// Presentation from recorded references only. A suffix suggests a format,
    /// never that the file was read, exists, or is a valid instance of that format.
    static func resourceSymbol(_ resource: ResourceRecord, isKnownDirectory: Bool = false) -> String {
        if resource.location.hasPrefix("trace:") { return "paperclip" }
        if let path = NativeFileLocation.localPath(resource.location) {
            return fileSymbol(path, isDirectory: isKnownDirectory)
        }
        if URL(string: resource.location)?.scheme != nil { return "link" }
        return "doc"
    }
    static func resourceTitle(_ resource: ResourceRecord) -> String {
        if resource.location.hasPrefix("trace:"), resource.name.isEmpty || resource.name.hasPrefix("trace:") {
            return LensL10n.text("Pièce jointe embarquée")
        }
        return resource.name
    }

    static func fileItemKind(isDirectory: Bool, isSymbolicLink: Bool) -> String {
        if isSymbolicLink { return isDirectory ? LensL10n.text("Lien symbolique vers un dossier") : LensL10n.text("Lien symbolique") }
        return isDirectory ? LensL10n.text("Dossier") : LensL10n.text("Fichier")
    }
}

/// Content headers share a leading edge and scale, without imposing a fixed
/// height on translated titles or longer descriptions.
struct LensSectionHeader: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: LensSymbols.name(symbol)).foregroundStyle(LensBrand.ink).accessibilityHidden(true)
                }
                Text(title).font(LensUI.sectionTitle).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail {
                Text(detail).font(LensUI.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Secondary content actions keep their native button role and keyboard
/// activation. Hover is local to the control, never to the session store.
struct LensQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LensQuietButton(configuration: configuration)
    }
    private struct LensQuietButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        var body: some View {
            configuration.label
                .frame(minWidth: 16, minHeight: 16)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .background(enabled && (hovered || configuration.isPressed) ? LensBrand.controlHover.opacity(configuration.isPressed ? 1.5 : 1) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if contrast == .increased, enabled && hovered {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary, lineWidth: 1)
                    }
                }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Toolbar labels respect the width proposed by AppKit, including native glass margins.
struct LensSessionToolbarTitle: View {
    let title: String
    private var subtitle: String { LensL10n.text("Lecture seule") }
    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 0, idealWidth: 240, maxWidth: 280)
        .padding(.horizontal, 10).padding(.vertical, 2)
        .help(title + "\n" + subtitle)
        .accessibilityElement(children: .ignore).accessibilityLabel(title + ". " + subtitle)
        .accessibilityIdentifier("lens-session-toolbar-title")
    }
}

/// Reflow summaries and actions rather than squeezing words or hiding controls.
struct LensAdaptiveRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                leading.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                trailing.fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                leading.fixedSize(horizontal: false, vertical: true)
                trailing.fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Empty rows have a reason; clearing restores only this collection's filters.
struct LensCollectionEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    var onClear: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: LensSymbols.name(symbol)).font(.system(size: 26, weight: .light))
                .foregroundStyle(LensBrand.ink).accessibilityHidden(true)
            LensSectionHeader(title: title, detail: detail)
            if let onClear { Button(LensL10n.text("Retirer les filtres de cette liste"), action: onClear).buttonStyle(.bordered) }
        }.frame(maxWidth: 420, alignment: .leading).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("lens-collection-empty-state")
    }
}

/// A stable-width mark supplements the tint; the owning control exposes selection.
struct LensSelectionMark: View {
    let selected: Bool
    var body: some View {
        Image(systemName: LensSymbols.name("checkmark"))
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: 12).opacity(selected ? 1 : 0).accessibilityHidden(true)
    }
}

/// Native secondary menu label. Its 24-point target remains usable with an
/// icon alone; menu items keep their full text and normal keyboard behavior.
struct LensIconMenuLabel: View {
    let symbol: String
    init(_ symbol: String = "ellipsis") { self.symbol = symbol }
    var body: some View {
        Image(systemName: LensSymbols.name(symbol)).frame(width: 24, height: 24)
    }
}

extension View {
    func lensIconMenu(_ title: String, help: String? = nil) -> some View {
        self.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .controlSize(.small).fixedSize()
            .accessibilityLabel(LensL10n.text(title))
            .help(LensL10n.text(help ?? title))
    }
}
