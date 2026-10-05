import Foundation

/// Synthetic, deterministic development data. All paths are fictional `/fixture/...` paths.
/// No file, database, network, clock or random identifier is read by this factory.
public enum LensDemoFixtures {
    public static let epoch = Date(timeIntervalSince1970: 1_790_856_000)
    public static let rootID = "fixture-session-alpha"
    public static let worktreePaths = ["/fixture/worktrees/alpha", "/fixture/worktrees/beta"]

    /// Up to 100,000 events, interleaved across eight agents and two distinct worktrees.
    /// The default 24 events includes recorded calls and their matching results.
    public static func snapshot(eventCount: Int = 24) -> SessionSnapshot {
        let count = min(100_000, max(0, eventCount))
        let agents: [AgentRecord] = (0..<8).map { number in
            let id = agentID(number)
            let relation: RelationKind = number == 0 ? .root : number == 6 ? .fork : number == 7 ? .continuation : .subagent
            return AgentRecord(id: id, parentID: number == 0 ? nil : rootID,
                               name: number == 0 ? "Agent principal" : "Agent de démonstration \(number)", relation: relation,
                               mission: number == 0 ? "Inspecter les éléments disponibles sans modifier leur environnement." : "Examiner une partie bornée des données de démonstration et rapporter les limites.",
                               missionEventID: count > number ? eventID(number) : nil,
                               evidence: "Relation explicite dans cette fixture synthétique ; aucun rattachement par dépôt commun.",
                               paths: [sourcePath(number)],
                               environmentIDs: number == 0 ? worktreePaths : [worktreePaths[number % 2]], accessible: false)
        }
        var events: [LensEvent] = []; events.reserveCapacity(count)
        var environmentEvents = [[String](), [String]()]
        for index in 0..<count {
            let number = index % 8, phase = (index / 8) % 4, round = index / 32
            let environment = (number + (number == 0 ? round : 0)) % 2
            let timestamp = epoch.addingTimeInterval(Double(round) * 5 + Double(phase) * 0.85 + Double(number) * 0.05)
            let kind: EventKind = phase == 0 ? (number == 0 ? .user : .instruction) : phase == 1 ? .toolCall : phase == 2 ? .toolResult : number == 1 ? .wait : number == 5 ? .error : .assistant
            let tool = number == 0 ? "apply_patch" : number % 2 == 0 ? "read_file" : "exec_command"
            let call = "fixture-call-\(round)-\(number)"
            let title: String
            let preview: String
            switch kind {
            case .user: title = "Demande fournie"; preview = "Comparer les traces et expliquer ce qui est confirmé, corrélé ou inconnu."
            case .instruction: title = "Mission enregistrée"; preview = agents[number].mission
            case .toolCall: title = "Appel \(tool)"; preview = number == 0 ? "Patch demandé sur Sources/Example.swift ; résultat inspecté séparément." : "Lecture de Sources/Example.swift dans le worktree explicitement associé."
            case .toolResult: title = "Résultat de \(tool)"; preview = number == 5 ? "Sortie partielle : la fin de la commande n’a pas été enregistrée." : "Résultat synthétique conservé pour vérifier l’affichage ; aucun outil n’a été exécuté."
            case .wait: title = "Attente enregistrée"; preview = "Attente d’une réponse d’agent ; cause non déduite de la proximité temporelle."
            case .error: title = "Erreur enregistrée"; preview = "Source de démonstration inaccessible ; les autres éléments restent consultables."
            default: title = "Explication enregistrée"; preview = "Les deux fichiers homonymes appartiennent à deux worktrees distincts."
            }
            let relatedIndex = phase == 2 ? round * 32 + 8 + number : phase == 1 ? round * 32 + 16 + number : -1
            let event = LensEvent(id: eventID(index), timestamp: timestamp,
                                  endTime: phase == 1 ? timestamp.addingTimeInterval(0.85) : nil,
                                  agentID: agentID(number), turnID: "fixture-turn-\(round)-\(number)", kind: kind,
                                  title: title, preview: preview, toolName: phase == 1 || phase == 2 ? tool : nil,
                                  callID: phase == 1 || phase == 2 ? call : nil,
                                  environmentID: worktreePaths[environment], resourceIDs: ["fixture-file-\(environment)"],
                                  relatedEventID: relatedIndex >= 0 && relatedIndex < count ? eventID(relatedIndex) : nil,
                                  source: SourceRef(path: sourcePath(number), length: 0, line: index / 8 + 1),
                                  isError: kind == .error)
            events.append(event); environmentEvents[environment].append(event.id)
        }
        let environments = worktreePaths.enumerated().map { index, path in
            EnvironmentRecord(path: path, repositoryPath: "/fixture/repositories/example",
                              recordedBranch: index == 0 ? "main" : "review/example",
                              recordedRef: index == 0 ? "fixture-ref-before" : "fixture-ref-after",
                              agentIDs: agents.filter { $0.environmentIDs.contains(path) }.map(\.id),
                              eventIDs: environmentEvents[index], evidence: "Worktree fictif ; identité distincte malgré le même chemin relatif.")
        }
        var resources = worktreePaths.enumerated().map { index, path in
            ResourceRecord(id: "fixture-file-\(index)", location: path + "/Sources/Example.swift", roles: [.referenced, .recordedRead],
                           agentIDs: agents.filter { $0.environmentIDs.contains(path) }.map(\.id), environmentID: path,
                           eventIDs: environmentEvents[index], evidence: "Données de galerie en mémoire ; aucun octet de fichier n’est accessible à ce chemin fictif.", availability: .unknown)
        }
        resources.append(ResourceRecord(id: "fixture-attachment", location: "/fixture/attachments/request.pdf", name: "Document fourni — octets absents",
                                        roles: [.supplied], agentIDs: [rootID], eventIDs: count > 0 ? [eventID(0)] : [],
                                        evidence: "Pièce jointe synthétique : une référence ne prouve pas la disponibilité des octets.", availability: .missing))
        var changes: [ChangeRecord] = []
        if count > 8 { changes.append(ChangeRecord(id: "fixture-change-request", path: worktreePaths[0] + "/Sources/Example.swift", environmentID: worktreePaths[0], agentID: rootID, eventID: eventID(8), kind: .requestedPatch, evidence: "Demande de patch synthétique ; ne prouve aucune écriture.")) }
        if count > 16 { changes.append(ChangeRecord(id: "fixture-change-result", path: worktreePaths[0] + "/Sources/Example.swift", environmentID: worktreePaths[0], agentID: rootID, eventID: eventID(16), kind: .recordedResult, evidence: "Résultat synthétique séparé ; le contenu actuel et l’auteur d’un diff Git ne sont pas déduits.")) }
        let cut = events.last?.timestamp ?? epoch
        let root = SessionSummary(id: rootID, title: "Session de démonstration anonymisée", cwd: worktreePaths[0], paths: [sourcePath(0)],
                                  modifiedAt: cut, cliVersion: "fixture-v1", agentName: "Agent principal", evidence: "Données de démonstration, sans lecture de session.")
        return SessionSnapshot(root: root, agents: agents, events: events, environments: environments, resources: resources, changes: changes,
                               coverage: [CoverageIssue("fixture", "Données synthétiques anonymisées. Les chemins /fixture n’existent pas et ne doivent pas être ouverts.")], collectedAt: cut)
    }

