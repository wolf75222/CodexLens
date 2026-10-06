import SwiftUI
import LensCore

/// A compact role label from recorded attributes. A requested role is never
/// presented as an observed agent configuration.
struct AgentRoleCaption: View {
    let agent: AgentRecord
    var body: some View {
        if let role = AgentMetadataField.preferredRole(in: agent.metadata ?? []) {
            Text(role.origin == .delegationRequest
                 ? LensL10n.text("Rôle demandé : {0}", role.value) : role.value)
                .font(LensUI.metadata).lineLimit(1).truncationMode(.middle)
                .help(role.origin == .delegationRequest
                      ? LensL10n.text("Rôle demandé : {0}", role.value)
                      : LensL10n.text("Rôle enregistré : {0}", role.value))
                .accessibilityLabel(role.origin == .delegationRequest
                                    ? LensL10n.text("Rôle demandé : {0}", role.value)
                                    : LensL10n.text("Rôle enregistré : {0}", role.value))
        }
    }
}

/// Displays bounded allowlisted fields. Complete instructions stay in their
/// recorded events and are opened only through the existing event reader.
struct AgentMetadataView: View {
    @EnvironmentObject var store: LensStore
    let agent: AgentRecord
    private static let fieldOrder: [AgentMetadataField.Kind] = [
        .role, .description, .model, .reasoningEffort, .modelProvider,
        .taskName, .forkContext, .cliVersion
    ]
    private var fields: [AgentMetadataField] {
        // Preserve the recorded order within each kind, including conflicts.
        (agent.metadata ?? []).enumerated().sorted { lhs, rhs in
            let left = Self.fieldOrder.firstIndex(of: lhs.element.kind) ?? Self.fieldOrder.count
            let right = Self.fieldOrder.firstIndex(of: rhs.element.kind) ?? Self.fieldOrder.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
    private var sourcePaths: [String] {
        var paths: [String] = [], seen: Set<String> = []
        for field in fields {
            let path = field.source?.path ?? field.sourcePath
            if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }
    private var baseInstructionEvents: [LensEvent] {
        (store.presentation?.communicationInspection.instructions ?? [])
            .filter { $0.agentID == agent.id && $0.kind == .base }
            .compactMap { store.event($0.eventID) }
            .filter { $0.agentID == agent.id && $0.kind == .instruction && $0.source.line == 1 }
    }

    var body: some View {
        let baseEvents = baseInstructionEvents
        let linkedIDs = sourceEventIDs(baseEvents)
        VStack(alignment: .leading, spacing: 12) {
            Text(LensL10n.text("Informations sur l’agent")).font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("lens-agent-metadata")
            if !fields.contains(where: { $0.kind == .role }) {
                missing("Rôle", value: "Non enregistré")
            }
            if !fields.contains(where: { $0.kind == .description }) {
                missing("Description", value: "Non enregistrée")
            }
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title(field.kind)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(origin(field.origin)).foregroundStyle(.secondary)
                    }.font(LensUI.metadata)
                    Text(value(field)).font(LensUI.readingFont(store.fontSize))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if field.isTruncated == true {
                        Text(LensL10n.text("Extrait")).font(LensUI.metadata).foregroundStyle(.secondary)
                    }
                    sourceAvailability(field)
                }.contextMenu {
                    if let id = sourceEventID(field, baseEvents: baseEvents) {
                        sourceButton(id, title: LensL10n.text("Ouvrir le message source"))
                    }
                }
            }
            if fields.contains(where: { $0.origin == .threadMetadata && ($0.kind == .model || $0.kind == .reasoningEffort) }) {
                Text(LensL10n.text("Le modèle et l’effort du thread indiquent sa dernière configuration enregistrée. Le détail de chaque requête peut manquer."))
                    .font(LensUI.metadata).foregroundStyle(.secondary)
            }
            if !sourcePaths.isEmpty {
                DisclosureGroup(LensL10n.text("Sources")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sourcePaths, id: \.self) { path in
                            Text(path).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(path)
                        }
                    }.padding(.top, 6)
                }.font(LensUI.metadata)
            }
            if !linkedIDs.isEmpty {
                DisclosureGroup(LensL10n.text("Messages source")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(linkedIDs, id: \.self) { id in
                            sourceButton(id, title: store.event(id).map { LensL10n.display($0.title) }
                                         ?? LensL10n.text("Ouvrir le message source"))
                        }
                    }.padding(.top, 6)
                }.font(LensUI.metadata)
            }
            ForEach(baseEvents) { event in
                Button {
                    store.navigate(.event(event.id), newTab: true)
                } label: {
                    Label(LensL10n.text("Ouvrir les instructions de base"), systemImage: LensSymbols.name("doc.text"))
                }.buttonStyle(.borderless).font(LensUI.metadata)
                    .accessibilityIdentifier("lens-agent-base-instructions")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missing(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LensL10n.text(label)).font(LensUI.metadata).foregroundStyle(.secondary)
            Text(LensL10n.text(value)).font(LensUI.body).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func sourceAvailability(_ field: AgentMetadataField) -> some View {
        if field.sourcePath.isEmpty, field.source?.path.isEmpty != false {
            Text(LensL10n.text("Source non indiquée")).font(LensUI.metadata).foregroundStyle(.secondary)
        }
        if let id = field.eventID, store.event(id) == nil {
            Text(LensL10n.text("Message source indisponible")).font(LensUI.metadata).foregroundStyle(.secondary)
        }
    }
    private func sourceButton(_ id: String, title: String) -> some View {
        Button { store.navigate(.event(id), newTab: true) } label: {
            Label(title, systemImage: LensSymbols.name("link")).lineLimit(2)
        }.buttonStyle(.borderless).font(LensUI.metadata)
            .accessibilityIdentifier("lens-agent-metadata-source")
    }
    private func sourceEventID(_ field: AgentMetadataField, baseEvents: [LensEvent]) -> String? {
        if let id = field.eventID, store.event(id) != nil { return id }
        guard let recorded = field.source, let digest = recorded.sha256,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        // A path/line can now refer to a different header. Link only the exact
        // captured range and digest, never a newer instruction at that path.
        return baseEvents.first(where: { $0.source == recorded })?.id
    }
    private func sourceEventIDs(_ baseEvents: [LensEvent]) -> [String] {
        var ids: [String] = []
        for field in fields {
            if let id = sourceEventID(field, baseEvents: baseEvents), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
    private func value(_ field: AgentMetadataField) -> String {
        if field.kind == .forkContext {
            if field.value == "true" { return LensL10n.text("Oui") }
            if field.value == "false" { return LensL10n.text("Non") }
        }
        return field.value
    }
    private func origin(_ origin: AgentMetadataField.Origin) -> String {
        switch origin {
        case .sessionMetadata: return LensL10n.text("Session")
        case .threadMetadata: return LensL10n.text("Thread")
        case .delegationRequest: return LensL10n.text("Demandé")
        }
    }
    private func title(_ kind: AgentMetadataField.Kind) -> String {
        switch kind {
        case .role: return LensL10n.text("Rôle")
        case .description: return LensL10n.text("Description")
        case .model: return LensL10n.text("Modèle")
        case .reasoningEffort: return LensL10n.text("Effort de raisonnement")
        case .modelProvider: return LensL10n.text("Fournisseur")
        case .taskName: return LensL10n.text("Nom de tâche")
        case .forkContext: return LensL10n.text("Contexte hérité")
        case .cliVersion: return LensL10n.text("Version de Codex")
        }
    }
}
