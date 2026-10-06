import AppKit
import SwiftUI

/// Native, read-only code document. `NSRange` uses AppKit's UTF-16 offsets.
/// The supplied version label is displayed verbatim; this component never loads a file.
enum CodeTextCopyScope: Equatable { case selection, loadedText }

struct CodeDocumentView: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    @Environment(\.lensReadingMagnify) private var magnify
    var text: String
    var path: String
    var versionLabel: String
    var fontSize: Double = LensUI.defaultReadingSize
    var codeFont: LensCodeFont = .system
    var scrollToLine: Int? = nil
    var onSelection: ((NSRange, String) -> Void)? = nil
    var onLineNavigate: ((Int) -> Void)? = nil
    var onInvestigateSelection: ((NSRange, String) -> Void)? = nil
    var onCopyText: ((String, CodeTextCopyScope) -> Void)? = nil
    var loadedTextCopyLabel = LensL10n.text("Copier le texte chargé")
    var onCopyFileLine: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> CodeDocumentHost {
        let view = CodeDocumentHost(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CodeDocumentHost, context: Context) {
        accent.applyTextSelection(to: view.editor)
        view.install(text: text, path: path, versionLabel: versionLabel,
                     requestedLine: scrollToLine, fontSize: fontSize, codeFont: codeFont, onSelection: onSelection, onLineNavigate: onLineNavigate,
                     onInvestigateSelection: onInvestigateSelection, onCopyText: onCopyText,
                     loadedTextCopyLabel: loadedTextCopyLabel, onCopyFileLine: onCopyFileLine, onMagnify: magnify)
    }

    static func dismantleNSView(_ view: CodeDocumentHost, coordinator: ()) { view.cancelAnalysis() }
}

