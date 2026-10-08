import AppKit
import Combine
import CryptoKit
import Foundation
import LensCore

/// Production reader and passive polling on dedicated anonymous journals only.
/// The native launcher supplies the frozen source manifest and denies network.
@main struct LargeHistoryFollowMain {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Large history follow qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output").standardizedFileURL.resolvingSymlinksInPath()
        guard (output.path.hasPrefix("/private/tmp/") || output.path.hasPrefix("/tmp/")),
              output.lastPathComponent.hasPrefix("CodexLens-") || output.lastPathComponent.hasPrefix("lens-ci-") else {
            throw LensError.unavailable("Use an owned private temporary output directory.")
        }
        UserDefaults.standard.setVolatileDomain(["lensLanguage": "en"], forName: UserDefaults.argumentDomain)
        LensL10n.language = .en
        var checks: [[String: Any]] = [], observations: [[String: Any]] = []
        var complete = false, stage = "source-freeze"
        func check(_ name: String, _ passed: Bool) throws {
            checks.append(["name": name, "passed": passed])
            if !passed { throw LensError.unavailable(name) }
        }
        func writeReceipt(_ completed: Bool) {
            let receipt: [String: Any] = [
                "checks": checks, "renders": [String](), "observations": observations,
                "completed": completed, "failedStage": completed ? "none" : stage,
                "allExecutedChecksPassed": completed && checks.allSatisfy { $0["passed"] as? Bool == true },
                "fixture": ["anonymous": true, "origin": "Dedicated generated JSONL journals",
                    "largeInitialEvents": 100_001, "largeFinalEvents": 100_002, "smallEvents": 3,
                    "maximumJournalBytes": LifecycleFixture.maximumBytes, "appendedOwnedRecords": 1],
                "scope": "Frozen production LensStore.start/open, passive two-second collector polling, waiting state and explicit toggleFollow command. Only the generated large journal is appended.",
                "memoryContract": "One large history, one append, streamed 64 KiB fixture writes, scalar publication observers and no retained baseline snapshot or presentation. Expected process use below 1 GiB; the runner must measure the actual peak.",
                "unqualified": ["No production GUI, user session, authenticated inference or recorded tool execution is qualified.",
                    "No memory or latency improvement is inferred from this functional regression."]
            ]
            if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
            }
        }
        defer {
            if !complete {
                checks.append(["name": "flow-completes-after-" + stage, "passed": false])
                writeReceipt(false)
            }
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        try check("source-matched-frozen-production-store-entrypoint",
            manifest?["entrypoint"] as? String == "LargeHistoryFollowMain.swift"
                && manifest?["copiedAppSourcesModified"] as? Bool == false
                && manifest?["productionEntryPointReplaced"] as? Bool == true)

        // Finish and release the tiny reader before allocating the large history.
        stage = "small-history"
        let small = try LifecycleFixture(output: output, name: "small-history", rootID: "aaaaaaaa-1111-4111-8111-111111111111", eventCount: 3)
        let smallObservation = try await inspectSmall(small, output: output)
        observations.append(smallObservation)
        try check("small-history-still-starts-following",
            smallObservation["openComplete"] as? Bool == true && smallObservation["follow"] as? Bool == true
                && smallObservation["snapshotEvents"] as? Int == 3 && smallObservation["presentationEvents"] as? Int == 3)
        try check("small-owned-journal-remains-unchanged", try small.matchesExpectedBytes())

        stage = "large-history-open"
        let large = try LifecycleFixture(output: output, name: "large-history", rootID: "bbbbbbbb-2222-4222-8222-222222222222", eventCount: 100_001)
        let store = makeStore(large, output: output)
        defer { store.stopObserving() }
        await store.start()
        await store.open(large.rootID)
        try check("large-history-production-open-completes",
            !store.busy && store.openingProgress == nil && store.error == nil && store.hasSessionReader
                && store.snapshot?.root.id == large.rootID && store.snapshot?.events.count == large.eventCount)
        try check("large-history-starts-with-visual-follow-paused",
            !store.follow && !store.liveState.following && store.waitingEvents == 0 && !store.waitingUpdates)
        let initiallyPresented = try await waitUntil {
            !store.isProjecting && !store.timelinePreparing && store.presentation?.rootID == large.rootID
                && store.presentation?.filteredEvents.count == large.eventCount && store.timelineProjection != nil
        }
        try check("large-history-initial-presentation-completes", initiallyPresented && store.timelineIssue == nil)
        await store.waitForPresentation()
        try check("large-history-indexes-only-owned-lifecycle-records", store.snapshot?.events.allSatisfy {
            $0.kind == .lifecycle && URL(fileURLWithPath: $0.source.path).standardizedFileURL == large.journal.standardizedFileURL
        } == true)
        guard let frozenPresentationID = store.presentation?.id, let frozenCollectedAt = store.snapshot?.collectedAt else {
            throw LensError.unavailable("Missing initial large history publication.")
        }
        let openingIdentity = store.openingIdentity
        var snapshotPublications = 0, presentationPublications = 0
        let snapshotSubscription = store.$snapshot.dropFirst().sink { _ in snapshotPublications += 1 }
        let presentationSubscription = store.$presentation.dropFirst().sink { _ in presentationPublications += 1 }
        defer { snapshotSubscription.cancel(); presentationSubscription.cancel() }
        observations.append(["stage": "initial-open", "journalBytes": large.expectedBytes,
            "snapshotEvents": store.snapshot?.events.count ?? 0,
            "presentationEvents": store.presentation?.filteredEvents.count ?? 0, "follow": store.follow])

        stage = "passive-append"
        let appended = try large.appendLifecycleEvent()
        // Do not call engine.refresh(), assign snapshot, or enable follow here:
        // waitingEvents must result from the store's production polling task.
        let passivelyCollected = try await waitUntil { store.waitingUpdates && store.waitingEvents == 1 }
        try check("paused-large-history-passively-collects-one-valid-append", passivelyCollected && store.error == nil)
        try check("passive-collection-keeps-displayed-snapshot-and-presentation-frozen",
            !store.follow && store.openingIdentity == openingIdentity
                && store.snapshot?.events.count == large.eventCount && store.snapshot?.collectedAt == frozenCollectedAt
                && store.presentation?.id == frozenPresentationID && store.presentation?.filteredEvents.count == large.eventCount
                && snapshotPublications == 0 && presentationPublications == 0
                && !store.isProjecting && !store.timelinePreparing)
        observations.append(["stage": "passive-collection", "waitingEvents": store.waitingEvents,
            "snapshotPublications": snapshotPublications, "presentationPublications": presentationPublications,
            "snapshotEvents": store.snapshot?.events.count ?? 0, "presentationEvents": store.presentation?.filteredEvents.count ?? 0])

        stage = "explicit-resume"
        store.toggleFollow()
        let resumed = try await waitUntil {
            store.follow && !store.waitingUpdates && store.waitingEvents == 0
                && store.snapshot?.events.count == large.eventCount + 1
                && store.presentation?.filteredEvents.count == large.eventCount + 1
                && store.presentation?.id != frozenPresentationID && !store.isProjecting && !store.timelinePreparing
        }
        try check("explicit-follow-command-publishes-collected-snapshot-and-presentation", resumed && store.error == nil)
        await store.waitForPresentation()
        let appendedEvent = store.snapshot?.events.first {
            $0.source.offset == appended.offset && URL(fileURLWithPath: $0.source.path).standardizedFileURL == large.journal.standardizedFileURL
        }
        try check("resumed-event-retains-appended-record-provenance",
            appendedEvent?.kind == .lifecycle && appendedEvent?.title == "task_completed"
                && appendedEvent?.source.line == large.eventCount + 2 && appendedEvent?.source.length == appended.recordLength
                && appendedEvent.flatMap { store.presentation?.eventsByID[$0.id] }?.source == appendedEvent?.source)
        try check("resume-publishes-one-snapshot-and-one-new-presentation", snapshotPublications == 1 && presentationPublications == 1)
        try check("only-intended-owned-journal-append-is-present", try large.matchesExpectedBytes() && small.matchesExpectedBytes())
        observations.append(["stage": "explicit-resume", "waitingEvents": store.waitingEvents,
            "snapshotPublications": snapshotPublications, "presentationPublications": presentationPublications,
            "snapshotEvents": store.snapshot?.events.count ?? 0, "presentationEvents": store.presentation?.filteredEvents.count ?? 0,
            "journalBytes": large.expectedBytes, "appendedSourceOffset": appended.offset])
        snapshotSubscription.cancel(); presentationSubscription.cancel()
        store.stopObserving()
        await store.investigation.flushAndStop()
        stage = "complete"; complete = true; writeReceipt(true)
    }

    @MainActor private static func makeStore(_ fixture: LifecycleFixture, output: URL) -> LensStore {
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent(fixture.name + "-archive")),
            cacheDirectory: output.appendingPathComponent(fixture.name + "-cache"), readerPool: SessionReaderPool())
        store.investigation.automaticCodexCheckEnabled = false
        store.setNavigationScope("anonymous-large-history-follow-" + UUID().uuidString)
        return store
    }

    @MainActor private static func inspectSmall(_ fixture: LifecycleFixture, output: URL) async throws -> [String: Any] {
        let store = makeStore(fixture, output: output)
        defer { store.stopObserving() }
        await store.start(); await store.open(fixture.rootID)
        let presented = try await waitUntil { !store.isProjecting && !store.timelinePreparing && store.presentation?.filteredEvents.count == fixture.eventCount }
        guard presented else { throw LensError.unavailable("Small history presentation did not complete.") }
        await store.waitForPresentation()
        let observation: [String: Any] = ["stage": "small-open", "journalBytes": fixture.expectedBytes,
            "openComplete": presented && !store.busy && store.openingProgress == nil && store.error == nil && store.snapshot?.root.id == fixture.rootID,
            "follow": store.follow, "snapshotEvents": store.snapshot?.events.count ?? 0,
            "presentationEvents": store.presentation?.filteredEvents.count ?? 0]
        store.stopObserving(); await store.investigation.flushAndStop()
        return observation
    }

    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else {
            throw LensError.unavailable("Missing " + name)
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return predicate()
    }
}

