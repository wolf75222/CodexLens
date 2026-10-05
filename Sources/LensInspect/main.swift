import Foundation
import Dispatch
import LensCore

@main struct InspectMain {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let home = CodexSourceLocation.observationHome()
            let engine = SessionEngine(home: home)
            guard let command = args.first else { print("lens-inspect catalog | session ID [--report PATH] [--watch SECONDS] [--inspection-benchmark] [--origin-path PATH --origin-report PATH]"); return }
            if command == "catalog" {
                let rows = try await engine.catalog()
                print("\(rows.count) threads locaux")
                for row in rows.prefix(25) { print("\(row.id)\t\(row.relation.rawValue)\t\(row.title.prefix(120))") }; return
            }
            guard command == "session", args.count >= 2 else { throw LensError.unsupported("Commande inconnue") }
            if args.contains("--inspection-benchmark") {
                guard let explicitHome = ProcessInfo.processInfo.environment["LENS_CODEX_HOME"], !explicitHome.isEmpty else {
                    throw LensError.unsupported("--inspection-benchmark nécessite LENS_CODEX_HOME explicite pour borner les sources mesurées.")
                }
                guard !args.contains("--watch") else { throw LensError.unsupported("Le benchmark d’inspection utilise un instantané fixe ; --watch doit être lancé séparément.") }
                let report = try await inspectionBenchmark(home: home, id: args[1])
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                if let i = args.firstIndex(of: "--report") {
                    guard i + 1 < args.count else { throw LensError.unsupported("--report nécessite un chemin.") }
                    try data.write(to: URL(fileURLWithPath: args[i + 1]), options: .atomic)
                }
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let began = Date()
            let snapshot = try await engine.open(id: args[1])
            let presentation = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters())
            if let pathIndex = args.firstIndex(of: "--origin-path"), pathIndex + 1 < args.count {
                let path = args[pathIndex + 1]
                guard let change = snapshot.changes.last(where: { $0.path == path }),
                      let origin = presentation.originInspection.selection(objectID: OriginInspectionIndex.changeID(change.id)),
                      let reportIndex = args.firstIndex(of: "--origin-report"), reportIndex + 1 < args.count else {
                    throw LensError.unavailable("Modification exacte ou destination --origin-report introuvable.")
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(origin).write(to: URL(fileURLWithPath: args[reportIndex + 1]), options: .atomic)
            }
            let files = FileService()
            var checks: [[String: Any]] = []
            for call in snapshot.events.filter({ $0.toolName != nil && $0.kind != .toolResult }).prefix(3) {
                let detail = try await engine.detail(for: call)
                checks.append(["eventID": call.id, "tool": call.toolName ?? "", "agentID": call.agentID, "argumentCharacters": detail.arguments.count, "outputCharacters": detail.output.count, "rawCharacters": detail.raw.count, "environment": call.environmentID ?? "", "sourceLine": call.source.line])
            }
            var fileChecks: [[String: Any]] = []
            for resource in snapshot.resources.filter({ $0.roles.contains(.supplied) || $0.roles.contains(.recordedRead) }).prefix(6) {
                var check: [String: Any] = ["location": resource.location, "roles": resource.roles.map(\.rawValue), "sourceEvents": resource.eventIDs.count, "environment": resource.environmentID ?? ""]
                if resource.location.hasPrefix("/") {
                    do {
                        _ = try await files.previewURL(path: resource.location)
                        check["accessibleNow"] = true
                        if let page = try? await files.readText(path: resource.location) { check["currentBytes"] = page.totalBytes; check["currentPageCharacters"] = page.text.count }
                    } catch { check["accessibleNow"] = false; check["reason"] = error.localizedDescription }
                } else { check["accessibleNow"] = false }
                fileChecks.append(check)
            }
            var delta = 0
            if let i = args.firstIndex(of: "--watch"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
                let deadline = Date().addingTimeInterval(max(0, min(seconds, 300)))
                var latestCount = snapshot.events.count
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if let update = try await engine.refresh() { delta += max(0, update.events.count - latestCount); latestCount = update.events.count }
                }
            }
            let report: [String: Any] = [
                "rootID": snapshot.root.id, "sessionID": snapshot.root.sessionID, "adapterCLI": snapshot.root.cliVersion,
                "agents": snapshot.agents.map { ["id": $0.id, "parentID": $0.parentID ?? "", "relation": $0.relation.rawValue, "accessible": $0.accessible] as [String: Any] },
                "eventCount": snapshot.events.count, "environmentCount": snapshot.environments.count,
                "resourceCount": snapshot.resources.count, "suppliedResourceCount": snapshot.resources.filter { $0.roles.contains(.supplied) }.count,
                "changeCount": snapshot.changes.count, "coverage": snapshot.coverage.map { ["category": $0.category, "message": $0.message, "source": $0.source] },
                "toolChecks": checks, "fileChecks": fileChecks, "liveNewEvents": delta,
                "inspectionV20": inspectionSummary(presentation),
                "originInspection": ["objectCount": presentation.originInspection.objectsByID.count, "linkCount": presentation.originInspection.links.count],
                "elapsedSeconds": Date().timeIntervalSince(began), "collectedAt": ISO8601DateFormatter().string(from: snapshot.collectedAt)
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let i = args.firstIndex(of: "--report"), i + 1 < args.count { try data.write(to: URL(fileURLWithPath: args[i + 1])); print("Rapport: \(args[i + 1])") }
            print("Session \(snapshot.root.id): \(snapshot.agents.count) agents, \(snapshot.events.count) événements, \(snapshot.environments.count) environnements, \(snapshot.resources.count) ressources (\(snapshot.resources.filter { $0.roles.contains(.supplied) }.count) fournies), \(snapshot.changes.count) changements, \(snapshot.coverage.count) limites, +\(delta) événements suivis")
            print("Inspection .20: \(presentation.contextInspection.identifiedOperationCount) compactages identifiés, \(presentation.communicationInspection.communications.count) communications, \(presentation.activityEvidence.tests.count) observations de commandes de test avec preuve liée, \(presentation.activityEvidence.repeatedCallGroups.count) groupes d’appels identiques")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func inspectionSummary(_ presentation: SessionPresentation) -> [String: Any] {
        let context = presentation.contextInspection
        let communication = presentation.communicationInspection
        let activity = presentation.activityEvidence
        let observations = Dictionary(activity.observationsByEventID.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        return [
            "context": [
                "identifiedOperationCount": context.identifiedOperationCount,
                "installedCompactionCount": context.installedCompactionCount,
                "representationGroupCount": context.compactions.count,
                "confirmedAssociationCount": context.compactions.filter { $0.association == .confirmed }.count,
                "sourceOrderCorrelationCount": context.compactions.filter { $0.association == .sourceOrderCorrelation }.count,
                "unassociatedCount": context.compactions.filter { $0.association == .unassociated }.count,
                "opaqueOrMixedGroupCount": context.compactions.filter { $0.visibility == .opaque || $0.visibility == .mixed }.count,
                "usageSampleCount": context.usageSamples.count,
                "usageSemantics": Dictionary(grouping: context.usageSamples, by: { $0.semantics.rawValue }).mapValues(\.count)
            ] as [String: Any],
            "communication": [
                "communicationCount": communication.communications.count,
                "sendRequestedCount": communication.communications.filter { !$0.sentEventIDs.isEmpty }.count,
                "toolResultRecordedCount": communication.communications.filter { !$0.toolResultEventIDs.isEmpty }.count,
                "submissionRecordedCount": communication.communications.filter { !$0.submissionEventIDs.isEmpty }.count,
                "recipientContextRecordedCount": communication.communications.filter { !$0.recipientContextEventIDs.isEmpty }.count,
                "modelInclusionConfirmedCount": communication.communications.filter { !$0.modelInclusionEventIDs.isEmpty }.count,
                "opaqueCommunicationCount": communication.communications.filter(\.isOpaque).count,
                "instructionCount": communication.instructions.count,
                "instructionKinds": Dictionary(grouping: communication.instructions, by: { $0.kind.rawValue }).mapValues(\.count),
                "unassociatedMetadataEventCount": communication.unassociatedMetadataEventIDs.count,
                "collectionLimitationCount": communication.collectionLimitations.count
            ] as [String: Any],
            "activity": [
                "observationCount": observations.count,
                "indexedEventCount": activity.observationsByEventID.count,
                "testObservationCount": activity.tests.count,
                "testOutcomes": Dictionary(grouping: activity.tests, by: { $0.outcome.rawValue }).mapValues(\.count),
                "partialCommandPreviewCount": observations.filter(\.commandIsPartial).count,
                "explicitlyTruncatedOutputCount": observations.flatMap(\.outputs).filter(\.isExplicitlyTruncated).count,
                "repeatedCallGroupCount": activity.repeatedCallGroups.count,
                "repeatedObservationCount": activity.repeatedCallGroups.reduce(0) { $0 + $1.observationIDs.count },
                "fileHistoryCount": activity.fileHistories.count,
                "fileActivityCount": activity.fileHistories.reduce(0) { $0 + $1.activities.count },
                "recordedIntervalOverlapCount": activity.fileHistories.reduce(0) { $0 + $1.overlappingRecordedIntervals.count },
                "resourceReadCount": activity.fileHistories.reduce(0) { $0 + $1.reads.count },
                "readWithVersionReferenceCount": activity.fileHistories.flatMap(\.reads).filter { !$0.recordedVersions.isEmpty }.count
            ] as [String: Any],
            "graphs": ["agentRowCount": presentation.agentRows.count, "sequenceLaneCount": presentation.sequence.lanes.count,
                       "sequenceRouteCount": presentation.sequence.routes.count, "omittedAgentCount": presentation.sequence.omittedAgentCount],
            "limits": [
                "Counts summarize recorded evidence; they do not establish causality, test coverage or loss of context.",
                "A send request, a recorded tool result, recipient context and confirmed request inclusion remain distinct stages.",
                "File activity counts are per environment and path; they are not a count of independent edits.",
                "Resource version references are not verified file bytes, and output presence does not establish completeness."
            ]
        ]
    }

    private static func inspectionBenchmark(home: URL, id: String) async throws -> [String: Any] {
        // Preserve the real ancestor spelling: Foundation may abbreviate /private/tmp to /tmp,
        // which the ownership registry deliberately refuses as a symlinked storage parent.
        let scratch = URL(fileURLWithPath: "/private/tmp/CodexLens-InspectionBenchmark-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = SessionEngine(home: home, cacheDirectory: scratch.appendingPathComponent("Index", isDirectory: true),
                                   investigationRegistryDirectory: scratch.appendingPathComponent("InvestigationRegistry", isDirectory: true))
        let builder = SessionPresentationBuilder()
        let openStart = DispatchTime.now().uptimeNanoseconds
        let snapshot = try await engine.open(id: id)
        let openSeconds = elapsedSeconds(since: openStart)
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        let cold = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters())
        let prepareSeconds = elapsedSeconds(since: prepareStart)
        let filterStart = DispatchTime.now().uptimeNanoseconds
        let hot = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(kind: .toolCall), agentFilters: AgentFilters())
        let filterSeconds = elapsedSeconds(since: filterStart)
        let repetitions = 10_000
        let accessStart = DispatchTime.now().uptimeNanoseconds
        var checksum = 0
        for iteration in 0..<repetitions { checksum = checksum &+ accessGraphs(cold, iteration: iteration) }
        let accessSeconds = elapsedSeconds(since: accessStart)
        let originRepetitions = 1_000
        let originIDs = snapshot.changes.prefix(32).map { OriginInspectionIndex.changeID($0.id) }
        let originStart = DispatchTime.now().uptimeNanoseconds
        var originChecksum = 0
        for i in 0..<originRepetitions where !originIDs.isEmpty {
            if let selection = cold.originInspection.selection(objectID: originIDs[i % originIDs.count]) {
                originChecksum = originChecksum &+ selection.links.count &+ selection.objects.count &+ selection.explanations.count
            }
        }
        let originSeconds = elapsedSeconds(since: originStart)
        return [
            "schemaVersion": 1, "reportKind": "inspection-benchmark-v21", "sourceHome": home.standardizedFileURL.path,
            "rootID": snapshot.root.id, "sessionID": snapshot.root.sessionID, "adapterCLI": snapshot.root.cliVersion,
            "collectedAt": ISO8601DateFormatter().string(from: snapshot.collectedAt),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "corpus": ["agentCount": snapshot.agents.count, "eventCount": snapshot.events.count, "environmentCount": snapshot.environments.count,
                       "resourceCount": snapshot.resources.count, "changeCount": snapshot.changes.count, "coverageIssueCount": snapshot.coverage.count],
            "measurements": ["clock": "DispatchTime monotonic uptime nanoseconds", "sampleCount": 1,
                             "coldOpenSeconds": openSeconds, "coldPrepareSeconds": prepareSeconds,
                             "coldOpenAndPrepareSeconds": openSeconds + prepareSeconds,
                             "hotFilterChangeSeconds": filterSeconds, "repeatedGraphAccessSeconds": accessSeconds,
                             "graphAccessRepetitions": repetitions, "graphAccessChecksum": checksum,
                             "originSelectionRepetitions": originRepetitions, "originSelectionSeconds": originSeconds, "originSelectionChecksum": originChecksum] as [String: Any],
            "filterChange": ["from": "all events", "to": EventKind.toolCall.rawValue,
                             "coldVisibleEventCount": cold.filteredEvents.count, "hotVisibleEventCount": hot.filteredEvents.count,
                             "agentFilters": "unchanged", "revision": 1] as [String: Any],
            "inspectionV20": inspectionSummary(cold),
            "method": [
                "Cold means a new SessionEngine and an empty disposable application cache, not a purged operating-system disk cache.",
                "Open includes source cataloging, parsing and the engine's disposable cache write.",
                "The cold prepare and filter change call the SessionPresentationBuilder actor with the same snapshot and revision.",
                "The repeated-access loop calls only stored projections and dictionary lookups; no SessionEngine.detail, refresh or FileService call occurs in that loop.",
                "Filesystem calls were not instrumented; the no-I/O scope of repeated access is established by the code path.",
                "Graph accesses use the unfiltered prepared graph and an observable checksum; no UI rendering or scrolling is measured.",
                "One run gives elapsed measurements for this corpus and binary. No before/after gain or end-to-end performance conclusion is implied."
            ]
        ]
    }