final class CodeDocumentHost: NSView, NSTextViewDelegate {
    override var isOpaque: Bool { true }
    fileprivate let scroll = NSScrollView()
    fileprivate let editor = CodeReadOnlyTextView()
    private let metadata = NSTextField(labelWithString: "")
    private let search = NSButton()
    private var gutter: CodeLineRuler!
    fileprivate var lineStarts = [0]
    fileprivate var hasLineIndex = false
    private var currentText: String?
    private var currentPath = ""
    private var versionLabel = ""
    private var syntaxLabel = ""
    private var selectionLabel = ""
    private var analysis: Task<Void, Never>?
    private var generation = 0
    private var requestedLine: Int?
    private var pendingLine: Int?
    private var onSelection: ((NSRange, String) -> Void)?
    private var onLineNavigate: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.usesFindPanel = false
        editor.font = NSFont.monospacedSystemFont(ofSize: LensUI.readingSize(LensUI.defaultReadingSize), weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.delegate = self
        editor.setAccessibilityLabel(LensL10n.text("Code en lecture seule"))
        scroll.documentView = editor
        gutter = CodeLineRuler(scrollView: scroll, owner: self)
        scroll.verticalRulerView = gutter

        metadata.translatesAutoresizingMaskIntoConstraints = false
        metadata.font = NSFont.labelFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        search.translatesAutoresizingMaskIntoConstraints = false
        search.image = NSImage(systemSymbolName: LensSymbols.name("magnifyingglass"), accessibilityDescription: LensL10n.text("Rechercher dans ce fichier"))?.withSymbolConfiguration(.preferringMonochrome())
        search.imagePosition = .imageOnly
        search.bezelStyle = .inline
        search.controlSize = .small
        search.toolTip = LensL10n.text("Rechercher dans le texte chargé (⌘F)")
        search.target = self
        search.action = #selector(showFind)

        addSubview(scroll); addSubview(metadata); addSubview(search)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -5),
            metadata.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            metadata.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            metadata.trailingAnchor.constraint(lessThanOrEqualTo: search.leadingAnchor, constant: -8),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            search.centerYAnchor.constraint(equalTo: metadata.centerYAnchor),
            search.widthAnchor.constraint(equalToConstant: 24),
            search.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { analysis?.cancel() }
    func cancelAnalysis() { analysis?.cancel(); analysis = nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    func install(text: String, path: String, versionLabel: String, requestedLine: Int?, fontSize: Double = LensUI.defaultReadingSize, codeFont: LensCodeFont = .system,
                 onSelection: ((NSRange, String) -> Void)?, onLineNavigate: ((Int) -> Void)?,
                 onInvestigateSelection: ((NSRange, String) -> Void)? = nil,
                 onCopyText: ((String, CodeTextCopyScope) -> Void)? = nil,
                 loadedTextCopyLabel: String = LensL10n.text("Copier le texte chargé"), onCopyFileLine: ((Int) -> Void)? = nil,
                 onMagnify: ((CGFloat) -> Void)? = nil) {
        search.toolTip = LensL10n.text("Rechercher dans le texte chargé (⌘F)")
        editor.setAccessibilityLabel(LensL10n.text("Code en lecture seule"))
        let font = codeFont.nativeFont(size: fontSize)
        if editor.font != font {
            let selection = editor.selectedRange()
            editor.preservingReadingAnchor {
                editor.font = font
                if let storage = editor.textStorage { storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length)) }
                gutter.updateWidth(); gutter.needsDisplay = true
                editor.setSelectedRange(selection)
            }
        }
        self.onSelection = onSelection; self.onLineNavigate = onLineNavigate
        editor.onInvestigateSelection = onInvestigateSelection
        editor.onCopyText = onCopyText; editor.loadedTextCopyLabel = loadedTextCopyLabel
        editor.onCopyFileLine = onCopyFileLine
        editor.onMagnify = onMagnify
        self.versionLabel = versionLabel
        if self.requestedLine != requestedLine {
            self.requestedLine = requestedLine; pendingLine = requestedLine
        }
        let changedText = currentText != text
        let changedPath = currentPath != path
        currentPath = path
        editor.setAccessibilityHelp(path + LensL10n.text(" · ") + versionLabel)
        metadata.toolTip = path + "\n" + versionLabel
        if changedText {
            let position = scroll.contentView.bounds.origin
            let selection = editor.selectedRange()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: editor.font ?? NSFont.monospacedSystemFont(ofSize: LensUI.readingSize(LensUI.defaultReadingSize), weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
            if let old = currentText, text.hasPrefix(old), let storage = editor.textStorage {
                let start = text.index(text.startIndex, offsetBy: old.count)
                storage.append(NSAttributedString(string: String(text[start...]), attributes: attributes))
            } else { editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes)) }
            let length = (text as NSString).length
            let offset = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: offset, length: min(selection.length, length - offset)))
            restoreViewport(position)
            currentText = text
            hasLineIndex = false
            gutter.needsDisplay = true
        }
        if changedText || changedPath {
            generation += 1
            let expectedGeneration = generation
            cancelAnalysis()
            syntaxLabel = "Indexation…"
            refreshMetadata()
            analysis = Task { [weak self] in
                let worker = Task.detached(priority: .utility) { CodeSyntax.analyze(text: text, path: path) }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.lineStarts = result.lineStarts
                self.hasLineIndex = true
                self.gutter.updateWidth()
                self.gutter.needsDisplay = true
                if let storage = self.editor.textStorage, storage.length >= result.highlightLength {
                    storage.beginEditing()
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: result.highlightLength))
                    for token in result.tokens { storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range) }
                    storage.endEditing()
                }
                self.syntaxLabel = result.language + (result.partial ? " · coloration partielle" : "")
                self.refreshMetadata()
                // Colouring and the updated ruler can complete deferred text layout.
                // Constrain the current position rather than restore an obsolete
                // anchor, so scrolling during analysis remains under user control.
                self.restoreViewport(self.scroll.contentView.bounds.origin)
                self.consumeRequestedLine()
            }
        } else {
            // SwiftUI selection, theme and metadata updates leave the document and viewport alone.
            refreshMetadata(); consumeRequestedLine()
        }
    }

    private func restoreViewport(_ origin: NSPoint) {
        let clip = scroll.contentView
        // AppKit reserves the ruler through a negative native X origin.
        // Use its constraints; forcing X = 0 can hide the start of a line.
        let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(clip)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let range = textView.selectedRange()
        let text = textView.string as NSString
        guard range.location != NSNotFound, range.location <= text.length, range.length <= text.length - range.location else { return }
        selectionLabel = range.length == 0 ? "" : LensL10n.text("Texte sélectionné")
        refreshMetadata()
        onSelection?(range, text.substring(with: range))
        gutter.needsDisplay = true
    }

    fileprivate func lineNumber(at character: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }

    fileprivate func selectLine(_ line: Int, notify: Bool) {
        guard hasLineIndex, line >= 1, line <= lineStarts.count else { return }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : (editor.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        window?.makeFirstResponder(editor)
        if notify { onLineNavigate?(line) }
    }

    private func consumeRequestedLine() {
        guard hasLineIndex, let line = pendingLine else { return }
        pendingLine = nil
        if line >= 1 && line <= lineStarts.count { selectLine(line, notify: false) }
        else { selectionLabel = LensL10n.text("Ligne {0} absente du texte chargé", String(describing: line)); refreshMetadata() }
    }

    private func refreshMetadata() {
        metadata.stringValue = [LensL10n.display(syntaxLabel), versionLabel, LensL10n.display(selectionLabel)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @objc private func showFind() {
        window?.makeFirstResponder(editor)
        editor.showNativeFind(action: .showFindInterface)
    }
}

final class CodeReadOnlyTextView: NSTextView {
    private var preservingResizeAnchor = false

    override func setFrameSize(_ newSize: NSSize) {
        // A pane resize can rewrap the text. Preserve the fragment the reader
        // was viewing, rather than its old Y coordinate or the selected text
        // (which may intentionally be outside the viewport).
        guard abs(newSize.width - frame.width) > 0.5 else { super.setFrameSize(newSize); return }
        preservingReadingAnchor { super.setFrameSize(newSize) }
    }

    func preservingReadingAnchor(_ change: () -> Void) {
        guard !preservingResizeAnchor, let scroll = enclosingScrollView, let manager = layoutManager,
              let container = textContainer, !string.isEmpty else {
            change()
            return
        }
        preservingResizeAnchor = true
        defer { preservingResizeAnchor = false }
        let oldOrigin = scroll.contentView.bounds.origin
        let visible = scroll.documentVisibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        manager.ensureLayout(forBoundingRect: visible, in: container)
        let visibleGlyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        guard visibleGlyphs.location < manager.numberOfGlyphs else {
            change()
            return
        }
        let character = manager.characterIndexForGlyph(at: visibleGlyphs.location)
        let fragment = manager.lineFragmentRect(forGlyphAt: visibleGlyphs.location, effectiveRange: nil)
        let offsetWithinFragment = oldOrigin.y - textContainerOrigin.y - fragment.minY
        change()
        guard character < (string as NSString).length else { return }
        manager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        let glyph = manager.glyphIndexForCharacter(at: character)
        guard glyph < manager.numberOfGlyphs else { return }
        let resizedFragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = scroll.contentView
        let origin = NSPoint(x: oldOrigin.x, y: resizedFragment.minY + textContainerOrigin.y + offsetWithinFragment)
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }

    var onMagnify: ((CGFloat) -> Void)?
    override func magnify(with event: NSEvent) {
        if let onMagnify { onMagnify(event.magnification) } else { super.magnify(with: event) }
    }
    var onInvestigateSelection: ((NSRange, String) -> Void)?
    var onCopyText: ((String, CodeTextCopyScope) -> Void)?
    var loadedTextCopyLabel = LensL10n.text("Copier le texte chargé")
    var onCopyFileLine: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let originalSelection = selectedRange()
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        // AppKit may select the clicked word while preparing spelling/lookup items.
        // Investigation must use the user's explicit selection, including an empty one.
        if selectedRange() != originalSelection { setSelectedRange(originalSelection) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: LensL10n.text("Demander à l’IA sur la sélection…"), action: #selector(investigateSelection(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("CodexLens.investigateSelection")
        item.isEnabled = canInvestigateSelection
        menu.addItem(item)
        if onCopyText != nil {
            let copyLoaded = NSMenuItem(title: loadedTextCopyLabel, action: #selector(copyLoadedText(_:)), keyEquivalent: "")
            copyLoaded.target = self
            copyLoaded.identifier = NSUserInterfaceItemIdentifier("CodexLens.copyLoadedCode")
            menu.addItem(copyLoaded)
        }
        if onCopyFileLine != nil {
            let copyLocation = NSMenuItem(title: LensL10n.text("Copier fichier actuel : ligne"), action: #selector(copyFileLine(_:)), keyEquivalent: "")
            copyLocation.target = self
            copyLocation.identifier = NSUserInterfaceItemIdentifier("CodexLens.copyFileLine")
            menu.addItem(copyLocation)
        }
        return menu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(investigateSelection(_:)) { return canInvestigateSelection }
        if item.action == #selector(copyLoadedText(_:)) { return onCopyText != nil }
        if item.action == #selector(copyFileLine(_:)) { return onCopyFileLine != nil && NativeFileLocation.lineNumber(in: string, atUTF16Offset: selectedRange().location) != nil }
        return super.validateUserInterfaceItem(item)
    }

    private var canInvestigateSelection: Bool {
        let range = selectedRange(), length = (string as NSString).length
        return onInvestigateSelection != nil && range.location != NSNotFound && range.length > 0 &&
               range.location <= length && range.length <= length - range.location
    }

    @objc fileprivate func investigateSelection(_ sender: Any?) {
        guard canInvestigateSelection, let onInvestigateSelection else { return }
        let range = selectedRange()
        onInvestigateSelection(range, (string as NSString).substring(with: range))
    }

    override func copy(_ sender: Any?) {
        guard let onCopyText else { super.copy(sender); return }
        let range = selectedRange(), length = (string as NSString).length
        guard range.location != NSNotFound, range.length > 0, range.location <= length, range.length <= length - range.location else { return }
        // The ruler is a separate NSView: only the exact document substring is copied.
        onCopyText((string as NSString).substring(with: range), .selection)
    }

    @objc private func copyLoadedText(_ sender: Any?) { onCopyText?(string, .loadedText) }
    @objc private func copyFileLine(_ sender: Any?) {
        guard let line = NativeFileLocation.lineNumber(in: string, atUTF16Offset: selectedRange().location) else { return }
        onCopyFileLine?(line)
    }

    func showNativeFind(action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performFindPanelAction(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers?.lowercased() == "f", !modifiers.contains(.shift) { showNativeFind(action: .showFindInterface); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "g" {
            showNativeFind(action: modifiers.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class CodeLineRuler: NSRulerView {
    private weak var owner: CodeDocumentHost?
    override var isFlipped: Bool { true }
    init(scrollView: NSScrollView, owner: CodeDocumentHost) {
        self.owner = owner
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = owner.editor
        ruleThickness = 42
        setAccessibilityLabel(LensL10n.text("Numéros de lignes ; cliquer pour sélectionner une ligne"))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func updateWidth() {
        let digits = max(3, String(owner?.lineStarts.count ?? 1).count)
        let font = numberFont()
        let measured = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        let width = max(42, ceil(measured) + 17)
        if ruleThickness != width { ruleThickness = width }
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill(); NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let owner, owner.hasLineIndex, let layout = owner.editor.layoutManager, let container = owner.editor.textContainer else { return }
        let origin = owner.editor.textContainerOrigin
        let visible = owner.editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let selected = owner.editor.selectedRange().location
        let selectedLine = selected == NSNotFound ? -1 : owner.lineNumber(at: selected)
        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { [weak self] fragment, _, _, range, _ in
                guard let self, range.location < layout.numberOfGlyphs else { return }
                let character = layout.characterIndexForGlyph(at: range.location)
                let line = owner.lineNumber(at: character)
                // Wrapped continuations have no repeated logical line number.
                guard owner.lineStarts[line - 1] == character else { return }
                self.drawNumber(line, documentY: fragment.minY + origin.y, selected: selectedLine == line)
            }
        }
        if layout.extraLineFragmentTextContainer != nil {
            let y = layout.extraLineFragmentRect.minY + origin.y
            if owner.editor.visibleRect.intersects(layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)) {
                let line = owner.lineStarts.count
                drawNumber(line, documentY: y, selected: selectedLine == line)
            }
        }
    }
    private func numberFont(selected: Bool = false) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(10, min(18, (owner?.editor.font?.pointSize ?? 13) - 2)), weight: selected ? .semibold : .regular)
    }
    private func drawNumber(_ line: Int, documentY: CGFloat, selected: Bool) {
        guard let owner else { return }
        let point = convert(NSPoint(x: 0, y: documentY), from: owner.editor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont(selected: selected),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let label = String(line) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: point.y + 1), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        guard let owner, owner.hasLineIndex, let layout = owner.editor.layoutManager, let container = owner.editor.textContainer else { return }
        let point = owner.editor.convert(event.locationInWindow, from: nil)
        let origin = owner.editor.textContainerOrigin
        let local = NSPoint(x: 0, y: max(0, point.y - origin.y))
        let glyph = layout.glyphIndex(for: local, in: container)
        let character = glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : (owner.editor.string as NSString).length
        owner.selectLine(owner.lineNumber(at: character), notify: true)
    }
}

private enum CodeTokenKind: Sendable {
    case keyword, string, number, comment
    var color: NSColor {
        switch self { case .keyword: return LensAppearance.codeKeyword; case .string: return LensAppearance.codeString; case .number: return LensAppearance.codeNumber; case .comment: return LensAppearance.codeComment }
    }
}
private struct CodeToken: Sendable { var range: NSRange; var kind: CodeTokenKind }
private struct CodeSyntaxResult: Sendable {
    var lineStarts: [Int]
    var tokens: [CodeToken]
    var highlightLength: Int
    var language: String
    var partial: Bool
}
private enum CodeSyntax {
    static func analyze(text: String, path: String) -> CodeSyntaxResult {
        let limit = 262144
        var starts = [0], offset = 0, previousCR = false
        for unit in text.utf16 {
            offset += 1
            if offset % 4096 == 0 && Task.isCancelled { return CodeSyntaxResult(lineStarts: starts, tokens: [], highlightLength: 0, language: "Texte", partial: true) }
            if unit == 10 && previousCR { starts[starts.count - 1] = offset }
            else if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { starts.append(offset) }
            previousCR = unit == 13
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let profile: (String, String, String)?
        switch ext {
        case "swift": profile = ("Swift", "actor async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init internal is let nil open private protocol public repeat rethrows return self static struct subscript super switch throw throws true try typealias var weak where while", #"//[^\n]*|/\*[\s\S]*?\*/"#)
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hxx", "m", "mm": profile = ("C / C++", "alignas auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend if include inline int long namespace new nullptr private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while", #"//[^\n]*|/\*[\s\S]*?\*/"#)
        case "py", "pyi": profile = ("Python", "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield", #"#[^\n]*"#)
        case "js", "jsx", "ts", "tsx": profile = ("JavaScript / TypeScript", "as async await break case catch class const continue debugger default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public return static super switch this throw true try typeof undefined var void while yield", #"//[^\n]*|/\*[\s\S]*?\*/"#)
        case "rs": profile = ("Rust", "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while", #"//[^\n]*|/\*[\s\S]*?\*/"#)
        case "go": profile = ("Go", "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var", #"//[^\n]*|/\*[\s\S]*?\*/"#)
        case "sh", "bash", "zsh", "fish": profile = ("Shell", "case do done elif else esac export fi for function if in local return then until while", #"#[^\n]*"#)
        case "json", "jsonl": profile = ("JSON", "true false null", "(?!)")
        case "yaml", "yml", "toml", "ini", "conf": profile = (ext.uppercased(), "true false null yes no", #"#[^\n]*"#)
        default: profile = nil
        }
        let source = text as NSString
        var length = min(limit, source.length)
        if length < source.length, length > 0, (0xD800...0xDBFF).contains(source.character(at: length - 1)) { length -= 1 }
        guard let profile else { return CodeSyntaxResult(lineStarts: starts, tokens: [], highlightLength: length, language: "Texte", partial: false) }
        let prefix = source.substring(with: NSRange(location: 0, length: length))
        let range = NSRange(location: 0, length: length)
        var tokens: [CodeToken] = []
        let patterns: [(String, CodeTokenKind, String)] = [
            ("comment", .comment, profile.2),
            ("string", .string, #"\"(?:[^\"\\\n]|\\.)*\"|'(?:[^'\\\n]|\\.)*'"#),
            ("keyword", .keyword, "\\b(?:" + profile.1.split(separator: " ").joined(separator: "|") + ")\\b"),
            ("number", .number, #"\b(?:0[xX][0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\b"#)
        ]
        var capped = false
        let expression = patterns.map { "(?<" + $0.0 + ">" + $0.2 + ")" }.joined(separator: "|")
        if let regex = try? NSRegularExpression(pattern: expression) {
            regex.enumerateMatches(in: prefix, range: range) { match, _, stop in
                guard let match else { return }
                if tokens.count >= 12000 || Task.isCancelled { capped = true; stop.pointee = true; return }
                for (name, kind, _) in patterns {
                    let tokenRange = match.range(withName: name)
                    if tokenRange.location != NSNotFound { tokens.append(CodeToken(range: tokenRange, kind: kind)); break }
                }
            }
        }
        return CodeSyntaxResult(lineStarts: starts, tokens: tokens, highlightLength: length,
                                language: profile.0, partial: source.length > length || capped)
    }
}
