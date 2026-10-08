import AppKit
import SwiftUI

/// AppKit retains text selection, undo, paste and input-method composition.
/// Only an explicit Return in this editor submits a message.
struct LensChatInput: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    @Binding var text: String
    let fontSize: CGFloat
    let enabled: Bool
    let canSend: Bool
    let label: String
    let focused: Binding<Bool>
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = LensChatInputTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? LensChatInputTextView else { return }
        context.coordinator.parent = self
        editor.submit = onSend
        editor.canSubmit = canSend
        editor.isEditable = enabled
        editor.isSelectable = true
        editor.font = .systemFont(ofSize: LensUI.readingSize(Double(fontSize)))
        editor.textColor = .textColor
        accent.applyTextSelection(to: editor)
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier("lens-chat-composer")
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
        context.coordinator.focus(editor)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.focusTask?.cancel()
        if let editor = scroll.documentView as? LensChatInputTextView {
            editor.delegate = nil
            editor.submit = nil
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LensChatInput
        var focusTask: Task<Void, Never>?
        init(_ parent: LensChatInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, parent.text != editor.string else { return }
            parent.text = editor.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused.wrappedValue = false }
        func focus(_ editor: NSTextView) {
            guard parent.focused.wrappedValue, parent.enabled, editor.window?.firstResponder !== editor else { return }
            focusTask?.cancel()
            focusTask = Task { @MainActor [weak self, weak editor] in
                await Task.yield()
                guard !Task.isCancelled, self?.parent.focused.wrappedValue == true,
                      self?.parent.enabled == true, let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
    }
}

final class LensChatInputTextView: NSTextView {
    var submit: (() -> Void)?
    var canSubmit = false

    static func isSubmitKey(_ event: NSEvent, composing: Bool) -> Bool {
        guard !composing, event.keyCode == 36 || event.keyCode == 76 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control)
    }

    override func keyDown(with event: NSEvent) {
        if isEditable, Self.isSubmitKey(event, composing: hasMarkedText()) {
            if canSubmit { submit?() }
            return
        }
        super.keyDown(with: event)
    }
}
