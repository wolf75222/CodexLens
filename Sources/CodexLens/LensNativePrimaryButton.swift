import AppKit
import SwiftUI

/// An owned native default button. AppKit keeps Return, focus, accessibility
/// and disabled feedback; bezelColor follows Lens instead of the system blue.
struct LensNativePrimaryButton: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    let title: String
    var isDefault = false
    let action: () -> Void
    func makeNSView(context: Context) -> NSButton {
        let button = LensAccentPrimaryButton()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        (button as? LensAccentPrimaryButton)?.onPress = action
        button.title = title; button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        button.bezelColor = accent == .system ? nil : accent.filledNSColor
        button.keyEquivalent = isDefault ? "\r" : ""
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The control owns its callback and target for its whole native lifetime.
final class LensAccentPrimaryButton: NSButton {
    var onPress: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); target = self; action = #selector(invoke(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke(_ sender: Any?) { guard isEnabled else { return }; onPress?() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; performClick(nil); return true
    }
}
