import Foundation
import CryptoKit

/// Presence and size of recorded bytes, never a claim that the capture is complete
/// or that those bytes entered a model request. Contents stay in the source journal.
public struct RecordedOutputObservation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case commandCapture, toolResult }
    public var kind: Kind
    public var fieldPath: String
    public var utf8Count: Int
    public var truncationMarkers: [String]
    public var isExplicitlyTruncated: Bool { !truncationMarkers.isEmpty }
    public init(kind: Kind, fieldPath: String, utf8Count: Int, truncationMarkers: [String] = []) {
        self.kind = kind; self.fieldPath = fieldPath; self.utf8Count = utf8Count; self.truncationMarkers = truncationMarkers
    }
}

public struct RecordedResourceVersionFact: Codable, Hashable, Sendable {
    public var path: String?
    public var identifier: String
    public var fieldPath: String
    public var sourceRef: SourceRef?
    public init(path: String? = nil, identifier: String, fieldPath: String, sourceRef: SourceRef? = nil) {
        self.path = path; self.identifier = identifier; self.fieldPath = fieldPath; self.sourceRef = sourceRef
    }
}

/// Facts extracted once from a recorded payload. The fingerprint compares exact
/// canonical arguments and the recorded environment, not the intention of a call.
public struct RecordedToolObservationFacts: Codable, Hashable, Sendable {
    public enum ExecutionEvidence: String, Codable, Sendable { case toolResult, completedItem, processIdentifier }
    public var toolName: String?
    public var callID: String?
    public var environmentID: String?
    public var callFingerprint: String?
    public var command: String?
    public var explicitTestCommand: String?
    public var commandUTF8Bytes: Int?
    public var commandIsPartial: Bool
    public var outputs: [RecordedOutputObservation]
    public var exitCode: Int?
    public var status: String?
    public var executionEvidence: [ExecutionEvidence]
    public var recordedStartTime: Date?
    public var recordedEndTime: Date?
    public var recordedReads: [RecordedResourceVersionFact]
    public init(toolName: String? = nil, callID: String? = nil, environmentID: String? = nil,
                callFingerprint: String? = nil, command: String? = nil, explicitTestCommand: String? = nil,
                commandUTF8Bytes: Int? = nil, commandIsPartial: Bool = false,
                outputs: [RecordedOutputObservation] = [], exitCode: Int? = nil, status: String? = nil,
                executionEvidence: [ExecutionEvidence] = [], recordedStartTime: Date? = nil,
                recordedEndTime: Date? = nil, recordedReads: [RecordedResourceVersionFact] = []) {
        self.toolName = toolName; self.callID = callID; self.environmentID = environmentID
        self.callFingerprint = callFingerprint; self.command = command; self.explicitTestCommand = explicitTestCommand
        self.commandUTF8Bytes = commandUTF8Bytes; self.commandIsPartial = commandIsPartial
        self.outputs = outputs; self.exitCode = exitCode; self.status = status; self.executionEvidence = executionEvidence
        self.recordedStartTime = recordedStartTime; self.recordedEndTime = recordedEndTime; self.recordedReads = recordedReads
    }

    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let payload = root["payload"] as? [String: Any] ?? root
        let item = payload["item"] as? [String: Any] ?? [:]
        let type = payload["type"] as? String ?? ""
        let subtype = item["type"] as? String ?? ""
        let isCall = ["function_call", "custom_tool_call"].contains(type)
        let isResult = ["function_call_output", "custom_tool_call_output"].contains(type)
        let isCommand = ["CommandExecution", "commandExecution", "command_execution"].contains(subtype)
        let isFileChange = ["FileChange", "fileChange", "file_change"].contains(subtype)
        guard isCall || isResult || isCommand || isFileChange else { return nil }
        let itemPath = root["payload"] == nil ? "item" : "payload.item"
        let payloadPath = root["payload"] == nil ? "" : "payload."
        let tool = event.toolName ?? (payload["name"] as? String) ?? (isCommand ? "exec_command" : isFileChange ? "apply_patch" : nil)
        let commandTool = tool.map { name in
            let leaf = name.components(separatedBy: ".").last?.components(separatedBy: "__").last ?? name
            return ["exec_command", "shell", "shell_command", "run_command", "run_terminal_cmd", "bash"].contains(leaf)
        } == true
        let call = nonempty(event.callID ?? payload["call_id"] as? String ?? item["call_id"] as? String ?? item["id"] as? String)
        let argumentsValue = payload["arguments"] ?? payload["input"]
        let arguments = object(argumentsValue)
        let environment = nonempty(event.environmentID ?? arguments["workdir"] as? String ?? arguments["cwd"] as? String ?? item["cwd"] as? String)
        let commandValue = arguments["cmd"] ?? arguments["command"] ?? item["command"]
        let command: String?
        if let words = commandValue as? [String] {
            // An argv capture is not a shell string. Recognize a literal -c body,
            // otherwise quote argv so arguments cannot become command segments.
            if words.count >= 3, ["sh", "bash", "zsh", "dash"].contains((words.first! as NSString).lastPathComponent),
               words.dropFirst().contains(where: { $0 == "-c" || $0 == "-lc" }) { command = words.last }
            else { command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
        } else { command = commandValue as? String }
        let fingerprint: String?
        if let tool, isCall, let argumentsValue { fingerprint = stableFingerprint(tool: tool, environment: environment, arguments: argumentsValue) }
        else if let tool, isCommand, let commandValue {
            fingerprint = stableFingerprint(tool: tool, environment: environment, arguments: ["command": commandValue])
        } else { fingerprint = nil }
        let resultObject = object(payload["output"])
        let metadata = isCommand || isFileChange ? item : isResult ? resultObject : payload
        var outputs: [RecordedOutputObservation] = []
        if isResult, let value = payload["output"] {
            outputs.append(output(value, kind: .toolResult, path: payloadPath + "output", metadata: payload))
        }
        for key in ["stdout", "stderr", "formatted_output", "aggregated_output"] {
            if let value = metadata[key] {
                let path = isCommand ? itemPath + "." + key : payloadPath + "output." + key
                outputs.append(output(value, kind: .commandCapture, path: path, metadata: metadata))
            }
        }
        if isCommand, let value = item["output"] {
            outputs.append(output(value, kind: .commandCapture, path: itemPath + ".output", metadata: item))
        }
        let textOutput = payload["output"] as? String
        let exitCode = integer(metadata["exit_code"] ?? metadata["exitCode"])
            ?? integer(payload["exit_code"] ?? payload["exitCode"])
            ?? textOutput.flatMap { textExitCode($0) }
        let status = metadata["status"] as? String ?? (isResult ? payload["status"] as? String : nil)
        var evidence: [ExecutionEvidence] = []
        if isResult { evidence.append(.toolResult) }
        if type == "item_completed" { evidence.append(.completedItem) }
        if nonempty(metadata["process_id"] as? String) != nil || integer(metadata["process_id"]).map({ $0 > 0 }) == true
            || nonempty(metadata["session_id"] as? String) != nil || integer(metadata["session_id"]).map({ $0 > 0 }) == true { evidence.append(.processIdentifier) }
        var reads: [RecordedResourceVersionFact] = []
        let isRead = tool.map { name in ["read_file", "read_text", "view_image", "read_resource"].contains(name.components(separatedBy: ".").last ?? name) } == true
        if isRead || isResult {
            let path = arguments["path"] as? String ?? arguments["file_path"] as? String
                ?? resultObject["path"] as? String ?? resultObject["file_path"] as? String
            let argumentField = payload["arguments"] == nil ? "input." : "arguments."
            for (container, prefix) in [(arguments, payloadPath + argumentField), (resultObject, payloadPath + "output.")] {
                for key in ["source_version_id", "source_version", "blob_id", "object_id", "source_sha256", "sha256"] {
                    if let id = container[key] as? String, !id.isEmpty {
                        reads.append(RecordedResourceVersionFact(path: path, identifier: id, fieldPath: prefix + key, sourceRef: event.source))
                    }
                }
            }
        }
        // Recognition and the hash use original recorded bytes. Only redacted,
        // bounded previews are retained in the passive cache.
        let originalTestCommand = isCommand || commandTool ? command.flatMap(testCommand) : nil
        let redactedCommand = command.map(EvidenceRedaction.redact)
        let redactedTestCommand = originalTestCommand.map(EvidenceRedaction.redact)
        let previewLimit = 12 * 1_024
        let isPartial = (command?.utf8.count ?? 0) > previewLimit || (redactedCommand?.utf8.count ?? 0) > previewLimit
            || (redactedTestCommand?.utf8.count ?? 0) > previewLimit
        return Self(toolName: tool, callID: call, environmentID: environment, callFingerprint: fingerprint,
                    command: redactedCommand.map { EvidenceRedaction.utf8Prefix($0, limit: previewLimit) },
                    explicitTestCommand: redactedTestCommand.map { EvidenceRedaction.utf8Prefix($0, limit: previewLimit) },
                    commandUTF8Bytes: command?.utf8.count, commandIsPartial: isPartial, outputs: outputs,
                    exitCode: exitCode, status: status, executionEvidence: evidence,
                    recordedStartTime: date(payload["started_at_ms"] ?? item["started_at_ms"], milliseconds: true)
                        ?? date(payload["started_at"] ?? item["started_at"], milliseconds: false),
                    recordedEndTime: date(payload["completed_at_ms"] ?? item["completed_at_ms"], milliseconds: true)
                        ?? date(payload["completed_at"] ?? item["completed_at"], milliseconds: false), recordedReads: reads)
    }