private final class LifecycleFixture {
    static let maximumBytes = 20_000_000
    let name: String, home: URL, rootID: String, journal: URL, eventCount: Int
    private(set) var expectedBytes = 0
    private var expectedHasher = SHA256()

    init(output: URL, name: String, rootID: String, eventCount: Int) throws {
        self.name = name; self.rootID = rootID; self.eventCount = eventCount
        home = output.appendingPathComponent(name + "-home")
        let sessions = home.appendingPathComponent("sessions/2026/10/08")
        journal = sessions.appendingPathComponent("rollout-2026-10-08T00-00-00-" + rootID + ".jsonl")
        guard eventCount > 0, !FileManager.default.fileExists(atPath: home.path) else {
            throw LensError.unavailable("Require a new dedicated lifecycle fixture home.")
        }
        let metadata = try Self.record(type: "session_meta", payload: ["id": rootID, "source": "cli"])
        let lifecycle = try Self.record(type: "event_msg", payload: ["type": "task_started"])
        guard metadata.count + (eventCount + 1) * lifecycle.count < Self.maximumBytes else {
            throw LensError.unavailable("Lifecycle fixture exceeds the bounded journal size.")
        }
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: journal.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: journal)
        defer { try? writer.close() }
        try writer.write(contentsOf: metadata); expectedHasher.update(data: metadata); expectedBytes += metadata.count
        var chunk = Data(); chunk.reserveCapacity(65_536 + lifecycle.count)
        for _ in 0..<eventCount {
            chunk.append(lifecycle)
            if chunk.count >= 65_536 {
                try writer.write(contentsOf: chunk); expectedHasher.update(data: chunk); expectedBytes += chunk.count
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            try writer.write(contentsOf: chunk); expectedHasher.update(data: chunk); expectedBytes += chunk.count
        }
    }

    func appendLifecycleEvent() throws -> (offset: UInt64, recordLength: Int) {
        let record = try Self.record(type: "event_msg", payload: ["type": "task_completed"])
        guard expectedBytes + record.count < Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let offset = UInt64(expectedBytes), writer = try FileHandle(forWritingTo: journal)
        defer { try? writer.close() }
        guard try writer.seekToEnd() == offset else { throw LensError.unavailable("Owned fixture changed before the append.") }
        try writer.write(contentsOf: record); expectedHasher.update(data: record); expectedBytes += record.count
        return (offset, record.count - 1)
    }

    func matchesExpectedBytes() throws -> Bool {
        let reader = try FileHandle(forReadingFrom: journal)
        defer { try? reader.close() }
        var actualHasher = SHA256(), actualBytes = 0
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            actualBytes += chunk.count
            guard actualBytes <= expectedBytes else { return false }
            actualHasher.update(data: chunk)
        }
        let expected = expectedHasher
        return actualBytes == expectedBytes && actualHasher.finalize() == expected.finalize()
    }

    private static func record(type: String, payload: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-08T00:00:00Z", "type": type, "payload": payload], options: [.sortedKeys])
        bytes.append(10)
        return bytes
    }
}
