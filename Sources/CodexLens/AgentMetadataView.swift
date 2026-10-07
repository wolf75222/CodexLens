import SwiftUI
import LensCore

/// A compact role label from recorded attributes. A requested role is never
/// presented as an observed agent configuration.
struct AgentRoleCaption: View {
    @AppStorage("lens.language") private var language = "en"
    let agent: AgentRecord
    private func label(_ french: String, _ value: String) -> String {
        LensL10n.text(french, in: LensL10n.Language(rawValue: language) ?? .system)
            .replacingOccurrences(of: "{0}", with: value)
    }
    var body: some View {
        if let role = AgentMetadataField.preferredRole(in: agent.metadata ?? []) {
            Text(role.origin == .delegationRequest
                 ? label("Rôle demandé : {0}", role.value) : role.value)
                .font(LensUI.metadata).lineLimit(1).truncationMode(.middle)
                .help(role.origin == .delegationRequest
                      ? label("Rôle demandé : {0}", role.value)
                      : label("Rôle enregistré : {0}", role.value))
                .accessibilityLabel(role.origin == .delegationRequest
                                    ? label("Rôle demandé : {0}", role.value)
                                    : label("Rôle enregistré : {0}", role.value))
        }
    }
}

/// Displays bounded allowlisted fields. Complete instructions stay in their
/// recorded events and are opened only through the existing event reader.
struct AgentMetadataView: View {
    @EnvironmentObject var store: LensStore
    @AppStorage("lens.language") private var language = "en"
    let agent: AgentRecord
    private func label(_ french: String) -> String {
        LensL10n.text(french, in: LensL10n.Language(rawValue: language) ?? .system)
    }
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
            Text(label("Informations sur l’agent")).font(.headline)
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
                        Text(label("Extrait")).font(LensUI.metadata).foregroundStyle(.secondary)
                    }
                    sourceAvailability(field)
                }.contextMenu {
                    if let id = sourceEventID(field, baseEvents: baseEvents) {
                        sourceButton(id, title: label("Ouvrir le message source"))
                    }
                }
            }
            if fields.contains(where: { $0.origin == .threadMetadata && ($0.kind == .model || $0.kind == .reasoningEffort) }) {
                Text(label("Le modèle et l’effort du thread indiquent sa dernière configuration enregistrée. Le détail de chaque requête peut manquer."))
                    .font(LensUI.metadata).foregroundStyle(.secondary)
            }
            if !sourcePaths.isEmpty {
                DisclosureGroup(label("Sources")) {
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
                DisclosureGroup(label("Messages source")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(linkedIDs, id: \.self) { id in
                            sourceButton(id, title: store.event(id).map { LensL10n.display($0.title) }
                                         ?? label("Ouvrir le message source"))
                        }
                    }.padding(.top, 6)
                }.font(LensUI.metadata)
            }
            ForEach(baseEvents) { event in
                Button {
                    store.navigate(.event(event.id), newTab: true)
                } label: {
                    Label(label("Ouvrir les instructions de base"), systemImage: LensSymbols.name("doc.text"))
                }.buttonStyle(.borderless).font(LensUI.metadata)
                    .accessibilityIdentifier("lens-agent-base-instructions")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missing(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.label(label)).font(LensUI.metadata).foregroundStyle(.secondary)
            Text(self.label(value)).font(LensUI.body).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func sourceAvailability(_ field: AgentMetadataField) -> some View {
        if field.sourcePath.isEmpty, field.source?.path.isEmpty != false {
            Text(label("Source non indiquée")).font(LensUI.metadata).foregroundStyle(.secondary)
        }
        if let id = field.eventID, store.event(id) == nil {
            Text(label("Message source indisponible")).font(LensUI.metadata).foregroundStyle(.secondary)
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
            if field.value == "true" { return label("Oui") }
            if field.value == "false" { return label("Non") }
        }
        return field.value
    }
    private func origin(_ origin: AgentMetadataField.Origin) -> String {
        switch origin {
        case .sessionMetadata: return label("Session")
        case .threadMetadata: return label("Thread")
        case .delegationRequest: return label("Demandé")
        }
    }
    private func title(_ kind: AgentMetadataField.Kind) -> String {
        switch kind {
        case .role: return label("Rôle")
        case .description: return label("Description")
        case .model: return label("Modèle")
        case .reasoningEffort: return label("Effort de raisonnement")
        case .modelProvider: return label("Fournisseur")
        case .taskName: return label("Nom de tâche")
        case .forkContext: return label("Contexte hérité")
        case .cliVersion: return label("Version de Codex")
        }
    }
}