    public static func evidencePieces() -> [EvidencePiece] {
        [EvidencePiece(id: "E001", kind: "event", title: "Appel enregistré de démonstration", text: "Demande de patch ; résultat disponible séparément.",
                       eventID: eventID(8), agentID: rootID, environmentID: worktreePaths[0], knownVersion: "fixture-ref-before", capturedAt: epoch),
         EvidencePiece(id: "E002", kind: "file", title: "Sources/Example.swift — worktree beta", text: "let answer = 42\n",
                       eventID: eventID(17), agentID: agentID(1), environmentID: worktreePaths[1], knownVersion: "fixture-ref-after", capturedAt: epoch)]
    }

    public static func diffLines() -> [RecordedDiffLine] {
        [RecordedDiffLine(id: "fixture-diff-1", kind: .metadata, text: "@@ -1,2 +1,2 @@"),
         RecordedDiffLine(id: "fixture-diff-2", kind: .context, text: "struct Example {", beforeLine: 1, afterLine: 1),
         RecordedDiffLine(id: "fixture-diff-3", kind: .removed, text: "    let answer = 41", beforeLine: 2),
         RecordedDiffLine(id: "fixture-diff-4", kind: .added, text: "    let answer = 42", afterLine: 2)]
    }

    private static func agentID(_ number: Int) -> String { number == 0 ? rootID : "fixture-agent-\(number)" }
    private static func eventID(_ index: Int) -> String { "fixture-event-\(index)" }
    private static func sourcePath(_ number: Int) -> String { "/fixture/sessions/agent-\(number).jsonl" }
}
