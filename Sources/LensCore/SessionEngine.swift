import Foundation
import CSQLite
import CryptoKit
import Darwin

/// Read-only adapter for local Codex rollout JSONL, supported schema families 0.158/0.159.
/// It never starts Codex, uses an app server, resumes a thread, or opens auth.json.
public actor SessionEngine {
    public let home: URL
    private let cacheDirectory: URL
    private let investigationRegistryDirectory: URL?
    private let investigationWorkspaceRoot: String
    private let investigationConnectionProbeRoot: String
    private var registeredInvestigationIDs = Set<String>()
    private var excludedInvestigationIDs = Set<String>()
    private var summaries: [String: SessionSummary] = [:]
    private var metadata: [String: RolloutMetadata] = [:]
    private var relationSources: [String: [SourceRef]] = [:]
    private var files: [String: FileIndex] = [:]
    private var selectedID: String?
    private var eventsByID: [String: LensEvent] = [:]
    private var fingerprintsBySource: [SourceRef: String] = [:]
    private var catalogIssues: [CoverageIssue] = []
    private var catalogHeaderCache: SessionCatalogCache
    internal private(set) var catalogHeaderReads = 0
    internal private(set) var catalogHeaderHits = 0
    internal var catalogHeaderCacheBytes: Int { catalogHeaderCache.estimatedBytes }
    private var loadedCache = false
    private var lastCollectionSignature: String?
    private var lastSelectedSignature: String?
    private let maximumCacheBytes = 64 * 1024 * 1024
    private let maximumLineBytes = 64 * 1024 * 1024
    private let maximumIndexedEvents = 150_000
    // Parsing changes must invalidate cached classification of unchanged source bytes.
    private let cacheVersion = 8

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), cacheDirectory: URL? = nil, investigationRegistryDirectory: URL? = nil) {
        self.home = home.standardizedFileURL
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexLens/Index-v1")
        self.catalogHeaderCache = SessionCatalogCache(home: self.home, cacheDirectory: self.cacheDirectory)
        self.investigationRegistryDirectory = investigationRegistryDirectory
        self.investigationWorkspaceRoot = CodexInvestigationRegistry.workspaceRoot(directory: investigationRegistryDirectory).path
        self.investigationConnectionProbeRoot = CodexInvestigationRegistry.workspaceRoot(directory: investigationRegistryDirectory).deletingLastPathComponent().appendingPathComponent("ConnectionProbe", isDirectory: true).path
    }

    public func catalog(progress: SessionProgressHandler? = nil) async throws -> [SessionSummary] {
        let span = LensSignposts.begin("SessionCatalog"); defer { span.end() }
        let reporter = SessionProgressReporter(progress)
        reporter.send(.init(stage: .discoveringSessions))
        relationSources = [:]
        try Task.checkCancellation()
        catalogIssues = []
        _ = try reloadInvestigationExclusions()
        excludedInvestigationIDs = registeredInvestigationIDs
        var found: [String: SessionSummary] = [:]
        var meta: [String: RolloutMetadata] = [:]
        var candidatePaths = Set<String>()
        let databaseSpan = LensSignposts.begin("CatalogDatabase")
        let databaseURL = home.appendingPathComponent("state_5.sqlite")
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                let database = try ReadOnlyDatabase(url: databaseURL)
                let columns = try database.columns("threads")
                let wanted = ["id", "rollout_path", "updated_at", "updated_at_ms", "cwd", "title", "cli_version", "agent_nickname", "agent_path", "agent_role", "agent_description", "model", "model_provider", "reasoning_effort", "source", "git_branch", "git_sha"].filter { columns.contains($0) }
                guard wanted.contains("id"), wanted.contains("rollout_path") else { throw LensError.unsupported("Schéma threads sans id/rollout_path.") }
                for row in try database.rows("SELECT " + wanted.joined(separator: ",") + " FROM threads") {
                    guard let id = row["id"], let path = row["rollout_path"] else { continue }
                    if excludedInvestigationIDs.contains(id) || isInvestigationWorkspace(row["cwd"] ?? "") { excludedInvestigationIDs.insert(id); continue }
                    let source = Self.jsonDictionary(row["source"] ?? "")
                    let spawn = Self.spawnMetadata(source)
                    let date = Double(row["updated_at_ms"] ?? "").map { Date(timeIntervalSince1970: $0 / 1000) } ?? Double(row["updated_at"] ?? "").map(Date.init(timeIntervalSince1970:)) ?? .distantPast
                    found[id] = SessionSummary(id: id, title: Self.redact(row["title"] ?? ""), cwd: row["cwd"] ?? "", paths: [path], modifiedAt: date, cliVersion: row["cli_version"] ?? "", parentID: spawn?["parent_thread_id"] as? String, relation: spawn == nil ? .root : .subagent, agentName: row["agent_nickname"] ?? row["agent_path"] ?? "", evidence: "state_5.sqlite threads (lecture SQLITE_OPEN_READONLY)")
                    found[id]?.agentMetadata = AgentMetadataField.threadFields(row, path: databaseURL.path)
                    candidatePaths.insert(path)
                    meta[id] = RolloutMetadata(id: id, cwd: row["cwd"] ?? "", branch: row["git_branch"], gitRef: row["git_sha"], name: row["agent_nickname"] ?? row["agent_path"] ?? "", parent: spawn?["parent_thread_id"] as? String, relation: spawn == nil ? .root : .subagent)
                }
                if (try? database.columns("thread_spawn_edges"))?.contains("child_thread_id") == true {
                    for row in try database.rows("SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges") {
                        guard let parent = row["parent_thread_id"], let child = row["child_thread_id"] else { continue }
                        if excludedInvestigationIDs.contains(parent) || excludedInvestigationIDs.contains(child) { excludedInvestigationIDs.insert(child); continue }
                        if found[child] == nil { found[child] = SessionSummary(id: child, parentID: parent, relation: .subagent, evidence: "state_5.sqlite thread_spawn_edges ; journal introuvable") }
                        found[child]?.parentID = parent
                        found[child]?.relation = .subagent
                        found[child]?.evidence += "; thread_spawn_edges confirme parent → enfant"
                        if meta[child] == nil { meta[child] = RolloutMetadata(id: child, parent: parent, relation: .subagent) }
                        meta[child]?.parent = parent; meta[child]?.relation = .subagent
                    }
                }
            } catch { catalogIssues.append(CoverageIssue("catalogue", "Base locale non lisible : \(error.localizedDescription). Repli sur les journaux.", source: databaseURL.path)) }
        }
        databaseSpan.end()
        let enumerationSpan = LensSignposts.begin("CatalogEnumeration")
        var discoveredFiles: Int64 = 0
        for directory in ["sessions", "archived_sessions"] {
            let url = home.appendingPathComponent(directory)
            candidatePaths.formUnion(try Self.rolloutPaths(in: url, onFile: {
                try Task.checkCancellation()
                discoveredFiles += 1
                reporter.send(.init(stage: .discoveringSessions, completed: discoveredFiles))
            }))
        }
        enumerationSpan.end()
        var processedFiles: Int64 = 0
        let totalFiles = Int64(candidatePaths.count)
        reporter.send(.init(stage: .readingMetadata, total: totalFiles))
        catalogHeaderCache.prepare(paths: candidatePaths)
        let headerSpan = LensSignposts.begin("CatalogHeaders")
        // First record is the file owner. Later copied session_meta records are inherited context.
        for path in candidatePaths.sorted() {
            try Task.checkCancellation()
            defer {
                processedFiles += 1
                reporter.send(.init(stage: .readingMetadata, completed: processedFiles, total: totalFiles))
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                let stamp = try SessionCatalogStamp.read(path: path)
                let header: SessionCatalogHeader
                if let cached = catalogHeaderCache.header(path: path, stamp: stamp) {
                    header = cached; catalogHeaderHits += 1
                } else {
                    catalogHeaderReads += 1
                    // Foundation's large JSON objects must die per file, not at
                    // the end of a catalog containing thousands of instructions.
                    guard let read = try autoreleasepool(invoking: { try Self.catalogHeader(path: path) }) else {
                        catalogIssues.append(CoverageIssue("métadonnées", "Premier enregistrement sans session_meta.id ; association du fichier inconnue.", source: path)); continue
                    }
                    guard try SessionCatalogStamp.read(path: path) == stamp else { throw LensError.unavailable("Métadonnées du journal modifiées pendant leur lecture.") }
                    header = read
                    catalogHeaderCache.insert(header, stamp: stamp)
                }
                let id = header.id, firstSource = header.source
                if excludedInvestigationIDs.contains(id) || isInvestigationWorkspace(header.cwd) {
                    excludedInvestigationIDs.insert(id); catalogHeaderCache.remove(path: path); continue
                }
                // A new mutable object for this merge; cached parentage cannot
                // inherit a previous database edge that has since disappeared.
                let parsed = RolloutMetadata(id: id, cwd: header.cwd, branch: header.branch, gitRef: header.gitRef,
                    name: header.name, parent: header.parent, relation: header.relation)
                parsed.sessionID = header.sessionID; parsed.historyStart = header.historyStart
                var summary = found[id] ?? SessionSummary(id: id)
                summary.sessionID = parsed.sessionID ?? id
                if !summary.paths.contains(path) { summary.paths.append(path) }
                summary.cwd = parsed.cwd.isEmpty ? summary.cwd : parsed.cwd
                summary.cliVersion = header.cliVersion ?? summary.cliVersion
                summary.agentName = parsed.name.isEmpty ? summary.agentName : parsed.name
                summary.modifiedAt = max(summary.modifiedAt, stamp.modifiedAt)
                summary.agentMetadata = (summary.agentMetadata ?? []) + (header.agentMetadata ?? [])
                if let parent = parsed.parent { summary.parentID = parent; summary.relation = parsed.relation; relationSources[id] = [firstSource] }
                summary.evidence += "; session_meta initial propriétaire (\(URL(fileURLWithPath: path).lastPathComponent))"
                if let existing = meta[id], parsed.parent == nil { parsed.parent = existing.parent; parsed.relation = existing.relation }
                meta[id] = parsed
                found[id] = summary
            } catch { catalogIssues.append(CoverageIssue("journal", "Métadonnées non lisibles : \(error.localizedDescription)", source: path)) }
        }
        headerSpan.end()
        // A child of a private investigation cannot re-enter the source catalog
        // through its own rollout, even when rows/edges arrived in another order.
        var exclusionsGrew = true
        while exclusionsGrew {
            let before = excludedInvestigationIDs.count
            for summary in found.values where summary.parentID.map(excludedInvestigationIDs.contains) == true { excludedInvestigationIDs.insert(summary.id) }
            exclusionsGrew = before != excludedInvestigationIDs.count
        }
        for id in excludedInvestigationIDs { found.removeValue(forKey: id); meta.removeValue(forKey: id) }
        let titleSpan = LensSignposts.begin("CatalogTitles")
        let titleURL = home.appendingPathComponent("session_index.jsonl")
        if (try? LocalContentGuard.requireResident(path: titleURL.path)) != nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: titleURL.path),
           let size = attrs[.size] as? NSNumber, size.intValue < 8 * 1024 * 1024,
           let data = try? Data(contentsOf: titleURL), data.count < 8 * 1024 * 1024 {
            for line in data.split(separator: 10) {
                if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = row["id"] as? String, let title = row["thread_name"] as? String ?? row["title"] as? String { found[id]?.title = Self.redact(title) }
            }
        }
        titleSpan.end()
        for id in found.keys { if found[id]?.title.isEmpty == true { found[id]?.title = "Session \(id.prefix(8))" } }
        try Task.checkCancellation()
        catalogHeaderCache.persist()
        summaries = found; metadata = meta
        return found.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func open(id: String, progress: SessionProgressHandler? = nil) async throws -> SessionSnapshot {
        let span = LensSignposts.begin("SessionLoad"); defer { span.end() }
        try Task.checkCancellation()
        _ = try await catalog(progress: progress)
        let requestedID = SessionPickerTarget.sessionID(from: id) ?? id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excludedInvestigationIDs.contains(where: { SessionPickerTarget.sameIdentity($0, requestedID) }) else { throw LensError.unavailable("Ce thread appartient à une investigation Lens ; il est exclu des sources observées.") }
        var cleanID = summaries[requestedID] != nil ? requestedID : summaries.keys.first(where: { SessionPickerTarget.sameIdentity($0, requestedID) }) ?? requestedID
        if summaries[cleanID] == nil {
            // A session ID identifies a tree, but cannot itself establish parentage.
            let roots = summaries.values.filter { SessionPickerTarget.sameIdentity($0.sessionID, requestedID) && $0.parentID == nil && $0.relation == .root }
            if roots.count == 1 { cleanID = roots[0].id }
            else if roots.count > 1 { throw LensError.unavailable("ID de session ambigu : \(requestedID). Choisissez son thread d’origine : \(roots.map(\.id).sorted().joined(separator: ", ")).") }
        }
        guard summaries[cleanID] != nil else { throw LensError.unavailable("Session \(requestedID) introuvable dans \(home.path). Vérifiez le dossier des sessions et l’ID ou le lien du thread. Une session active peut être consultée sans la reprendre.") }
        let previousID = selectedID, previousFiles = files, previousEvents = eventsByID, previousFingerprints = fingerprintsBySource
        let previousLoaded = loadedCache, previousCollectionSignature = lastCollectionSignature, previousSelectedSignature = lastSelectedSignature
        if selectedID != cleanID { files = [:]; eventsByID = [:]; fingerprintsBySource = [:]; loadedCache = false }
        selectedID = cleanID
        do { return try collect(progress: progress) }
        catch {
            // A cancelled/failed load must not silently change the session subsequently polled by this engine.
            selectedID = previousID; files = previousFiles; eventsByID = previousEvents; fingerprintsBySource = previousFingerprints
            loadedCache = previousLoaded; lastCollectionSignature = previousCollectionSignature; lastSelectedSignature = previousSelectedSignature
            throw error
        }
    }

    /// Collection continues when the view freezes; freezing is solely a UI selection decision.
    public func refresh() async throws -> SessionSnapshot? {
        guard selectedID != nil else { return nil }
        let exclusionsChanged = try reloadInvestigationExclusions()
        let signature = Self.sourceSignature(home: home)
        if signature == lastCollectionSignature && !exclusionsChanged { return nil }
        _ = try await catalog() // discovers late children, including children with separate rollouts
        if let selectedID, selectedSignature(root: selectedID) == lastSelectedSignature { lastCollectionSignature = signature; return nil }
        return try collect()
    }

    /// Fetches full recorded bytes on demand, never substitutes a current file for past content.
    public func detail(for event: LensEvent) async throws -> EventDetail {
        let related = event.relatedEventID.flatMap { eventsByID[$0] }
        return try recordedDetail(for: event, related: related, fingerprints: fingerprintsBySource)
    }

    /// Exact sources of this event, excluding its linked call/result. Used when
    /// classifying evidence so a counterpart's input cannot become this output.
    public func sourceDetail(for event: LensEvent) async throws -> EventDetail {
        try recordedDetail(for: event, related: nil, fingerprints: fingerprintsBySource)
    }

    private func recordedDetail(for event: LensEvent, related: LensEvent?, fingerprints: [SourceRef: String]) throws -> EventDetail {
        try Task.checkCancellation()
        var sources = [event.source] + event.supplementarySources
        if let related { sources += [related.source] + related.supplementarySources }
        var seenSources = Set<SourceRef>()
        sources = sources.filter { seenSources.insert($0).inserted }
        var rawParts: [String] = [], contentParts: [String] = [], args: [String] = [], outputs: [String] = []
        for source in sources {
            try Task.checkCancellation()
            let data = try Self.read(source)
            try Task.checkCancellation()
            if let expected = source.sha256 ?? fingerprints[source], Self.digest(data) != expected { throw LensError.unavailable("L'événement source a changé depuis la collecte : \(source.path):\(source.line). Actualisez pour examiner la nouvelle trace.") }
            guard let raw = String(data: data, encoding: .utf8) else { throw LensError.corrupt("Événement UTF-8 invalide : \(source.path):\(source.line)") }
            rawParts.append(Self.redact(raw))
            if let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let p = record["payload"] as? [String: Any] {
                let type = p["type"] as? String ?? ""
                if type == "item_completed", let item = p["item"] as? [String: Any] {
                    contentParts.append(Self.pretty(item))
                    if let output = item["formatted_output"] ?? item["aggregated_output"] ?? item["output"] ?? item["result"] { outputs.append(Self.string(output)) }
                    if let command = item["command"] { args.append(Self.pretty(["command": command, "cwd": item["cwd"] ?? "", "process_id": item["process_id"] ?? "", "recordedDuration": item["duration"] ?? [:]])) }
                    else if let input = item["arguments"] { args.append(Self.string(input)) }
                } else {
                    let text = (p["base_instructions"] as? [String: Any])?["text"] as? String ?? p["base_instructions"] as? String ?? Self.content(p)
                    if !text.isEmpty { contentParts.append(text) }
                    if let input = p["arguments"] ?? p["input"] { args.append(Self.string(input)) }
                    if let output = p["output"] { outputs.append(Self.string(output)) }
                }
            }
        }
        try Task.checkCancellation()
        return EventDetail(content: Self.redact(contentParts.joined(separator: "\n\n")), arguments: Self.redact(args.joined(separator: "\n\n")), output: Self.redact(outputs.joined(separator: "\n\n")), raw: rawParts.joined(separator: "\n\n"))
    }

    /// Chunked raw access for large inspectors. `nextOffset == nil` means end of the exact record.
    /// Individual chunks may split UTF-8; callers should buffer bytes before decoding.
    public func rawChunk(source: SourceRef, offset: Int = 0, limit: Int = 64 * 1024) async throws -> (data: Data, nextOffset: Int?) {
        guard offset >= 0, offset <= source.length else { throw LensError.corrupt("Offset hors de l'événement.") }
        let amount = min(max(1, min(limit, 1024 * 1024)), source.length - offset)
        let data = try Self.read(SourceRef(path: source.path, offset: source.offset + UInt64(offset), length: amount, line: source.line))
        let next = offset + data.count
        return (data, next < source.length ? next : nil)
    }

    /// Searches full source records lazily, so content outside the indexed preview remains findable.
    public func search(query: String, snapshot: SessionSnapshot) async throws -> [String] {
        let span = LensSignposts.begin("SearchSession"); defer { span.end() }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        // Capture the requested graph once. Actor reentrancy or another opened session must not change its links.
        var requestedEvents: [String: LensEvent] = [:]
        requestedEvents.reserveCapacity(snapshot.events.count)
        for (offset, event) in snapshot.events.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            requestedEvents[event.id] = event
        }
        let capturedFingerprints = fingerprintsBySource
        var matches: [String] = []
        for (i, event) in snapshot.events.enumerated() {
            try Task.checkCancellation()
            if i % 32 == 0 { await Task.yield() }
            if event.title.localizedCaseInsensitiveContains(term) || event.preview.localizedCaseInsensitiveContains(term) { matches.append(event.id); continue }
            let related = event.relatedEventID.flatMap { requestedEvents[$0] }
            do {
                let detail = try recordedDetail(for: event, related: related, fingerprints: capturedFingerprints)
                if detail.raw.localizedCaseInsensitiveContains(term) { matches.append(event.id) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A missing or changed source cannot produce a verified full-record match. */ }
        }
        return matches
    }

    /// Build the membership set on the engine executor, rather than copying all IDs on MainActor.
    public func matchingEventIDs(query: String, snapshot: SessionSnapshot) async throws -> Set<String> {
        let ids = try await search(query: query, snapshot: snapshot)
        try Task.checkCancellation()
        return Set(ids)
    }

    private func collect(progress: SessionProgressHandler? = nil) throws -> SessionSnapshot {
        // Collection also creates temporary file buffers, lookup objects and
        // cache-encoding objects outside individual JSON record scopes.
        try autoreleasepool { try collectIndex(progress: progress) }
    }

    private func collectIndex(progress: SessionProgressHandler?) throws -> SessionSnapshot {
        let reporter = SessionProgressReporter(progress)
        try Task.checkCancellation()
        guard let selectedID, let root = summaries[selectedID] else { throw LensError.unavailable("Aucune session sélectionnée.") }
        guard !excludedInvestigationIDs.contains(selectedID), !isInvestigationWorkspace(root.cwd) else { throw LensError.unavailable("Chat d’enquête exclu de l’historique de session.") }
        let collectionSignature = Self.sourceSignature(home: home)
        let selectedCollectionSignature = selectedSignature(root: selectedID)
        var memberIDs = descendants(of: selectedID)
        if !loadedCache {
            reporter.send(.init(stage: .restoringIndex))
            restore(root: selectedID); loadedCache = true
        }
        var readOwners = Set<String>()
        let history = SessionHistoryProgress()
        while !memberIDs.isSubset(of: readOwners) {
            try Task.checkCancellation()
            for id in memberIDs {
                for path in summaries[id]?.paths ?? [] {
                    guard !history.contains(path: path) else { continue }
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
                    history.register(path: path, bytes: size)
                }
            }
            for id in memberIDs.subtracting(readOwners) {
                readOwners.insert(id)
                guard let summary = summaries[id] else { continue }
                for path in summary.paths where FileManager.default.fileExists(atPath: path) {
                    do { try update(path: path, owner: id, reporter: reporter, history: history) }
                    catch is CancellationError { throw CancellationError() }
                    catch { var index = files[path] ?? FileIndex(owner: id); index.issues.append(CoverageIssue("lecture", error.localizedDescription, source: path)); files[path] = index }
                    history.finish(path: path)
                }
            }
            discoverSpawnedChildren(in: memberIDs)
            memberIDs = descendants(of: selectedID)
        }
        var coverage = catalogIssues
        var all: [IndexedEvent] = []
        for (path, file) in files where memberIDs.contains(file.owner) {
            all += file.records
            coverage += file.issues
            if file.pendingBytes > 0 { coverage.append(CoverageIssue("ligne partielle", "\(file.pendingBytes) octets en fin de journal attendent une ligne JSON complète ; la collecte reprendra sans doublon.", source: path)) }
        }
        reporter.send(.init(stage: .organizingEvents, total: Int64(all.count)))
        all.sort { $0.event.timestamp == $1.event.timestamp ? ($0.event.agentID == $1.event.agentID ? $0.event.source.offset < $1.event.source.offset : $0.event.agentID < $1.event.agentID) : $0.event.timestamp < $1.event.timestamp }
        var events: [LensEvent] = []
        var recordForID: [String: IndexedEvent] = [:]
        var eventIndex: [String: Int] = [:]
        var itemIDs: [String: Int] = [:]
        // Stable protocol IDs deduplicate copied/supplementary records; equal text alone never does.
        for (recordIndex, record) in all.enumerated() {
            if recordIndex.isMultiple(of: 1024) {
                try Task.checkCancellation()
                reporter.send(.init(stage: .organizingEvents, completed: Int64(recordIndex), total: Int64(all.count)))
            }
            let event = record.event
            let identity = record.protocolID.map { event.agentID + ":" + $0 }
            if let identity, let existing = itemIDs[identity] {
                if record.isCompletedItem {
                    events[existing].supplementarySources.append(event.source)
                    if events[existing].trace?.explanation?.phase == "started", event.trace?.explanation != nil {
                        // A started item often contains empty text. Keep its stable event ID,
                        // but let the matching completed item be the actual content source.
                        // Equal prose or a neighbouring timestamp cannot reach this branch.
                        let startedSource = events[existing].source
                        events[existing].source = event.source
                        events[existing].supplementarySources = [startedSource] + events[existing].supplementarySources.filter { $0 != event.source }
                        events[existing].trace = event.trace
                        events[existing].preview = event.preview
                        events[existing].title = event.title
                        events[existing].kind = event.kind
                    }
                    if let end = event.endTime { events[existing].endTime = end }
                    events[existing].isError = events[existing].isError || event.isError
                    if var merged = recordForID[events[existing].id] {
                        merged.resources += record.resources; merged.resultPatchPaths += record.resultPatchPaths
                        merged.spawnedChildID = record.spawnedChildID ?? merged.spawnedChildID
                        merged.positiveSuccess = merged.positiveSuccess || record.positiveSuccess
                        merged.mergeFileChangeStatus(record, isError: events[existing].isError)
                        merged.event = events[existing]
                        recordForID[events[existing].id] = merged
                    }
                    continue
                } else if events[existing].source != event.source {
                    if recordForID[events[existing].id]?.isCompletedItem == true {
                        let completedID = events[existing].id
                        let completed = recordForID[completedID]
                        var preferred = event
                        preferred.supplementarySources = [events[existing].source] + events[existing].supplementarySources
                        preferred.endTime = events[existing].endTime
                        preferred.isError = preferred.isError || events[existing].isError
                        eventIndex.removeValue(forKey: completedID)
                        recordForID.removeValue(forKey: completedID)
                        events[existing] = preferred
                        eventIndex[preferred.id] = existing
                        recordForID[preferred.id] = record
                        if var merged = recordForID[preferred.id], let completed {
                            merged.resources += completed.resources; merged.resultPatchPaths += completed.resultPatchPaths
                            merged.spawnedChildID = completed.spawnedChildID ?? merged.spawnedChildID
                            merged.positiveSuccess = merged.positiveSuccess || completed.positiveSuccess
                            merged.mergeFileChangeStatus(completed, isError: preferred.isError)
                            recordForID[preferred.id] = merged
                        }
                    } else { events[existing].supplementarySources.append(event.source) }
                    continue
                }
            }
            if eventIndex[event.id] != nil { continue }
            eventIndex[event.id] = events.count
            if let identity { itemIDs[identity] = events.count }
            events.append(event); recordForID[event.id] = record
        }
        events.sort { $0.timestamp == $1.timestamp ? ($0.agentID == $1.agentID ? $0.source.offset < $1.source.offset : $0.agentID < $1.agentID) : $0.timestamp < $1.timestamp }
        var calls: [String: Int] = [:]
        reporter.send(.init(stage: .organizingEvents, completed: Int64(all.count), total: Int64(all.count)))
        reporter.send(.init(stage: .linkingEvents))
        for i in events.indices where events[i].kind == .toolCall || events[i].kind == .delegation || events[i].kind == .wait {
            if let callID = events[i].callID { calls[events[i].agentID + ":" + callID] = i }
        }
        for i in events.indices {
            guard let callID = events[i].callID else { continue }
            let key = events[i].agentID + ":" + callID
            if events[i].kind == .toolResult, let call = calls[key] {
                events[i].relatedEventID = events[call].id
                events[call].relatedEventID = events[i].id
                if events[call].endTime == nil, events[i].timestamp >= events[call].timestamp { events[call].endTime = events[i].timestamp }
                else if events[i].timestamp < events[call].timestamp { coverage.append(CoverageIssue("horodatage incohérent", "Le résultat \(callID) est horodaté avant son appel. Le lien est confirmé par call_id, pas par la proximité temporelle ; durée non déduite.", source: events[i].source.path)) }
                events[i].toolName = events[call].toolName
                events[i].environmentID = events[call].environmentID
            }
        }
        for event in events where event.toolName != nil && (event.kind == .toolCall || event.kind == .delegation || event.kind == .wait) && event.endTime == nil && event.relatedEventID == nil && recordForID[event.id]?.isCompletedItem != true {
            coverage.append(CoverageIssue("résultat non observé", "Appel \(event.callID ?? event.id) de l'agent \(event.agentID) : aucun résultat ni achèvement enregistré disponible. Il peut être encore actif ou manquer dans l'historique ; aucune erreur n'est déduite.", source: event.source.path))
        }
        var environments: [String: EnvironmentRecord] = [:], resources: [String: ResourceRecord] = [:]
        for id in memberIDs {
            let cwd = summaries[id]?.cwd ?? ""
            if !cwd.isEmpty {
                var env = environments[cwd] ?? EnvironmentRecord(path: cwd, repositoryPath: Self.repositoryRoot(cwd), recordedBranch: metadata[id]?.branch, recordedRef: metadata[id]?.gitRef, evidence: "session_meta.cwd initial enregistré ; contenu courant présenté séparément")
                if !env.agentIDs.contains(id) { env.agentIDs.append(id) }
                environments[cwd] = env
            }
        }
        var changes: [ChangeRecord] = []
        for i in events.indices {
            let event = events[i]
            guard let record = recordForID[event.id] else { continue }
            if let cwd = event.environmentID, !cwd.isEmpty {
                if environments[cwd] == nil { environments[cwd] = EnvironmentRecord(path: cwd, repositoryPath: Self.repositoryRoot(cwd), evidence: "cwd/workdir enregistré ; contenu courant présenté séparément") }
                if metadata[event.agentID]?.cwd == cwd { environments[cwd]?.recordedBranch = metadata[event.agentID]?.branch; environments[cwd]?.recordedRef = metadata[event.agentID]?.gitRef }
                if environments[cwd]?.agentIDs.contains(event.agentID) != true { environments[cwd]?.agentIDs.append(event.agentID) }
                // Mutate the dictionary value in place, avoiding an O(n²) copy of eventIDs.
                environments[cwd]?.eventIDs.append(event.id)
            }
            var candidates = record.resources
            if event.kind == .toolResult, let callEventID = event.relatedEventID, let call = recordForID[callEventID] {
                if record.positiveSuccess { candidates += call.readPaths.map { ResourceCandidate(location: $0, role: .recordedRead, evidence: "Lecture par commande ; succès enregistré") } }
                for path in call.patchPaths {
                    if record.positiveSuccess { candidates.append(ResourceCandidate(location: path, role: .modified, evidence: "Patch demandé + succès positif enregistré ; état des octets non prouvé")) }
                    changes.append(ChangeRecord(id: event.id + ":result:" + path, path: path, environmentID: event.environmentID ?? "", agentID: event.agentID, eventID: event.id, kind: .recordedResult, evidence: event.isError ? "Résultat en erreur enregistré du patch ; aucun octet modifié déduit" : "Résultat enregistré du patch ; succès éventuellement inconnu, aucun diff courant attribué automatiquement"))
                }
                if record.positiveSuccess { candidates += call.producedPaths.map { ResourceCandidate(location: $0, role: .produced, evidence: "Écriture par commande ; succès enregistré. L’état actuel reste à vérifier") } }
            }
            for candidate in candidates {
                let location = candidate.location
                let key = location.hasPrefix("/") ? location : (event.environmentID ?? event.agentID) + "::" + location
                if resources[key] == nil { resources[key] = ResourceRecord(id: key, location: location, roles: [], environmentID: event.environmentID, availability: Self.availability(location)) }
                if let availability = candidate.availability { resources[key]?.availability = availability }
                if resources[key]?.roles.contains(candidate.role) != true { resources[key]?.roles.append(candidate.role) }
                if resources[key]?.agentIDs.contains(event.agentID) != true { resources[key]?.agentIDs.append(event.agentID) }
                if resources[key]?.eventIDs.contains(event.id) != true { resources[key]?.eventIDs.append(event.id) }
                if resources[key]?.evidence.contains(candidate.evidence) != true { let separator = resources[key]?.evidence.isEmpty == true ? "" : "; "; resources[key]?.evidence += separator + candidate.evidence }
                if !events[i].resourceIDs.contains(key) { events[i].resourceIDs.append(key) }
            }
            for path in record.patchPaths {
                changes.append(ChangeRecord(id: event.id + ":request:" + path, path: path, environmentID: event.environmentID ?? "", agentID: event.agentID, eventID: event.id, kind: .requestedPatch, evidence: "Texte du patch demandé ; succès et contenu historique ne sont pas déduits de la demande"))
            }
            for path in record.resultPatchPaths {
                changes.append(ChangeRecord(id: event.id + ":item-result:" + path, path: path, environmentID: event.environmentID ?? "", agentID: event.agentID, eventID: event.id, kind: .recordedResult, evidence: record.fileChangeEvidence))
            }
        }
        var agents: [AgentRecord] = []
        for id in memberIDs.sorted() {
            let summary = summaries[id] ?? SessionSummary(id: id)
            let accessible = summary.paths.contains { FileManager.default.fileExists(atPath: $0) }
            let incoming = events.first { $0.agentID == id && $0.kind == .user }
            let spawnObservation = all.first { $0.spawnedChildID == id && $0.event.agentID == summary.parentID }
            let parentMission = spawnObservation.flatMap { observation in all.first { $0.event.agentID == summary.parentID && $0.event.callID == observation.event.callID && $0.delegatedMission != nil } }
            let parentRequest = spawnObservation.flatMap { observation in all.first { $0.event.agentID == summary.parentID && $0.event.callID == observation.event.callID && $0.delegatedMetadata != nil } }
            let encrypted = events.first { $0.agentID == id && $0.preview.contains("Charge utile chiffrée") }
            let mission = id == selectedID ? incoming?.preview ?? "" : parentMission?.delegatedMission ?? incoming?.preview ?? (encrypted == nil ? "Mission non enregistrée dans les données disponibles." : "Charge utile de mission chiffrée, non accessible dans ce journal.")
            let missionEventID = id == selectedID ? incoming?.id : parentMission?.event.id ?? incoming?.id ?? encrypted?.id
            let parentSources = relationSources[id] ?? spawnObservation.map { [$0.event.source] + $0.event.supplementarySources } ?? []
            var agentMetadata = summary.agentMetadata ?? []
            if let requested = parentRequest?.delegatedMetadata { agentMetadata += requested }
            agents.append(AgentRecord(id: id, parentID: id == selectedID ? nil : summary.parentID, name: summary.agentName.isEmpty ? (id == selectedID ? "Session principale" : "Agent \(id.prefix(8))") : summary.agentName, relation: id == selectedID ? .root : summary.relation, mission: mission, missionEventID: missionEventID, evidence: summary.evidence, paths: summary.paths, environmentIDs: environments.values.filter { $0.agentIDs.contains(id) }.map(\.id).sorted(), accessible: accessible, relationSources: parentSources, metadata: agentMetadata.isEmpty ? nil : agentMetadata))
            if !accessible { coverage.append(CoverageIssue("descendant inaccessible", "Lien parent/enfant enregistré pour \(id), mais ses octets de journal sont indisponibles.", source: summary.paths.first ?? id)) }
            if let version = summaries[id]?.cliVersion, !version.isEmpty, !version.hasPrefix("0.158"), !version.hasPrefix("0.159") { coverage.append(CoverageIssue("compatibilité", "Version \(version) hors des familles vérifiées 0.158/0.159 ; champs inconnus conservés comme événements bruts.", source: id)) }
        }
        for environment in environments.values where !FileManager.default.fileExists(atPath: environment.path) { coverage.append(CoverageIssue("environnement indisponible", "Chemin actuel introuvable. La référence enregistrée est conservée ; l’arborescence et le contenu actuel ne sont pas accessibles.", source: environment.path)) }
        for resource in resources.values where resource.roles.contains(.supplied) && resource.availability != .accessible { coverage.append(CoverageIssue("pièce jointe indisponible", "La référence fournie ne garantit pas que ses octets soient encore disponibles.", source: resource.location)) }
        coverage.append(CoverageIssue("historique", "L’explorateur affiche les fichiers actuels. Un instantané Git n’est proposé que si le commit enregistré et son fichier sont vérifiés. L’état non commité à l’époque reste inconnu. Les sorties et patches restent accessibles dans les traces ; les périodes sans traces ne sont pas reconstituées."))
        var snapshot = SessionSnapshot(root: root, agents: agents, events: events, environments: environments.values.sorted { $0.path < $1.path }, resources: resources.values.sorted { $0.location < $1.location }, changes: changes, coverage: Array(Set(coverage)).sorted { $0.category < $1.category }, collectedAt: Date())
        try Task.checkCancellation()
        reporter.send(.init(stage: .savingIndex))
        if let cacheIssue = persist(root: selectedID) { snapshot.coverage.append(cacheIssue) }
        try Task.checkCancellation()
        eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        fingerprintsBySource = Dictionary(all.compactMap { record -> (SourceRef, String)? in
            guard let fingerprint = record.fingerprint else { return nil }
            return (record.event.source, fingerprint)
        }, uniquingKeysWith: { a, _ in a })
        lastCollectionSignature = collectionSignature
        lastSelectedSignature = selectedCollectionSignature
        return snapshot
    }

    private func descendants(of root: String) -> Set<String> {
        guard !excludedInvestigationIDs.contains(root) else { return [] }
        var ids: Set<String> = [root]
        var changed = true
        while changed { changed = false; for summary in summaries.values where !excludedInvestigationIDs.contains(summary.id) && !isInvestigationWorkspace(summary.cwd) { if let parent = summary.parentID, ids.contains(parent), summary.relation == .subagent || summary.relation == .fork || summary.relation == .continuation { if ids.insert(summary.id).inserted { changed = true } } } }
        return ids
    }

    private func reloadInvestigationExclusions() throws -> Bool {
        do {
            let ids = try CodexInvestigationRegistry.ownedThreadIDs(directory: investigationRegistryDirectory)
            let changed = ids != registeredInvestigationIDs
            registeredInvestigationIDs = ids
            excludedInvestigationIDs.formUnion(ids)
            return changed
        } catch {
            summaries = [:]; metadata = [:]; files = [:]; eventsByID = [:]; fingerprintsBySource = [:]; loadedCache = false
            lastCollectionSignature = nil; lastSelectedSignature = nil
            catalogIssues = [CoverageIssue("investigations exclues", "Registre de propriété illisible ; couverture des sources indisponible pour éviter d'inclure une investigation.")]
            throw LensError.unavailable("Registre de propriété d'investigation illisible ; collecte des sources indisponible : \(error.localizedDescription)")
        }
    }
    private func isInvestigationWorkspace(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        // Preserve physical /private spellings. Foundation standardization may
        // abbreviate them to /tmp after the private directory has been created.
        let path = URL(fileURLWithPath: cwd).path
        return [investigationWorkspaceRoot, investigationConnectionProbeRoot].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func update(path: String, owner: String, reporter: SessionProgressReporter? = nil, history: SessionHistoryProgress? = nil) throws {
        try LocalContentGuard.requireResident(path: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var file = files[path] ?? FileIndex(owner: owner)
        let previousOffset = file.offset
        let boundaryChanged = file.offset > 0 && file.boundaryFingerprint != nil && (try? Self.boundaryFingerprint(path: path, offset: file.offset)) != file.boundaryFingerprint
        if file.inode != 0 && (file.inode != inode || size < file.offset || boundaryChanged) {
            file = FileIndex(owner: owner)
            file.issues.append(CoverageIssue("rotation/troncature", "Le journal a changé d'identité ou raccourci. Index relu depuis le début ; anciennes données non vérifiables remplacées.", source: path))
        }
        file.inode = inode
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        var reportedOffset = file.offset
        func report(_ offset: UInt64) {
            reportedOffset = offset
            let completed = Int64(clamping: offset), total = Int64(clamping: max(size, offset))
            history?.update(path: path, completedBytes: completed, totalBytes: total)
            reporter?.send(.init(stage: .readingHistory, completed: completed, total: total, fileName: fileName, history: history?.snapshot))
        }
        defer {
            if !Task.isCancelled { history?.finish(path: path); report(reportedOffset) }
        }
        report(file.offset)
        guard size > file.offset else { file.pendingBytes = 0; files[path] = file; return }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seek(toOffset: file.offset)
        var buffer = Data(), cursor = file.offset, readEnd = file.offset, dropping = false
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 256 * 1024) }), !chunk.isEmpty {
            try Task.checkCancellation()
            readEnd += UInt64(chunk.count)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline))
                let length = line.count
                file.line += 1
                if file.line.isMultiple(of: 1024) { try Task.checkCancellation() }
                if dropping { file.issues.append(CoverageIssue("événement volumineux", "Ligne \(file.line) de plus de \(maximumLineBytes) octets : non indexée, source conservée à l'offset \(cursor).", source: path)); dropping = false }
                else if file.records.count >= maximumIndexedEvents { if !file.issues.contains(where: { $0.category == "limite d'index" }) { file.issues.append(CoverageIssue("limite d'index", "Plus de \(maximumIndexedEvents) événements dans ce journal ; les suivants restent disponibles dans la source mais ne sont pas indexés.", source: path)) } }
                else {
                    // Foundation's JSON reader creates autoreleased objects. A
                    // collection task can decode many files without returning to
                    // a run loop; release temporary dictionaries after each line
                    // instead of retaining them for the entire history load.
                    autoreleasepool {
                        parse(line: line, source: SourceRef(path: path, offset: cursor, length: length, line: file.line), index: &file)
                    }
                }
                cursor += UInt64(length + 1)
                buffer.removeSubrange(...newline)
                file.offset = cursor
            }
            if buffer.count > maximumLineBytes { dropping = true; cursor += UInt64(buffer.count); buffer.removeAll(keepingCapacity: false) }
            report(readEnd)
        }
        // Active rollouts may grow after attributesOfItem. Count bytes actually read,
        // never subtract a stale pre-read size from a later (larger) parsed offset.
        file.pendingBytes = readEnd >= file.offset ? Int(readEnd - file.offset) : 0
        if dropping { file.issues.append(CoverageIssue("ligne volumineuse partielle", "Ligne de plus de \(maximumLineBytes) octets encore incomplète ; reprise depuis le dernier événement complet.", source: path)) }
        if file.offset == previousOffset && file.pendingBytes == 0 { file.offset = size }
        file.boundaryFingerprint = try? Self.boundaryFingerprint(path: path, offset: file.offset)
        files[path] = file
    }

    private func parse(line: Data, source: SourceRef, index: inout FileIndex) {
        guard !line.isEmpty else { return }
        if let historyStart = index.historyStart, source.line > 1, source.line <= historyStart {
            retainInheritedReference(line: line, source: source, index: &index); return
        }
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = root["type"] as? String ?? root["method"] as? String else { index.issues.append(CoverageIssue("JSON invalide", "Ligne \(source.line) illisible ; les événements suivants continuent à être collectés.", source: source.path)); return }
        let p = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? [:]
        let date = Self.date(root["timestamp"]) ?? Self.date(p["timestamp"]) ?? .distantPast
        if type == "session_meta" {
            if source.line == 1 {
                index.cwd = p["cwd"] as? String ?? ""
                index.historyStart = p["subagent_history_start_ordinal"] as? Int
                // Authentication/account metadata is deliberately not indexed.
                if let instructions = (p["base_instructions"] as? [String: Any])?["text"] as? String ?? p["base_instructions"] as? String, !instructions.isEmpty {
                    var instruction = LensEvent(id: index.owner + ":" + Self.digest(source.path) + ":instructions", timestamp: date, agentID: index.owner, kind: .instruction, title: "Instructions de base enregistrées", preview: Self.preview(instructions), environmentID: index.cwd.isEmpty ? nil : index.cwd, source: source)
                    instruction.trace = RecordedTraceFacts.decode(root, event: instruction)
                    var recorded = IndexedEvent(event: instruction); recorded.fingerprint = Self.digest(line); index.records.append(recorded)
                    index.records[index.records.count - 1].event.source.sha256 = recorded.fingerprint
                }
            }
            return
        }
        if let historyStart = index.historyStart, source.line <= historyStart { return }
        if type == "turn_context" {
            index.cwd = p["cwd"] as? String ?? index.cwd
            index.turnID = p["turn_id"] as? String ?? index.turnID
        }
        var event = LensEvent(id: index.owner + ":" + Self.digest(source.path) + ":" + String(source.offset), timestamp: date, agentID: index.owner, turnID: p["turn_id"] as? String ?? p["turnId"] as? String ?? index.turnID, kind: .unknown, environmentID: index.cwd.isEmpty ? nil : index.cwd, source: source)
        var record = IndexedEvent(event: event)
        record.fingerprint = Self.digest(line)
        switch type {
        case "response_item":
            let itemType = p["type"] as? String ?? "unknown"
                record.protocolID = p["id"] as? String
            let text = Self.content(p)
            switch itemType {
            case "message":
                let role = p["role"] as? String ?? "unknown"
                event.kind = role == "user" ? .user : role == "assistant" ? .assistant : .instruction
                event.title = role == "user" ? "Message utilisateur" : role == "assistant" ? "Réponse assistant" : "Instruction \(role) enregistrée"
                event.preview = Self.preview(text)
                record.resources = Self.messageResources(p, text: text, user: role == "user", cwd: index.cwd, eventID: event.id)
            case "agent_message":
                event.kind = .delegation; event.title = "Échange \(p["author"] as? String ?? "agent") → \(p["recipient"] as? String ?? "agent")"; event.preview = Self.preview(text)
                if (p["content"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "encrypted_content" }) == true {
                    event.preview += "\n[Charge utile chiffrée : contenu non accessible depuis ce journal]"
                    index.issues.append(CoverageIssue("charge utile chiffrée", "Un échange d'agent contient une charge utile chiffrée. Les arguments de délégation du parent, quand enregistrés, constituent une source séparée accessible.", source: source.path))
                }
            case "function_call", "custom_tool_call":
                let name = p["name"] as? String ?? "Outil inconnu"
                let input = Self.string(p["arguments"] ?? p["input"] ?? "")
                event.toolName = name; event.callID = p["call_id"] as? String
                record.protocolID = event.callID ?? record.protocolID
                if name.contains("spawn_agent"), let callID = event.callID { index.spawnCallIDs.insert(callID) }
                event.kind = name.contains("spawn_agent") || name.contains("send_message") || name.contains("followup_task") ? .delegation : name.contains("wait") ? .wait : .toolCall
                event.title = name; event.preview = Self.preview(input)
                let args = Self.jsonDictionary(input)
                let opaqueMessage = RecordedCommunicationFacts.hasOpaqueMessage(payload: p)
                if opaqueMessage {
                    var visible = args; visible["message"] = "[Message opaque ; contenu non déchiffré. Trace brute disponible.]"
                    event.preview = Self.preview(Self.pretty(visible))
                    index.issues.append(CoverageIssue("mission opaque", "Forme chiffrée reconnue dans un message d’agent ; contenu et authenticité non vérifiés. Aucun texte de mission reconstruit.", source: source.path))
                }
                if name.contains("spawn_agent") {
                    record.delegatedMission = opaqueMessage ? "Mission opaque ; contenu non accessible dans les données visibles." : (args["message"] as? String).map(Self.preview)
                    var metadataSource = source; metadataSource.sha256 = record.fingerprint
                    record.delegatedMetadata = AgentMetadataField.delegationFields(args, source: metadataSource, eventID: event.id)
                }
                let cwd = args["workdir"] as? String ?? args["cwd"] as? String
                if let cwd { event.environmentID = Self.resolve(cwd, cwd: index.cwd) }
                let command = args["cmd"] as? String ?? args["command"] as? String ?? ""
                if let explicit = Self.commandDirectory(command, cwd: event.environmentID ?? index.cwd) { event.environmentID = explicit }
                let workingDirectory = event.environmentID ?? index.cwd
                record.resources = Self.argumentResources(args, cwd: workingDirectory)
                if name.contains("apply_patch") {
                    record.patchPaths = Self.patchPaths(input, cwd: workingDirectory)
                    record.resources += record.patchPaths.map { ResourceCandidate(location: $0, role: .referenced, evidence: "Chemin du patch demandé") }
                } else if input.contains("apply_patch") {
                    // Statically decode only literal JSON strings, never evaluate orchestration code.
                    for literal in Self.matches(input, #"(?:tools\.)?apply_patch\s*\(\s*(\"(?:[^\"\\]|\\.)*\")"#) {
                        if let data = literal.data(using: .utf8), let patch = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String { record.patchPaths += Self.patchPaths(patch, cwd: workingDirectory) }
                    }
                    record.resources += record.patchPaths.map { ResourceCandidate(location: $0, role: .referenced, evidence: "Chemin de patch dans une chaîne littérale apply_patch ; code jamais exécuté") }
                }
                record.readPaths = Self.readPaths(command, cwd: workingDirectory)
                record.resources += record.readPaths.map { ResourceCandidate(location: $0, role: .referenced, evidence: "Cible d'une commande de lecture explicite ; résultat non encore établi") }
                if name.contains("read_file") || name.contains("view_image") || name.contains("read") && !name.contains("thread") {
                    record.readPaths += Self.namedPaths(args, cwd: workingDirectory)
                }
                record.producedPaths = Self.producedPaths(command, cwd: workingDirectory)
                record.resources += Self.pathReferences(input, cwd: workingDirectory).map { ResourceCandidate(location: $0, role: .referenced, evidence: "Chemin mentionné dans les arguments ; aucune lecture déduite") }
            case "function_call_output", "custom_tool_call_output":
                event.kind = .toolResult; event.title = "Résultat enregistré"; event.callID = p["call_id"] as? String
                let output = Self.string(p["output"] ?? "")
                event.preview = Self.preview(output)
                event.isError = p["is_error"] as? Bool == true || Self.outputFailed(output)
                record.positiveSuccess = !event.isError && Self.outputSucceeded(output)
                if let callID = event.callID, index.spawnCallIDs.contains(callID), !event.isError {
                    let outputObject = Self.jsonDictionary(output)
                    record.spawnedChildID = outputObject["agent_id"] as? String ?? outputObject["thread_id"] as? String
                }
                if event.isError { event.title = "Résultat / erreur enregistrée" }
            case "reasoning":
                event.kind = .context; event.title = "Explication enregistrée"
                // Empty/absent summaries never imply that a readable summary was produced.
                event.preview = ""
            default:
                event.kind = .unknown; event.title = "response_item · \(itemType)"; event.preview = Self.preview(text.isEmpty ? Self.pretty(p) : text)
            }
        case "event_msg", "item/started", "item/completed", "thread/plan/updated":
            let itemType = p["type"] as? String ?? (type == "item/started" ? "item_started" : type == "item/completed" ? "item_completed" : type == "thread/plan/updated" ? "plan_update" : "unknown")
            switch itemType {
            case "task_started", "task_complete", "task_completed", "turn_aborted":
                event.kind = .lifecycle; event.title = itemType
                index.turnID = p["turn_id"] as? String ?? index.turnID
                event.turnID = index.turnID
                event.preview = Self.preview(Self.pretty(p))
                event.isError = itemType == "turn_aborted"
            case "item_started", "item_completed":
                guard let item = p["item"] as? [String: Any] else { break }
                let completed = itemType == "item_completed"
                record.isCompletedItem = completed; record.protocolID = item["id"] as? String
                let subtype = item["type"] as? String ?? "unknown"
                event.kind = .lifecycle; event.title = "\(subtype) · observation enregistrée"
                event.callID = item["call_id"] as? String
                let itemCWD = item["cwd"] as? String
                if let itemCWD { event.environmentID = Self.resolve(itemCWD, cwd: index.cwd) }
                event.timestamp = Self.date(p["started_at_ms"]) ?? date
                event.endTime = completed ? Self.date(p["completed_at_ms"]) ?? date : nil
                event.isError = (item["exit_code"] as? Int).map { $0 != 0 } == true || ["failed", "error", "declined"].contains((item["status"] as? String ?? "").lowercased())
                record.positiveSuccess = completed && !event.isError && ((item["exit_code"] as? Int) == 0 || (item["status"] as? String ?? "").lowercased() == "completed")
                let command = Self.string(item["command"] ?? "")
                let output = Self.string(item["formatted_output"] ?? item["aggregated_output"] ?? item["output"] ?? item["result"] ?? "")
                event.preview = Self.preview(command.isEmpty ? Self.content(item) : command)
                if event.preview.isEmpty { event.preview = Self.preview(output.isEmpty ? Self.pretty(item) : output) }
                if subtype == "CommandExecution" {
                    event.kind = .toolCall; event.toolName = "exec_command"; event.callID = item["id"] as? String
                    let words = item["command"] as? [String]
                    let shell = words?.last ?? (item["command"] as? String ?? "")
                    let cwd = event.environmentID ?? index.cwd
                    let reads = Self.readPaths(shell, cwd: cwd)
                    record.resources += reads.map { ResourceCandidate(location: $0, role: record.positiveSuccess ? .recordedRead : .referenced, evidence: record.positiveSuccess ? "CommandExecution, cible de lecture explicite et succès positif enregistré" : "Cible de CommandExecution ; succès inconnu ou erreur enregistrée") }
                    if record.positiveSuccess { record.resources += Self.producedPaths(shell, cwd: cwd).map { ResourceCandidate(location: $0, role: .produced, evidence: "CommandExecution avec écriture explicite et résultat réussi enregistré") } }
                } else if subtype == "FileChange" || subtype == "fileChange" {
                    event.kind = .toolResult; event.toolName = "apply_patch"; event.callID = item["id"] as? String
                    let status = item["status"] as? String ?? "unknown"
                    record.fileChangeStatus = status
                    // A zero command exit code is not proof of a FileChange completion.
                    record.positiveSuccess = completed && !event.isError && status.lowercased() == "completed"
                    event.title = "\(subtype) · \(status) · observation enregistrée"
                    if status.lowercased() == "inprogress" { event.endTime = nil }
                    let paths: [String]
                    if let changes = item["changes"] as? [String: Any] {
                        paths = Array(changes.keys)
                    } else if let changes = item["changes"] as? [[String: Any]] {
                        paths = changes.compactMap { $0["path"] as? String ?? $0["file_path"] as? String }
                    } else { paths = [] }
                    record.resultPatchPaths = Array(Set(paths.filter { !$0.isEmpty && !$0.contains("\0") }.map { Self.resolve($0, cwd: event.environmentID ?? index.cwd) })).sorted()
                    record.resources += record.resultPatchPaths.map { ResourceCandidate(location: $0, role: record.positiveSuccess ? .modified : .referenced, evidence: record.fileChangeEvidence) }
                } else if subtype == "SubAgentActivity" {
                    event.kind = .delegation
                    event.callID = item["id"] as? String
                    event.title = "Sous-agent · \(item["kind"] as? String ?? "activité")"
                    event.preview = Self.preview(Self.pretty(item))
                    if item["kind"] as? String == "started" { record.spawnedChildID = item["agent_thread_id"] as? String }
                } else if subtype == "AgentMessage" || subtype == "agentMessage" {
                    event.kind = .assistant; event.title = "Réponse assistant enregistrée"; event.preview = Self.preview(Self.content(item))
                } else if subtype == "Reasoning" || subtype == "reasoning" {
                    event.kind = .context; event.title = "Explication enregistrée"; event.preview = ""
                } else if subtype == "Plan" || subtype == "plan" {
                    event.kind = .context; event.title = "Plan enregistré"; event.preview = ""
                } else if subtype == "UserMessage" {
                    event.kind = .user; event.title = "Message utilisateur enregistré"; event.preview = Self.preview(Self.content(item))
                } else if subtype == "McpToolCall" {
                    event.kind = .toolCall; event.callID = item["id"] as? String
                    event.toolName = "mcp__\(item["server"] as? String ?? "unknown")__\(item["tool"] as? String ?? "unknown")"
                    event.title = event.toolName ?? "Appel MCP enregistré"
                    let arguments = item["arguments"] as? [String: Any] ?? Self.jsonDictionary(Self.string(item["arguments"] ?? ""))
                    if let cwd = arguments["workdir"] as? String ?? arguments["cwd"] as? String { event.environmentID = Self.resolve(cwd, cwd: index.cwd) }
                    event.preview = Self.preview(Self.string(item["arguments"] ?? ""))
                    record.resources += Self.argumentResources(arguments, cwd: event.environmentID ?? index.cwd)
                }
                // Item-completed messages often mirror response_items. IDs confirm a relation;
                // an unrelated exec-* ID is retained as an observation, without guessing causality.
                if subtype == "UserMessage" { record.resources = Self.messageResources(item, text: Self.content(item), user: true, cwd: event.environmentID ?? index.cwd, eventID: event.id) }
            case "user_message", "agent_message", "agent_reasoning", "agent_reasoning_raw_content", "plan_update":
                // Legacy event messages mirror response_items without IDs. Retain their raw
                // references as context rather than silently dropping potentially unique text.
                event.kind = .context; event.title = "\(itemType) · trace de contexte"; event.preview = Self.preview(Self.content(p))
                if itemType == "user_message" { record.resources = Self.messageResources(p, text: Self.content(p), user: true, cwd: index.cwd, eventID: event.id) }
            case "error", "warning":
                event.kind = .error; event.title = itemType; event.preview = Self.preview(Self.content(p)); event.isError = true
            default:
                event.kind = .lifecycle; event.title = itemType; event.preview = Self.preview(Self.pretty(p))
            }
        case "turn_context": event.kind = .context; event.title = "Contexte du tour"; event.preview = "cwd : \(index.cwd) · tour : \(index.turnID ?? "inconnu")"
        case "compacted": event.kind = .compaction; event.title = "Compactage enregistré"; event.preview = Self.preview(p["message"] as? String ?? "")
        case "token_usage_record": event.kind = .context; event.title = "Consommation enregistrée par requête"; event.preview = "Compteurs enregistrés ; ne représentent pas une mesure du contexte."
        case "inter_agent_communication", "inter_agent_communication_metadata": event.kind = .delegation; event.title = "Communication inter-agent enregistrée"; event.preview = Self.preview(Self.content(p))
        default: event.kind = .context; event.title = type; event.preview = Self.preview(Self.content(p).isEmpty ? Self.pretty(p) : Self.content(p))
        }
        event.trace = RecordedTraceFacts.decode(root, event: event)
        if let explanation = event.trace?.explanation {
            if type == "item/started" || type == "item/completed" || type == "thread/plan/updated" {
                event.agentID = explanation.threadID; event.turnID = explanation.turnID
            }
            // These labels describe recorded visibility, never an explanation invented by Lens.
            if explanation.kind == .reasoningSummary { event.title = "Résumé de raisonnement enregistré" }
            else if explanation.kind == .exposedReasoning { event.title = "Raisonnement exposé enregistré" }
            else if explanation.kind == .plan, event.toolName == nil { event.title = "Plan enregistré" }
            if explanation.kind != .plan || event.toolName == nil {
                event.preview = Self.preview(explanation.preview)
                if event.preview.isEmpty {
                    switch explanation.availability {
                    case .opaque: event.preview = "Contenu opaque ; aucune explication lisible enregistrée."
                    case .empty: event.preview = "Champ d’explication enregistré vide."
                    case .unavailable: event.preview = "Contenu d’explication non disponible dans cet événement."
                    case .available: break
                    }
                } else if explanation.previewTruncated { event.preview += "\n[aperçu ; contenu complet chargé depuis la source]" }
            }
        }
        if let compaction = event.trace?.compaction {
            event.kind = .compaction; event.title = "Compactage enregistré"
            event.agentID = compaction.threadID // Explicit child producer beats the parent's shared hook session_id.
            record.protocolID = nil // Lifecycle/checkpoint representations are joined by the versioned context index.
            // Record time is not an operation boundary; duration remains unavailable without both bounds.
            event.endTime = compaction.startTime == nil ? nil : compaction.endTime
            if let start = compaction.startTime { event.timestamp = start }
            if event.preview.isEmpty || compaction.visibility == .opaque { event.preview = "Représentation compacte ; ouvrir les données et les limites enregistrées." }
        }
        if event.trace?.usage != nil, type == "event_msg" { event.kind = .context; event.title = "Mesure de tokens enregistrée" }
        record.event = event
        record.event.source.sha256 = record.fingerprint
        index.records.append(record)
    }

    /// The copied prefix is context evidence, never activity attributed to the child.
    private func retainInheritedReference(line: Data, source: SourceRef, index: inout FileIndex) {
        let id = index.owner + ":" + Self.digest(source.path) + ":inherited-context"
        var reference = source; reference.sha256 = Self.digest(line)
        if let position = index.records.firstIndex(where: { $0.event.id == id }) {
            if index.records[position].event.supplementarySources.count < 999 {
                index.records[position].event.supplementarySources.append(reference)
            } else if !index.issues.contains(where: { $0.category == "contexte hérité borné" }) {
                index.issues.append(CoverageIssue("contexte hérité borné", "Mille références de lignes héritées indexées ; la suite reste dans le journal source et n’est pas reconstituée.", source: source.path))
            }
            return
        }
        let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let time = Self.date(root?["timestamp"]) ?? .distantPast
        let facts = RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded,
            affectedAgentID: index.owner, instructionKind: .inherited, inheritedFromThreadID: summaries[index.owner]?.parentID,
            limitations: ["Préfixe hérité indiqué par subagent_history_start_ordinal ; aucune activité propre ni application de la consigne déduite."])
        let inherited = LensEvent(id: id, timestamp: time, agentID: index.owner, kind: .instruction,
            title: "Contexte hérité enregistré", preview: "Préfixe de conversation ; sources disponibles à la demande, distinctes de l’activité du sous-agent.",
            source: reference, trace: RecordedTraceFacts(communication: facts, recordedAt: time == .distantPast ? nil : time, collectedAt: Date()))
        var record = IndexedEvent(event: inherited); record.fingerprint = reference.sha256; index.records.append(record)
    }

    private func restore(root: String) {
        let url = cacheDirectory.appendingPathComponent(Self.digest(home.path + ":" + root) + ".json")
        guard (try? LocalContentGuard.requireResident(path: url.path)) != nil else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber, size.intValue <= maximumCacheBytes, let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == cacheVersion, cache.home == home.path else { return }
        files = cache.files
    }

    private func discoverSpawnedChildren(in owners: Set<String>) {
        for file in files.values where owners.contains(file.owner) {
            var spawnCalls = Set<String>()
            for record in file.records {
                let event = record.event
                if let child = record.spawnedChildID, child != file.owner, !excludedInvestigationIDs.contains(child) {
                    if summaries[child] == nil { summaries[child] = SessionSummary(id: child, parentID: file.owner, relation: .subagent, evidence: "SubAgentActivity started, agent_thread_id enregistré ; journal indisponible") }
                    else if summaries[child]?.parentID == nil { summaries[child]?.parentID = file.owner; summaries[child]?.relation = .subagent; summaries[child]?.evidence += "; SubAgentActivity started, agent_thread_id enregistré" }
                }
                if event.toolName?.contains("spawn_agent") == true, let callID = event.callID { spawnCalls.insert(callID) }
                autoreleasepool {
                    if event.kind == .toolResult, let callID = event.callID, spawnCalls.contains(callID), !event.isError,
                       let raw = try? Self.read(event.source), let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let payload = root["payload"] as? [String: Any] {
                        let output = Self.jsonDictionary(Self.string(payload["output"] ?? ""))
                        if let child = output["agent_id"] as? String ?? output["thread_id"] as? String,
                           !excludedInvestigationIDs.contains(child),
                           child.range(of: #"^[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27}$"#, options: .regularExpression) != nil {
                            if summaries[child] == nil { summaries[child] = SessionSummary(id: child, parentID: file.owner, relation: .subagent, evidence: "spawn_agent \(callID) → agent_id enregistré ; journal indisponible") }
                            else if summaries[child]?.parentID == nil { summaries[child]?.parentID = file.owner; summaries[child]?.relation = .subagent; summaries[child]?.evidence += "; spawn_agent \(callID) → agent_id enregistré" }
                        }
                    }
                }
            }
        }
    }
    private func selectedSignature(root: String) -> String {
        struct AgentAttributes: Encodable {
            let name: String?
            let cliVersion: String?
            let metadata: [AgentMetadataField]?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let ids = descendants(of: root).sorted()
        return Self.digest(ids.map { id in
            let summary = summaries[id]
            // The thread database can change while the journal stays unchanged.
            // Refresh the displayed fields without invalidating cached headers.
            let attributes = AgentAttributes(name: summary?.agentName,
                cliVersion: summary?.cliVersion, metadata: summary?.agentMetadata)
            let metadataSignature = Self.digest((try? encoder.encode(attributes)) ?? Data())
            let paths = (summary?.paths ?? []).sorted().map { path in
                let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                return path + ":" + String(describing: a[.size] ?? "") + ":" + String(describing: a[.systemFileNumber] ?? "") + ":" + String((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            }.joined(separator: "|")
            return id + ":" + (summary?.parentID ?? "") + ":" + (summary?.relation.rawValue ?? "") + ":" + (summary?.title ?? "") + ":" + paths + ":" + metadataSignature
        }.joined(separator: "\n"))
    }
    private func persist(root: String) -> CoverageIssue? {
        // Cache is disposable, bounded and confined to Lens' own directory. Sources are untouched.
        let oversized = CoverageIssue("cache borné", "L'index dépasse 64 Mio : disponible en mémoire mais non persisté ; une nouvelle ouverture réindexera les sources.")
        // Every preview is a required JSON string. Its unescaped UTF-8 length is a lower
        // bound, so exceeding the limit already proves the cache cannot be persisted.
        // Avoid encoding an enormous disposable cache merely to discard it afterwards.
        let previews = files.values.lazy.flatMap { $0.records.lazy.map { $0.event.preview } }
        guard !Self.cacheTextExceedsByteLimit(previews, limit: maximumCacheBytes) else { return oversized }
        guard let data = try? JSONEncoder().encode(Cache(version: cacheVersion, home: home.path, files: files)) else { return CoverageIssue("cache", "Index non sauvegardé ; la prochaine ouverture relira les sources.") }
        guard data.count <= maximumCacheBytes else { return oversized }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let url = cacheDirectory.appendingPathComponent(Self.digest(home.path + ":" + root) + ".json")
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let urls = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]).filter { $0.pathExtension == "json" }
            let sorted = urls.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            var total = 0
            for file in sorted { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0; if total > maximumCacheBytes && file != url { try? FileManager.default.removeItem(at: file) } }
            return nil
        } catch { return CoverageIssue("cache", "Cache personnel non accessible : \(error.localizedDescription). La lecture des journaux reste disponible.", source: cacheDirectory.path) }
    }

    /// A conservative lower bound only; the encoded byte guard remains authoritative.
    static func cacheTextExceedsByteLimit<Texts: Sequence>(_ texts: Texts, limit: Int) -> Bool where Texts.Element == String {
        guard limit >= 0 else { return true }
        var remaining = limit
        for text in texts {
            let count = text.utf8.count
            guard count <= remaining else { return true }
            remaining -= count
        }
        return false
    }

    private static func catalogHeader(path: String) throws -> SessionCatalogHeader? {
        let (first, source) = try firstRecord(path: path, limit: 16 * 1024 * 1024)
        guard first["type"] as? String == "session_meta", let payload = first["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty else { return nil }
        let parsed = RolloutMetadata(payload: payload)
        return SessionCatalogHeader(id: id, sessionID: parsed.sessionID, cwd: parsed.cwd,
            cliVersion: payload["cli_version"] as? String, name: parsed.name, branch: parsed.branch, gitRef: parsed.gitRef,
            parent: parsed.parent, relation: parsed.relation, historyStart: parsed.historyStart, source: source,
            agentMetadata: AgentMetadataField.sessionFields(payload, source: source))
    }
    private static func firstRecord(path: String, limit: Int) throws -> ([String: Any], SourceRef) {
        try LocalContentGuard.requireResident(path: path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let newlineOffset = chunk.withUnsafeBytes { bytes -> Int? in
                guard let start = bytes.baseAddress, let newline = memchr(start, 10, bytes.count) else { return nil }
                return start.distance(to: newline)
            }
            if let newlineOffset {
                guard data.count <= limit - newlineOffset else { throw LensError.unsupported("session_meta dépasse \(limit) octets") }
                data.append(contentsOf: chunk.prefix(newlineOffset))
                let record = data
                return ((try JSONSerialization.jsonObject(with: record)) as? [String: Any] ?? [:], SourceRef(path: path, offset: 0, length: record.count, line: 1, sha256: Self.digest(record)))
            }
            guard data.count <= limit - chunk.count else { throw LensError.unsupported("session_meta dépasse \(limit) octets") }
            data.append(chunk)
        }
        return ((try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], SourceRef(path: path, offset: 0, length: data.count, line: 1, sha256: Self.digest(data)))
    }
    private static func rolloutPaths(in directory: URL, onFile: (() throws -> Void)? = nil) rethrows -> Set<String> {
        var paths = Set<String>()
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                paths.insert(file.path); try onFile?()
            }
        }
        return paths
    }
    private static func sourceSignature(home: URL) -> String {
        var paths = rolloutPaths(in: home.appendingPathComponent("sessions"))
        paths.formUnion(rolloutPaths(in: home.appendingPathComponent("archived_sessions")))
        for name in ["state_5.sqlite", "state_5.sqlite-wal", "session_index.jsonl"] { paths.insert(home.appendingPathComponent(name).path) }
        return digest(paths.sorted().map { path in let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]; return path + ":" + String(describing: a[.size] ?? "") + ":" + String(describing: a[.systemFileNumber] ?? "") + ":" + String((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) }.joined(separator: "\n"))
    }
    private static func boundaryFingerprint(path: String, offset: UInt64) throws -> String {
        let length = min(offset, 2048)
        return digest(try read(SourceRef(path: path, offset: offset - length, length: Int(length))))
    }
    private static func read(_ source: SourceRef) throws -> Data {
        let file = URL(fileURLWithPath: source.path)
        try LocalContentGuard.requireResident(path: source.path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LensError.unavailable("Source disparue : \(source.path).") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: source.offset)
        let bytes = try handle.read(upToCount: source.length) ?? Data()
        guard bytes.count == source.length else { throw LensError.unavailable("Source raccourcie : événement \(source.line) plus disponible en entier.") }
        return bytes
    }
    private static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { let value = n.doubleValue; return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value) }
        guard let text = value as? String else { return nil }
        return fractionalDateFormatter.date(from: text) ?? wholeDateFormatter.date(from: text)
    }
    private static let fractionalDateFormatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let wholeDateFormatter = ISO8601DateFormatter()
    fileprivate static func spawnMetadata(_ source: [String: Any]) -> [String: Any]? { ((source["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]) }
    fileprivate static func jsonDictionary(_ string: String) -> [String: Any] { guard let data = string.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }; return value }
    private static func pretty(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: bytes, encoding: .utf8) else { return String(describing: value) }; return text }
    private static func string(_ value: Any) -> String { if let string = value as? String { return string }; return pretty(value) }
    private static func content(_ p: [String: Any]) -> String {
        if let string = p["content"] as? String { return string }
        if let parts = p["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String ?? $0["content"] as? String }.joined(separator: "\n") }
        if let summary = p["summary"] as? [[String: Any]] { return summary.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        for key in ["message", "text", "summary_text", "raw_content", "last_agent_message"] { if let string = p[key] as? String { return string } }
        return ""
    }
    private static func preview(_ text: String) -> String {
        let limit = 1200
        let bounded = String(text.prefix(limit + 1))
        let more = bounded.count > limit
        let clean = redact(String(bounded.prefix(limit)))
        return more ? clean + "\n[aperçu ; contenu complet chargé depuis la source]" : clean
    }
    private static let redactions: [(NSRegularExpression, String)] = [#"(?i)(\"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|client_secret|creator_user_id|creator_account_id)\"\s*:\s*\")[^\"]*(\")"#, #"(?i)(Bearer\s+)[A-Za-z0-9._~+/-]{12,}"#, #"\bsk-[A-Za-z0-9_-]{16,}\b"#].compactMap { pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, pattern.hasPrefix("\\b") ? "[secret masqué]" : pattern.contains("Bearer") ? "$1[secret masqué]" : "$1[secret masqué]$2")
    }
    private static func redact(_ text: String) -> String {
        var value = text
        for (regex, replacement) in redactions {
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
        }
        return value
    }
    private static let failureDiagnostics = [#"(?i)(?:exit(?:ed)?(?: with)? (?:code|status)\s*[:=]?\s*)([1-9][0-9]*)"#, #"(?m)^Error: "#, #"(?m)^Failed to "#].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let successDiagnostics = [#"(?i)(?:Process exited with code|Process exit code|exit code|exited with status)\s*[:=]?\s*0\b"#, #"(?m)^Success\. Updated the following files:"#, #"(?m)^Success\. "#].compactMap { try? NSRegularExpression(pattern: $0) }
    private static func matchesDiagnostic(_ diagnostic: String, patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(location: 0, length: (diagnostic as NSString).length)
        return patterns.contains { $0.firstMatch(in: diagnostic, range: range) != nil }
    }
    static func outputFailed(_ output: String) -> Bool {
        let diagnostic = output.utf8.count > 8192 ? String(output.prefix(4096)) + "\n" + String(output.suffix(4096)) : output
        if output.utf8.count <= 8192, let value = jsonDictionary(output)["isError"] as? Bool { return value }
        return matchesDiagnostic(diagnostic, patterns: failureDiagnostics)
    }
    static func outputSucceeded(_ output: String) -> Bool {
        let object = output.utf8.count <= 8192 ? jsonDictionary(output) : [:]
        if object["exit_code"] as? Int == 0 || object["exitCode"] as? Int == 0 { return true }
        if (object["status"] as? String ?? "").lowercased() == "completed" { return true }
        let diagnostic = output.utf8.count > 8192 ? String(output.prefix(4096)) + "\n" + String(output.suffix(4096)) : output
        return matchesDiagnostic(diagnostic, patterns: successDiagnostics)
    }
    private static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    private static let digestHex = Array("0123456789abcdef".utf8)
    private static func digest(_ value: Data) -> String {
        var encoded: [UInt8] = []; encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: value) {
            encoded.append(digestHex[Int(byte >> 4)]); encoded.append(digestHex[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
    private static func resolve(_ path: String, cwd: String) -> String {
        if path.hasPrefix("file://"), let url = URL(string: path) { return url.standardizedFileURL.path }
        if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("data:") || path.hasPrefix("trace:") { return path }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        if path.hasPrefix("~" ) { return (path as NSString).expandingTildeInPath }
        guard !cwd.isEmpty else { return path }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path).standardizedFileURL.path
    }
    private static func availability(_ location: String) -> Availability {
        if location.hasPrefix("http://") || location.hasPrefix("https://") { return .external }
        if location.hasPrefix("trace:") || location.hasPrefix("data:") { return .unknown }
        if location.hasPrefix("/") { return FileManager.default.fileExists(atPath: location) ? .accessible : .missing }
        return .unknown
    }
    private static func repositoryRoot(_ cwd: String) -> String? {
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { return nil }
        var directory = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<40 { if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory.path }; let parent = directory.deletingLastPathComponent(); if parent == directory { break }; directory = parent }
        return nil
    }
    private static func namedPaths(_ args: [String: Any], cwd: String) -> [String] {
        var paths: [String] = []
        for (key, value) in args {
            if ["path", "file", "file_path", "filename", "image_path", "output_path", "source_path"].contains(key), let path = value as? String { paths.append(resolve(path, cwd: cwd)) }
            else if let nested = value as? [String: Any] { paths += namedPaths(nested, cwd: cwd) }
            else if let list = value as? [[String: Any]] { for nested in list { paths += namedPaths(nested, cwd: cwd) } }
        }
        return Array(Set(paths))
    }
    private static func argumentResources(_ args: [String: Any], cwd: String) -> [ResourceCandidate] { namedPaths(args, cwd: cwd).map { ResourceCandidate(location: $0, role: .referenced, evidence: "Chemin structuré dans les arguments ; lecture non déduite") } }
    private static func matches(_ text: String, _ pattern: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in guard match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }; return String(text[range]) }
    }
    private static func pathReferences(_ text: String, cwd: String) -> [String] {
        let absolute = matches(text, #"(?:^|[\s\"'`(])((?:/Users/|/tmp/|/var/|/private/|/Volumes/|/home/)[^\\\n\"'`<>;,)]+)"#).map { candidate -> String in
            var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".:}"))
            // A filesystem lookup disambiguates spaces in an accessible mentioned path.
            // It supplies no read provenance, and does not change the source.
            if FileManager.default.fileExists(atPath: value) { return value }
            while let lastSpace = value.lastIndex(of: " ") {
                let prefix = String(value[..<lastSpace]).trimmingCharacters(in: CharacterSet(charactersIn: ".:}"))
                if FileManager.default.fileExists(atPath: prefix) { return prefix }
                value = prefix
            }
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".:}"))
        }
        let urls = matches(text, #"(https?://[^\s\"'`<>)]+)"#)
        return Array(Set((absolute + urls).map { resolve($0, cwd: cwd) }))
    }
    private static func messageResources(_ p: [String: Any], text: String, user: Bool, cwd: String, eventID: String) -> [ResourceCandidate] {
        var candidates = pathReferences(text, cwd: cwd).map { ResourceCandidate(location: $0, role: .referenced, evidence: "Mention de chemin/lien dans un message ; aucune lecture déduite") }
        if user {
            // Only explicit attachment sections claim supplied provenance. A later request
            // or another top-level heading ends the section, even in a single message.
            let suppliedHeader = #"(?i)^[ \t]*(?:#[ \t]+)?(?:\[Files\]|Files(?: (?:supplied|pasted) by the user)?[ \t]*:|Pièces jointes[ \t]*:)[ \t]*$"#
            let sectionBoundary = #"(?i)^[ \t]*(?:#[ \t]+[^#]|(?:My request|Files mentioned by the user)[ \t]*:)"#
            var sections: [[String]] = []
            var attachmentLines: [String]?
            for line in text.components(separatedBy: .newlines) {
                if line.range(of: suppliedHeader, options: .regularExpression) != nil {
                    if let attachmentLines { sections.append(attachmentLines) }
                    attachmentLines = []
                } else if attachmentLines != nil, line.range(of: sectionBoundary, options: .regularExpression) != nil {
                    if let attachmentLines { sections.append(attachmentLines) }
                    attachmentLines = nil
                } else if attachmentLines != nil {
                    attachmentLines?.append(line)
                }
            }
            if let attachmentLines { sections.append(attachmentLines) }
            for section in sections {
                let body = section.joined(separator: "\n")
                let titledPaths = matches(body, #"(?m)^[ \t]*##[ \t]*[^\r\n]*?:[ \t]*(/[^\r\n]+)$"#)
                // Pasted documents carry their path in an attachment title. Paths inside
                // their pasted contents remain mentions, not additional supplied files.
                let hasTitles = body.range(of: #"(?m)^[ \t]*##[^#]"#, options: .regularExpression) != nil
                let suppliedPaths = hasTitles ? titledPaths.map { resolve($0.trimmingCharacters(in: .whitespaces), cwd: cwd) } : pathReferences(body, cwd: cwd)
                for path in Set(suppliedPaths) {
                    candidates.append(ResourceCandidate(location: path, role: .supplied, evidence: "Message utilisateur, section explicite Files/pièces jointes bornée ; référence fournie, disponibilité vérifiée séparément"))
                }
            }
        }
        let parts = p["content"] as? [[String: Any]] ?? []
        for (i, part) in parts.enumerated() {
            let type = part["type"] as? String ?? ""
            if ["input_image", "image", "localImage", "local_image", "input_file", "file"].contains(type) {
                let direct = part["path"] as? String ?? part["file_path"] as? String ?? part["url"] as? String
                let image = part["image_url"] as? String ?? (part["image_url"] as? [String: Any])?["url"] as? String
                let path = direct ?? image
                let location = path.map { $0.hasPrefix("data:") ? "trace:\(eventID):attachment:\(i)" : resolve($0, cwd: cwd) } ?? "trace:\(eventID):attachment:\(i)"
                let embeddedAvailable = path.map { path in path.hasPrefix("data:image/") && path.contains(";base64,") && path.split(separator: ",", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }.map { !$0.isEmpty } == true } ?? false
                candidates.append(ResourceCandidate(location: location, role: user ? .supplied : .referenced, evidence: embeddedAvailable ? "Pièce jointe image structurée ; octets base64 enregistrés et décodables dans l'événement source" : "Pièce jointe structurée \(type) ; référence seule, disponibilité vérifiée séparément", availability: embeddedAvailable ? .accessible : nil))
            }
        }
        for key in ["local_images", "localImages", "images", "attachments"] {
            if let paths = p[key] as? [String] { for path in paths { candidates.append(ResourceCandidate(location: path.hasPrefix("data:") ? "trace:\(eventID):\(key)" : resolve(path, cwd: cwd), role: user ? .supplied : .referenced, evidence: "Pièce jointe structurée \(key)")) } }
        }
        return candidates
    }
    private static func commandDirectory(_ command: String, cwd: String) -> String? {
        // Only a literal leading `cd` is recognized; dynamic substitutions are never evaluated.
        guard let path = matches(command, #"^\s*cd\s+(?:\"([^\"$`]+)\"|'([^']+)'|([^\s;&|$`]+))\s*(?:&&|;)"#, group: 1).first ?? matches(command, #"^\s*cd\s+'([^']+)'\s*(?:&&|;)"#).first ?? matches(command, #"^\s*cd\s+([^\s;&|$`]+)\s*(?:&&|;)"#).first else { return nil }
        return resolve(path, cwd: cwd)
    }
    private static func patchPaths(_ patch: String, cwd: String) -> [String] { matches(patch, #"(?m)^\*\*\* (?:Add|Update|Delete) File: (.+)$"#).map { resolve($0.trimmingCharacters(in: .whitespaces), cwd: cwd) } }
    private static func readPaths(_ command: String, cwd: String) -> [String] {
        // An explicit cat/read target is a recorded read attempt. Search paths are references.
        let paths = matches(command, #"(?:^|&&\s*|;\s*)(?:rtk\s+)?(?:cat|read)\s+(?:\"([^\"]+)\")"#) + matches(command, #"(?:^|&&\s*|;\s*)(?:rtk\s+)?(?:cat|read)\s+([^\s;|&<>]+)"#)
        return Array(Set(paths.filter { !$0.hasPrefix("-") && !$0.hasPrefix("\"") && !$0.hasPrefix("'") && !$0.contains("$") && !$0.contains("`") }.map { resolve($0, cwd: cwd) }))
    }
    private static func producedPaths(_ command: String, cwd: String) -> [String] {
        let paths = matches(command, #"(?:^|[\s])(?:>|>>)\s*(?:\"([^\"]+)\")"#) + matches(command, #"(?:^|[\s])(?:>|>>)\s*([^\s;|&<>]+)"#)
        return paths.filter { !$0.contains("$") && !$0.contains("`") && $0 != "/dev/null" }.map { resolve($0, cwd: cwd) }
    }
}

private final class RolloutMetadata {
    var id: String, sessionID: String?, cwd: String, branch: String?, gitRef: String?, name: String, parent: String?, relation: RelationKind, historyStart: Int?
    init(id: String, cwd: String = "", branch: String? = nil, gitRef: String? = nil, name: String = "", parent: String? = nil, relation: RelationKind = .root) { self.id = id; self.cwd = cwd; self.branch = branch; self.gitRef = gitRef; self.name = name; self.parent = parent; self.relation = relation }
    convenience init(payload p: [String: Any]) {
        let source = p["source"] as? [String: Any] ?? SessionEngine.jsonDictionary(p["source"] as? String ?? "")
        let spawn = SessionEngine.spawnMetadata(source)
        let parent = p["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
        let fork = p["forked_from_id"] as? String ?? p["forked_from_thread_id"] as? String
        let continuation = p["resumed_from_id"] as? String ?? p["continued_from_id"] as? String
        let git = p["git"] as? [String: Any] ?? [:]
        self.init(id: p["id"] as? String ?? "", cwd: p["cwd"] as? String ?? "", branch: git["branch"] as? String, gitRef: git["commit_hash"] as? String, name: p["agent_nickname"] as? String ?? p["agent_path"] as? String ?? spawn?["agent_nickname"] as? String ?? "", parent: parent ?? fork ?? continuation, relation: parent != nil || spawn != nil ? .subagent : fork != nil ? .fork : continuation != nil ? .continuation : .root)
        sessionID = p["session_id"] as? String
        historyStart = p["subagent_history_start_ordinal"] as? Int
    }
}
private struct ResourceCandidate: Codable { var location: String; var role: ResourceRole; var evidence: String; var availability: Availability? = nil }
private struct IndexedEvent: Codable {
    var event: LensEvent
    var fingerprint: String?
    var positiveSuccess = false
    var fileChangeStatus: String?
    var fileChangeStatuses: [String]?
    var protocolID: String?
    var isCompletedItem = false
    var resources: [ResourceCandidate] = []
    var readPaths: [String] = []
    var patchPaths: [String] = []
    var resultPatchPaths: [String] = []
    var spawnedChildID: String?
    var delegatedMission: String?
    var delegatedMetadata: [AgentMetadataField]?
    var producedPaths: [String] = []
    mutating func mergeFileChangeStatus(_ other: IndexedEvent, isError: Bool) {
        let existing = fileChangeStatuses ?? fileChangeStatus.map { [$0] } ?? []
        let incoming = other.fileChangeStatuses ?? other.fileChangeStatus.map { [$0] } ?? []
        guard !existing.isEmpty || !incoming.isEmpty else { return }
        let statuses = Array(Set(existing + incoming)).sorted()
        fileChangeStatuses = statuses
        fileChangeStatus = statuses.joined(separator: " / ")
        resultPatchPaths = Array(Set(resultPatchPaths)).sorted()
        // Conflicting native observations cannot certify success by OR-ing their booleans.
        positiveSuccess = !isError && Set(statuses.map { $0.lowercased() }) == Set(["completed"])
        if !positiveSuccess {
            let affected = Set(resultPatchPaths)
            let evidence = fileChangeEvidence
            resources = resources.map { candidate in
                guard candidate.role == .modified && affected.contains(candidate.location) else { return candidate }
                return ResourceCandidate(location: candidate.location, role: .referenced, evidence: evidence, availability: candidate.availability)
            }
        }
    }
    var fileChangeEvidence: String {
        let status = fileChangeStatus ?? "unknown"
        let outcome = positiveSuccess ? "succès déclaré, contenu dans la source ; état courant non attribué" : "aucun succès ni octet modifié déduit"
        return "FileChange · statut \(status) enregistré ; \(outcome)."
    }
}
private struct FileIndex: Codable {
    var owner: String
    var inode: UInt64 = 0
    var offset: UInt64 = 0
    var line = 0
    var pendingBytes = 0
    var cwd = ""
    var turnID: String?
    var historyStart: Int?
    var boundaryFingerprint: String?
    var records: [IndexedEvent] = []
    var issues: [CoverageIssue] = []
    var spawnCallIDs = Set<String>()
}
private struct Cache: Codable { var version: Int; var home: String; var files: [String: FileIndex] }

private final class ReadOnlyDatabase {
    private var database: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite non disponible"; if let database { sqlite3_close(database) }; throw LensError.unavailable(message) }
        sqlite3_busy_timeout(database, 150)
    }
    deinit { sqlite3_close(database) }
    func columns(_ table: String) throws -> Set<String> { Set(try rows("PRAGMA table_info(" + table + ")").compactMap { $0["name"] }) }
    func rows(_ query: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw LensError.unsupported(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) { if let name = sqlite3_column_name(statement, i), let text = sqlite3_column_text(statement, i) { row[String(cString: name)] = String(cString: text) } }
            rows.append(row); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw LensError.unavailable(String(cString: sqlite3_errmsg(database))) }
        return rows
    }
}