    private static func object(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        guard let string = value as? String, let data = string.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private static func stableFingerprint(tool: String, environment: String?, arguments: Any) -> String? {
        let parsed: Any
        if let string = arguments as? String, let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { parsed = json }
        else { parsed = arguments }
        let identity: [String: Any] = ["version": 1, "tool": tool, "environment": environment as Any? ?? NSNull(), "arguments": parsed]
        guard JSONSerialization.isValidJSONObject(identity),
              let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func output(_ value: Any, kind: RecordedOutputObservation.Kind, path: String, metadata: [String: Any]) -> RecordedOutputObservation {
        let text: String
        if let string = value as? String { text = string }
        else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) { text = String(decoding: data, as: UTF8.self) }
        else { text = "" }
        var markers: [String] = []
        for key in ["truncated", "is_truncated", "output_truncated"] where metadata[key] as? Bool == true { markers.append(key + "=true") }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("warning: truncated output") || trimmed.hasPrefix("output truncated")
                || trimmed.hasPrefix("[output truncated]") || trimmed == "[truncated]"
                || trimmed.hasPrefix("warning: output was truncated") || trimmed.hasPrefix("warning: output truncated")
                || trimmed.hasPrefix("output was truncated") || trimmed.hasPrefix("output text was truncated") {
                // Keep the fact of a marker, never a line of captured output.
                markers.append("text: explicit truncation marker")
            }
        }
        return RecordedOutputObservation(kind: kind, fieldPath: path, utf8Count: text.utf8.count, truncationMarkers: Array(Set(markers)).sorted())
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
    private static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    private static func textExitCode(_ text: String) -> Int? {
        let pattern = #"(?m)^(?:Process exited with code|Exit code:)\s+(-?\d+)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
    private static func date(_ value: Any?, milliseconds: Bool) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0, number.doubleValue.isFinite {
            return Date(timeIntervalSince1970: number.doubleValue / (milliseconds ? 1_000 : 1))
        }
        if !milliseconds, let string = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }
        return nil
    }
    /// A small literal shell tokenizer. It never evaluates a substitution, script,
    /// alias, variable or wrapper body, and unknown forms stay unclassified.
    private static func testCommand(_ command: String) -> String? {
        // A later segment may be conditional, and a compound command's exit code
        // may describe a different executable. Only one literal segment qualifies.
        let segments = shellSegments(command)
        guard segments.count == 1 else { return nil }
        for original in segments {
            var words = original
            while words.first?.contains("=") == true && words.first?.hasPrefix("-") == false { words.removeFirst() }
            if words.first == "env" {
                words.removeFirst()
                while let first = words.first {
                    if first == "-u", words.count > 1 { words.removeFirst(2) }
                    else if first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
                    else { break }
                }
            }
            if words.first == "rtk" { words.removeFirst(); if words.first == "proxy" { words.removeFirst() } }
            if words.first == "xcrun" { words.removeFirst() }
            guard let first = words.first else { continue }
            let executable = (first as NSString).lastPathComponent
            let args = Array(words.dropFirst())
            let dry = ["--list-tests", "--collect-only", "--show-only", "--list", "-N", "-list", "--dry-run"]
            if args.contains(where: { dry.contains($0) || $0.hasPrefix("--collect-only=") || $0.hasPrefix("--show-only=") }) { continue }
            let matched: Bool
            switch executable {
            case "swift": matched = args.first == "test" && args.dropFirst().first != "list"
            case "pytest", "pytest3", "ctest", "rspec": matched = true
            case "python", "python3": matched = args.count >= 2 && args[0] == "-m" && ["pytest", "unittest"].contains(args[1])
            case "xcodebuild": matched = args.contains("test") || args.contains("test-without-building")
            case "cargo", "go", "dotnet", "npm", "pnpm", "yarn", "mvn", "gradle", "gradlew": matched = args.first == "test"
            case "bundle": matched = args.count >= 2 && args[0] == "exec" && args[1] == "rspec"
            default: matched = false
            }
            if matched { return command }
        }
        return nil
    }
    private static func shellSegments(_ text: String) -> [[String]] {
        var result: [[String]] = [], words: [String] = [], token = "", quote: Character?, escaping = false, comment = false
        func flushToken() { if !token.isEmpty { words.append(token); token = "" } }
        func flushSegment() { flushToken(); if !words.isEmpty { result.append(words); words = [] } }
        for character in text {
            if comment { if character == "\n" { comment = false; flushSegment() }; continue }
            if escaping { token.append(character); escaping = false; continue }
            if character == "\\", quote != "'" { escaping = true; continue }
            if let current = quote { if character == current { quote = nil } else { token.append(character) }; continue }
            if character == "'" || character == "\"" { quote = character; continue }
            if character == "#", token.isEmpty { comment = true; continue }
            if character == ";" || character == "&" || character == "|" || character == "\n" { flushSegment() }
            else if character.isWhitespace { flushToken() }
            else { token.append(character) }
        }
        guard quote == nil, !escaping else { return [] }
        flushSegment(); return result
    }
}

