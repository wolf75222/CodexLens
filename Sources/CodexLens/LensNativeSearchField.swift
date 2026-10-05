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
    let placeholder: String
    @Binding var text: String
    var accessibilityLabel: String? = nil
    var focused: Binding<Bool>? = nil
    var onChange: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
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
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.focus(field)
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.focusTask?.cancel()
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
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused?.wrappedValue = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused?.wrappedValue = false }
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