    private static func elapsedSeconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    @inline(never) private static func accessGraphs(_ presentation: SessionPresentation, iteration: Int) -> Int {
        var value = presentation.agentRows.count &+ presentation.sequence.routes.count &+ presentation.sequence.lanes.count
        if !presentation.agentRows.isEmpty {
            let agent = presentation.agentRows[iteration % presentation.agentRows.count].0
            value = value &+ (presentation.eventCountByAgent[agent.id] ?? 0) &+ (presentation.changesByAgent[agent.id]?.count ?? 0)
        }
        if !presentation.sequence.routes.isEmpty {
            let route = presentation.sequence.routes[iteration % presentation.sequence.routes.count]
            value = value &+ route.senderLane &+ route.recipientLanes.count
            value = value &+ (presentation.eventsByID[route.eventID] == nil ? 0 : 1)
            value = value &+ (presentation.communicationInspection.communicationByEventID[route.eventID] == nil ? 0 : 1)
        }
        if !presentation.contextInspection.compactions.isEmpty {
            let compaction = presentation.contextInspection.compactions[iteration % presentation.contextInspection.compactions.count]
            value = value &+ (presentation.contextInspection.compactionByEventID[compaction.eventID] == nil ? 0 : 1)
        }
        if !presentation.activityEvidence.fileHistories.isEmpty {
            let history = presentation.activityEvidence.fileHistories[iteration % presentation.activityEvidence.fileHistories.count]
            value = value &+ history.activities.count &+ history.reads.count &+ history.overlappingRecordedIntervals.count
        }
        return value
    }
}