public enum RecordedActivityOutcome: String, Codable, Sendable { case succeeded, failed, unknown, conflicting }
public struct RecordedActivityObservation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var agentID: String
    public var environmentID: String?
    public var toolName: String?
    public var callID: String?
    public var eventIDs: [String]
    public var callEventIDs: [String]
    public var resultEventIDs: [String]
    public var sourceRefs: [SourceRef]
    public var callFingerprint: String?
    public var command: String?
    public var explicitTestCommand: String?
    public var commandUTF8Bytes: Int?
    public var commandIsPartial: Bool
    public var outputs: [RecordedOutputObservation]
    public var exitCodes: [Int]
    public var statuses: [String]
    public var executionEvidence: [RecordedToolObservationFacts.ExecutionEvidence]
    public var outcome: RecordedActivityOutcome
    public var recordedStartTime: Date?
    public var recordedEndTime: Date?
    public var recordedReads: [RecordedResourceVersionFact]
    public var limitations: [String]
}
public struct RecordedTestObservation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { activity.id }
    public var activity: RecordedActivityObservation
    public var subsequentChangeIDs: [String]
    public var limitations: [String]
    public var outcome: RecordedActivityOutcome { activity.outcome }
}
public struct RecordedRepeatedCallGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: String { fingerprint }
    public var fingerprint: String
    public var observationIDs: [String]
    public var eventIDs: [String]
    public var limitations: [String]
}
public struct RecordedFileActivity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var eventIDs: [String]
    public var changeIDs: [String]
    public var kinds: [ChangeKind]
    public var agentID: String
    public var callID: String?
    public var timestamp: Date?
    public var recordedStartTime: Date?
    public var recordedEndTime: Date?
    public var sourceRefs: [SourceRef]
    public var isRequestOnly: Bool { kinds.allSatisfy { $0 == .requestedPatch } }
}
public struct RecordedResourceReadObservation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var resourceID: String
    public var eventIDs: [String]
    public var sourceRefs: [SourceRef]
    public var recordedVersions: [RecordedResourceVersionFact]
    public var limitations: [String]
}
public struct RecordedFileIntervalOverlap: Codable, Hashable, Sendable {
    public var firstActivityID: String
    public var secondActivityID: String
    public var startTime: Date
    public var endTime: Date
}
public struct RecordedFileHistory: Identifiable, Codable, Hashable, Sendable {
    public var id: String { environmentID + "\u{0}" + path }
    public var environmentID: String
    public var path: String
    public var activities: [RecordedFileActivity]
    public var reads: [RecordedResourceReadObservation]
    public var overlappingRecordedIntervals: [RecordedFileIntervalOverlap]
    public var limitations: [String]
}

