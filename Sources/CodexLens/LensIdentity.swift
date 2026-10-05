import SwiftUI

/// Text-only heading for guidance screens; the app icon belongs to macOS.
struct LensIdentityHeader: View {
    let subtitle: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Codex Lens").font(.system(size: compact ? 16 : 22, weight: .semibold))
            Text(subtitle).font(compact ? LensUI.metadata : LensUI.body).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : nil).truncationMode(.tail).help(subtitle)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}
