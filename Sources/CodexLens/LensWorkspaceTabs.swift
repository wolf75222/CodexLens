import SwiftUI

/// The active tab stays visible; overflow uses one native menu, never a scroll track.
struct LensWorkspaceTabs: View {
    @ObservedObject var store: LensStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(visibleTabs, titleWidth: 180)
            row(activeTabs, titleWidth: 180)
            row(activeTabs, titleWidth: 100)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeTabs: [LensTab] {
        if let active = store.tabs.first(where: { $0.id == store.activeTab }) { return [active] }
        return Array(store.tabs.suffix(1))
    }

    private var visibleTabs: [LensTab] {
        let active = activeTabs.first
        let other = store.tabs.first { $0.id != active?.id }
        let ids = Set([active?.id, other?.id].compactMap { $0 })
        return store.tabs.filter { ids.contains($0.id) }
    }

    private func row(_ tabs: [LensTab], titleWidth: CGFloat) -> some View {
        LensNavigationEffectGroup(spacing: 8) {
            HStack(spacing: 8) {
                if store.hasWorkspaceReturn {
                    Button { store.showWorkspace() } label: {
                        Label(LensL10n.display(store.workspaceSection.rawValue), systemImage: store.workspaceSection.symbol)
                            .frame(minHeight: 24)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
                    .lensNavigationItem(selected: store.workspacePresented)
                    .accessibilityAddTraits(store.workspacePresented ? .isSelected : [])
                    .help(LensL10n.text("Retrouver la vue et la position de lecture"))
                    .accessibilityIdentifier("lens-tabs-workspace")
                }
                ForEach(tabs) { tab in tabItem(tab, titleWidth: titleWidth) }
                if store.tabs.count > tabs.count {
                    overflow()
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
    }

    private func tabItem(_ tab: LensTab, titleWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            if tab.pinned {
                Image(systemName: LensSymbols.name("pin.fill")).font(LensUI.metadata)
                    .foregroundStyle(.secondary).accessibilityLabel(LensL10n.text("Onglet épinglé"))
            }
            Button { store.selectTab(tab) } label: {
                Text(store.label(tab.destination)).fontWeight(store.isTabPresented(tab) ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: titleWidth, minHeight: 24)
            }
            .buttonStyle(.plain).help(store.label(tab.destination))
            .accessibilityAddTraits(store.isTabPresented(tab) ? .isSelected : [])
            .accessibilityIdentifier("lens-tab-" + tab.id.uuidString)
            Button { store.closeTab(tab.id) } label: {
                Image(systemName: LensSymbols.name("xmark"))
                    .font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(LensL10n.text("Fermer cet onglet"))
            .accessibilityLabel(LensL10n.text("Fermer « {0} »", store.label(tab.destination)))
            .accessibilityIdentifier("lens-tab-close-" + tab.id.uuidString)
        }
        .fixedSize(horizontal: true, vertical: false).padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .lensNavigationItem(selected: store.isTabPresented(tab))
        .contextMenu {
            LensActionButton(store: store, action: .openInNewWindow, target: tab.destination)
            Button(tab.pinned ? LensL10n.text("Désépingler") : LensL10n.text("Épingler cet onglet")) { store.pinTab(tab.id) }
            LensActionButton(store: store, action: .bookmark, target: tab.destination)
            LensActionButton(store: store, action: .copyLink, target: tab.destination)
            LensQuestionMenu(store: store, target: tab.destination)
        }
    }

    private func overflow() -> some View {
        Menu {
            ForEach(store.tabs) { tab in
                Button { store.selectTab(tab) } label: {
                    Label(store.label(tab.destination), systemImage: tab.id == store.activeTab ? "checkmark" : "doc")
                }
            }
        } label: { LensIconMenuLabel() }
        .lensIconMenu("Autres onglets").lensChromeMenu()
        .accessibilityIdentifier("lens-tab-overflow")
    }
}
