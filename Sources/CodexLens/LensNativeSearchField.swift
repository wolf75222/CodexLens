import AppKit
import SwiftUI

extension Notification.Name {
    static let lensFocusAgentSearch = Notification.Name("CodexLens.focusAgentSearch")
}

private struct LensReadingMagnifyKey: EnvironmentKey {
    static let defaultValue: ((CGFloat) -> Void)? = nil
}
extension EnvironmentValues {
    var lensReadingMagnify: ((CGFloat) -> Void)? {
        get { self[LensReadingMagnifyKey.self] }
        set { self[LensReadingMagnifyKey.self] = newValue }
    }
}

/// One native search control, including its search and clear affordances. Queries
/// remain in this window; AppKit's persistent recent-search store is disabled.
struct LensNativeSearchField: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    let placeholder: String
    @Binding var text: String
    var accessibilityLabel: String? = nil
    var focused: Binding<Bool>? = nil
    var onChange: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = LensAccentSearchField()
        field.controlSize = .regular
        field.maximumRecents = 0
        field.recentsAutosaveName = nil
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if let field = field as? LensAccentSearchField { field.accent = accent; field.applyEditorAccent() }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.focus(field)
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.focusTask?.cancel()
        (field as? LensAccentSearchField)?.restoreEditorAccent()
        field.delegate = nil; field.target = nil
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LensNativeSearchField
        var focusTask: Task<Void, Never>?
        init(_ parent: LensNativeSearchField) { self.parent = parent }
        func focus(_ field: NSSearchField) {
            guard parent.focused?.wrappedValue == true, field.currentEditor() == nil else { return }
            focusTask?.cancel()
            focusTask = Task { @MainActor [weak self, weak field] in
                await Task.yield()
                guard !Task.isCancelled, self?.parent.focused?.wrappedValue == true, let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, parent.text != field.stringValue else { return }
            parent.text = field.stringValue; parent.onChange?()
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? LensAccentSearchField)?.applyEditorAccent()
            parent.focused?.wrappedValue = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? LensAccentSearchField)?.restoreEditorAccent()
            parent.focused?.wrappedValue = false
        }
        @objc func submit(_ sender: NSSearchField) {
            // The native cancel cell sends the action without a text-edit delegate callback.
            if parent.text != sender.stringValue {
                parent.text = sender.stringValue; parent.onChange?()
            }
            // AppKit may invoke the search action after a change as well as Return.
            // Only Return triggers an explicit expensive search/open operation.
            if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 36 { parent.onSubmit?() }
        }
    }
}

/// Only this owned search field replaces the system ring. The real field
/// editor/selection, native search/cancel cells and accessibility stay intact.
final class LensAccentSearchField: NSSearchField {
    var accent: LensControlAccent = .lens {
        didSet { focusRingType = accent == .system ? .default : .none; updateFocusBorder() }
    }
    private weak var styledEditor: NSTextView?
    private var originalInsertion: NSColor?
    private var originalSelection: [NSAttributedString.Key: Any]?
    func applyEditorAccent() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if styledEditor !== editor {
            restoreEditorAccent(); styledEditor = editor
            originalInsertion = editor.insertionPointColor; originalSelection = editor.selectedTextAttributes
        }
        accent.applyTextSelection(to: editor); editor.needsDisplay = true; updateFocusBorder()
    }
    func restoreEditorAccent() {
        if let editor = styledEditor {
            if let color = originalInsertion { editor.insertionPointColor = color }
            if let attributes = originalSelection { editor.selectedTextAttributes = attributes }
            editor.needsDisplay = true
        }
        styledEditor = nil; originalInsertion = nil; originalSelection = nil; updateFocusBorder()
    }
    private func updateFocusBorder() {
        wantsLayer = true
        let focused = accent != .system && isEnabled && styledEditor != nil
        layer?.cornerRadius = max(4, bounds.height / 2)
        layer?.borderWidth = focused ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 3 : 2) : 0
        // Layer colors are resolved only for this current appearance, then
        // refreshed on every theme/accent/focus change; no global CGColor cache.
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = accent.nsColor.cgColor }
        needsDisplay = true
    }
    override func layout() { super.layout(); updateFocusBorder() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFocusBorder() }
}