/// A pure projection over indexed facts. No filesystem access, current Git state,
/// command execution, model invocation or time-proximity association occurs here.
public struct ActivityEvidenceIndex: Sendable {
    public let observationsByEventID: [String: RecordedActivityObservation]
    public let tests: [RecordedTestObservation]
    public let repeatedCallGroups: [RecordedRepeatedCallGroup]
    public let fileHistories: [RecordedFileHistory]
    public init(events: [LensEvent], changes: [ChangeRecord], resources: [ResourceRecord]) {
        let eventMap = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Only observations participate in this ordering. Preserve every event
        // in eventMap for linked changes; absence of facts is not a tool result.
        let entries = events.compactMap { event in event.trace?.toolObservation.map { (event, $0) } }
            .sorted { ($0.0.timestamp, $0.0.id) < ($1.0.timestamp, $1.0.id) }
        func recordedEnvironment(_ event: LensEvent, _ facts: RecordedToolObservationFacts? = nil) -> String? {
            (event.environmentID ?? facts?.environmentID).flatMap { $0.isEmpty ? nil : $0 }
        }
        func recordedCall(_ event: LensEvent, _ facts: RecordedToolObservationFacts? = nil) -> String? {
            (facts?.callID ?? event.callID).flatMap { $0.isEmpty ? nil : $0 }
        }
        var knownEnvironments: [String: Set<String>] = [:]
        for (event, facts) in entries {
            if let call = recordedCall(event, facts), let environment = recordedEnvironment(event, facts) {
                knownEnvironments[event.agentID + "\u{0}" + call, default: []].insert(environment)
            }
        }
        func identity(_ event: LensEvent, _ facts: RecordedToolObservationFacts? = nil) -> String {
            guard let call = recordedCall(event, facts) else { return "event:" + event.id }
            let scoped = event.agentID + "\u{0}" + call
            let known = knownEnvironments[scoped] ?? []
            let environment = recordedEnvironment(event, facts) ?? (known.count == 1 ? known.first : nil)
            return "call:" + scoped + "\u{0}" + (environment ?? "<unknown>")
        }
        var groups: [String: [(LensEvent, RecordedToolObservationFacts)]] = [:]
        for (event, facts) in entries { groups[identity(event, facts), default: []].append((event, facts)) }
        var observations: [RecordedActivityObservation] = [], byEvent: [String: RecordedActivityObservation] = [:]
        for id in groups.keys.sorted() {
            let members = groups[id]!
            let first = members[0].0
            let facts = members.map(\.1)
            let exitCodes = unique(facts.compactMap(\.exitCode)).sorted()
            let statuses = unique(facts.compactMap(\.status)).sorted()
            let positive = exitCodes.contains(0) || statuses.contains { ["succeeded", "success", "passed"].contains($0.lowercased()) }
            let negative = exitCodes.contains { $0 != 0 } || statuses.contains { ["failed", "error", "declined", "cancelled", "canceled", "rejected"].contains($0.lowercased()) }
            let outcome: RecordedActivityOutcome = positive && negative ? .conflicting : negative ? .failed : positive ? .succeeded : .unknown
            let invocationFingerprints = facts.filter { !$0.executionEvidence.contains(.completedItem) }.compactMap(\.callFingerprint)
            let fingerprints = unique(invocationFingerprints.isEmpty ? facts.compactMap(\.callFingerprint) : invocationFingerprints)
            let invocationCommands = facts.filter { !$0.executionEvidence.contains(.completedItem) }.compactMap(\.command)
            let invocationTests = facts.filter { !$0.executionEvidence.contains(.completedItem) }.compactMap(\.explicitTestCommand)
            let commands = unique(invocationCommands.isEmpty ? facts.compactMap(\.command) : invocationCommands)
            let testCommands = unique(invocationTests.isEmpty ? facts.compactMap(\.explicitTestCommand) : invocationTests)
            let starts = unique(facts.compactMap(\.recordedStartTime))
            let ends = unique(facts.compactMap(\.recordedEndTime))
            // A completion journal timestamp alone is never an operation start.
            let suppliedIntervals = members.compactMap { event, _ -> (Date, Date)? in
                guard let end = event.endTime, event.timestamp != .distantPast, end > event.timestamp else { return nil }
                return (event.timestamp, end)
            }
            var start = starts.count == 1 ? starts.first : suppliedIntervals.count == 1 ? suppliedIntervals.first?.0 : nil
            var end = ends.count == 1 ? ends.first : suppliedIntervals.count == 1 ? suppliedIntervals.first?.1 : nil
            var limits = ["Recorded output presence does not establish completeness or inclusion in a model request.",
                          "An identical call fingerprint does not establish a retry, a defect or a cause."]
            if fingerprints.count > 1 { limits.append("Linked records contain different argument fingerprints; no single fingerprint is assigned.") }
            if starts.count > 1 || ends.count > 1 || (start != nil && end != nil && end! <= start!) {
                start = nil; end = nil; limits.append("Recorded interval boundaries conflict; overlap is unavailable.")
            }
            if outcome == .unknown { limits.append("No explicit recorded exit code or recognized outcome status establishes success.") }
            if facts.contains(where: \.commandIsPartial) {
                limits.append("Recorded command previews are redacted and partial under the 12 KiB UTF-8 limit; original command bytes remain in the source journal.")
            }
            if statuses.contains(where: { $0.lowercased() == "completed" }) && exitCodes.isEmpty {
                limits.append("A completed status establishes completion, not a passing test outcome.")
            }
            let observation = RecordedActivityObservation(id: id, agentID: first.agentID,
                environmentID: members.compactMap { recordedEnvironment($0.0, $0.1) }.first,
                toolName: facts.compactMap(\.toolName).first, callID: facts.compactMap(\.callID).first ?? first.callID,
                eventIDs: members.map { $0.0.id }, callEventIDs: members.filter { $0.0.kind == .toolCall }.map { $0.0.id },
                resultEventIDs: members.filter { $0.0.kind == .toolResult || !$0.1.executionEvidence.isEmpty }.map { $0.0.id },
                sourceRefs: unique(members.flatMap { [$0.0.source] + $0.0.supplementarySources }),
                callFingerprint: fingerprints.count == 1 ? fingerprints.first : nil, command: commands.count == 1 ? commands.first : nil,
                explicitTestCommand: fingerprints.count <= 1 && testCommands.count == 1 ? testCommands.first : nil,
                commandUTF8Bytes: commands.count == 1 ? facts.compactMap(\.commandUTF8Bytes).max() : nil,
                commandIsPartial: facts.contains(where: \.commandIsPartial), outputs: unique(facts.flatMap(\.outputs)),
                exitCodes: exitCodes, statuses: statuses, executionEvidence: unique(facts.flatMap(\.executionEvidence)),
                outcome: outcome, recordedStartTime: start, recordedEndTime: end, recordedReads: unique(facts.flatMap(\.recordedReads)), limitations: limits)
            observations.append(observation)
            for eventID in observation.eventIDs { byEvent[eventID] = observation }
        }
        self.observationsByEventID = byEvent
        self.tests = observations.filter { $0.explicitTestCommand != nil && !$0.executionEvidence.isEmpty }.map { activity in
            let completion = activity.recordedEndTime ?? activity.resultEventIDs.compactMap { eventMap[$0]?.timestamp }.filter { $0 != .distantPast }.max()
            let later = changes.filter { change in
                guard change.kind != .requestedPatch, let environment = activity.environmentID, change.environmentID == environment,
                      let completion, let event = eventMap[change.eventID], event.timestamp > completion,
                      !activity.eventIDs.contains(change.eventID) else { return false }
                return true
            }.sorted { $0.id < $1.id }.map(\.id)
            return RecordedTestObservation(activity: activity, subsequentChangeIDs: later,
                limitations: ["This records a literal test command and linked execution/result evidence, not individual test coverage.",
                              "A later recorded change in the same environment does not establish test invalidation, causality or coverage."])
        }.sorted { $0.id < $1.id }
        var repeated: [String: [RecordedActivityObservation]] = [:]
        for activity in observations where activity.environmentID != nil {
            if let fingerprint = activity.callFingerprint { repeated[fingerprint, default: []].append(activity) }
        }
        self.repeatedCallGroups = repeated.keys.sorted().compactMap { fingerprint in
            let values = repeated[fingerprint]!
            guard values.count > 1 else { return nil }
            return RecordedRepeatedCallGroup(fingerprint: fingerprint, observationIDs: values.map(\.id), eventIDs: values.flatMap(\.eventIDs),
                limitations: ["The same tool, canonical arguments and recorded environment were observed more than once; no reason for repetition is inferred."])
        }
        var histories: [String: RecordedFileHistory] = [:]
        func historyKey(_ environment: String, _ path: String) -> String { environment + "\u{0}" + path }
        func emptyHistory(_ environment: String, _ path: String) -> RecordedFileHistory {
            RecordedFileHistory(environmentID: environment, path: path, activities: [], reads: [], overlappingRecordedIntervals: [],
                limitations: ["Requested patches and their linked results describe one activity, not two edits.",
                              "Overlap means overlapping recorded intervals for this environment and path; no conflict or lost update is inferred.",
                              "Historical reads use only recorded version identifiers; no current file is consulted."])
        }
        for change in changes.sorted(by: { $0.id < $1.id }) {
            let key = historyKey(change.environmentID, change.path)
            var history = histories[key] ?? emptyHistory(change.environmentID, change.path)
            let event = eventMap[change.eventID]
            let activity = byEvent[change.eventID]
            let operationID = activity?.id ?? event.map { identity($0) } ?? "change:" + change.id
            if let position = history.activities.firstIndex(where: { $0.id == operationID }) {
                history.activities[position].changeIDs.append(change.id)
                history.activities[position].kinds = unique(history.activities[position].kinds + [change.kind])
                history.activities[position].eventIDs = unique(history.activities[position].eventIDs + [change.eventID])
                if let event { history.activities[position].sourceRefs = unique(history.activities[position].sourceRefs + [event.source] + event.supplementarySources) }
            } else {
                history.activities.append(RecordedFileActivity(id: operationID, eventIDs: activity?.eventIDs ?? [change.eventID],
                    changeIDs: [change.id], kinds: [change.kind], agentID: change.agentID, callID: activity?.callID ?? event?.callID,
                    timestamp: event.flatMap { $0.timestamp == .distantPast ? nil : $0.timestamp },
                    recordedStartTime: activity?.recordedStartTime, recordedEndTime: activity?.recordedEndTime,
                    sourceRefs: activity?.sourceRefs ?? event.map { [$0.source] + $0.supplementarySources } ?? []))
            }
            histories[key] = history
        }
        for resource in resources where resource.roles.contains(.recordedRead) {
            guard let environment = resource.environmentID else { continue }
            let key = historyKey(environment, resource.location)
            var history = histories[key] ?? emptyHistory(environment, resource.location)
            let related = unique(resource.eventIDs.compactMap { byEvent[$0] }).filter { $0.environmentID == environment }
            let versions = unique(related.flatMap(\.recordedReads)).filter { fact in
                guard let path = fact.path else { return false }
                return path == resource.location || (environment as NSString).appendingPathComponent(path) == resource.location
            }
            let sources = unique(resource.eventIDs.compactMap { eventMap[$0] }.flatMap { [$0.source] + $0.supplementarySources })
            history.reads.append(RecordedResourceReadObservation(id: resource.id, resourceID: resource.id,
                eventIDs: resource.eventIDs, sourceRefs: sources, recordedVersions: versions,
                limitations: versions.isEmpty ? ["The read is recorded, but its complete historical source version is not identified."]
                    : ["A recorded version identifier is a reference; its bytes are not verified by this projection."]))
            histories[key] = history
        }
        self.fileHistories = histories.keys.sorted().map { key in
            var history = histories[key]!
            history.activities.sort { ($0.timestamp ?? .distantPast, $0.id) < ($1.timestamp ?? .distantPast, $1.id) }
            let intervals = history.activities.filter {
                guard let start = $0.recordedStartTime, let end = $0.recordedEndTime else { return false }
                return start < end
            }.sorted { ($0.recordedStartTime!, $0.id) < ($1.recordedStartTime!, $1.id) }
            var active: [RecordedFileActivity] = []
            for right in intervals {
                active.removeAll { $0.recordedEndTime! <= right.recordedStartTime! }
                for left in active {
                    history.overlappingRecordedIntervals.append(RecordedFileIntervalOverlap(firstActivityID: left.id,
                        secondActivityID: right.id, startTime: right.recordedStartTime!, endTime: min(left.recordedEndTime!, right.recordedEndTime!)))
                }
                active.append(right)
            }
            return history
        }
    }
}

private func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen = Set<Value>(); return values.filter { seen.insert($0).inserted }
}
