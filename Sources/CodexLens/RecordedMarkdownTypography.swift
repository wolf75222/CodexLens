import AppKit
import LensCore

/// Native selectable text, keeping Find, Copy and the scroll position. The model
/// was parsed off MainActor; only bounded font/paragraph attributes are made here.
enum RecordedMarkdownTypography {
    static func render(_ document: ChatMarkdownDocument, fontSize: Double, codeFont: LensCodeFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let size = LensUI.readingSize(fontSize)
        for block in document.blocks {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            let start = result.length
            let font: NSFont
            switch block.kind {
            case .heading(let level): font = .systemFont(ofSize: size + (level <= 2 ? 5 : 2), weight: .semibold)
            case .code, .table: font = codeFont.nativeFont(size: fontSize)
            default: font = .systemFont(ofSize: size)
            }
            if let marker = block.listMarker { result.append(NSAttributedString(string: marker + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor])) }
            result.append(NSAttributedString(block.text))
            let range = NSRange(location: start, length: result.length - start)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 4
            paragraph.headIndent = CGFloat(block.listDepth + block.quoteDepth) * 14
            paragraph.firstLineHeadIndent = paragraph.headIndent
            result.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: range)
            var offset = start + (block.listMarker.map { (($0 + " ") as NSString).length } ?? 0)
            for run in block.text.runs {
                let runText = String(block.text[run.range].characters)
                let runRange = NSRange(location: offset, length: (runText as NSString).length)
                let intent = run.inlinePresentationIntent ?? []
                var styled = intent.contains(.code) ? codeFont.nativeFont(size: fontSize) : font
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { styled = NSFontManager.shared.convert(styled, toHaveTrait: traits) }
                result.addAttribute(.font, value: styled, range: runRange)
                offset += runRange.length
            }
        }
        return result
    }
}
