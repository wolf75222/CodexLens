import Foundation
import CryptoKit

public struct RecordedPage: Sendable {
    public var text: String
    public var token: String?
    public var bytesRead: UInt64
    public var totalSourceBytes: UInt64
    public var hasSelectedField: Bool
    public init(text: String, token: String?, bytesRead: UInt64, totalSourceBytes: UInt64, hasSelectedField: Bool = false) {
        self.text = text; self.token = token; self.bytesRead = bytesRead; self.totalSourceBytes = totalSourceBytes
        self.hasSelectedField = hasSelectedField
    }
}

/// Pull reader for recorded events. It never executes a tool or reads a current workspace file.
/// At most eight cursors are retained; evicted cursors report expiry instead of silently restarting.
/// Continuity checks use file identity and 128-byte event boundaries. When `SourceRef.sha256`
/// is recorded by the collector, the full incremental digest is verified before successful EOF.
/// Earlier pages are provisional until then. Without that digest, a concurrent interior rewrite
/// combined with append is not fully authenticated by the boundary checks.
/// `bytesRead` measures cumulative physical I/O, including integrity checks, and may exceed
/// `totalSourceBytes`. An empty page with a continuation represents scanning an unselected field.
public actor RecordedPager {
    private var readers: [String: PageReader] = [:]
    private var order: [String] = []
    public init() {}

    /// Disable presentation labels only for copying one explicit source; lexical validation,
    /// UTF-8 decoding and secret masking remain identical. Missing fields then yield empty text.
    public func begin(event: LensEvent, relatedEvent: LensEvent? = nil, part: String = "output", limit: Int = 65536, decorateSources: Bool = true) async throws -> RecordedPage {
        let normalized = part.lowercased()
        guard ["output", "raw", "input", "arguments", "content"].contains(normalized) else {
            throw LensError.unsupported("Partie enregistrée non prise en charge : \(part).")
        }
        var sources = [event.source] + event.supplementarySources
        if let relatedEvent { sources += [relatedEvent.source] + relatedEvent.supplementarySources }
        var seen = Set<SourceRef>()
        sources = sources.filter { seen.insert($0).inserted }
        let token = UUID().uuidString
        let reader = try PageReader(sources: sources, part: normalized, decorateSources: decorateSources)
        while order.count >= 8 { let old = order.removeFirst(); readers.removeValue(forKey: old) }
        readers[token] = reader; order.append(token)
        do { return try page(reader, token: token, limit: limit) }
        catch { readers.removeValue(forKey: token); order.removeAll { $0 == token }; throw error }
    }

    public func next(token: String, limit: Int = 65536) async throws -> RecordedPage {
        guard let reader = readers[token] else { throw LensError.unavailable("Lecture expirée. Ouvrez à nouveau l’événement enregistré.") }
        do {
            try reader.validate()
            order.removeAll { $0 == token }; order.append(token)
            return try page(reader, token: token, limit: limit)
        } catch { readers.removeValue(forKey: token); order.removeAll { $0 == token }; throw error }
    }

    private func page(_ reader: PageReader, token: String, limit: Int) throws -> RecordedPage {
        let text = try reader.page(limit: max(4, min(limit, 65536)))
        let continuation = reader.finished ? nil : token
        if continuation == nil { readers.removeValue(forKey: token); order.removeAll { $0 == token } }
        return RecordedPage(text: text, token: continuation, bytesRead: reader.bytesRead, totalSourceBytes: reader.total, hasSelectedField: reader.hasSelectedField)
    }
}

private final class RecordBytes {
    let source: SourceRef
    private let handle: FileHandle
    private var identity: FileIdentity
    private let fingerprint: Data
    private let tailFingerprint: Data
    private let tailOffset: UInt64
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var loaded: UInt64 = 0
    private var hasher = SHA256()
    private var digestVerified = false
    private(set) var bytesRead: UInt64 = 0
    private var peeked: UInt8?
    init(source: SourceRef) throws {
        guard source.length > 0 else { throw LensError.unavailable("Plage source absente : \(source.path).") }
        self.source = source
        identity = try FileIdentity(path: source.path)
        guard source.offset <= identity.size, UInt64(source.length) <= identity.size - source.offset else {
            throw LensError.corrupt("Événement incomplet : \(source.path):\(source.line).")
        }
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
        try handle.seek(toOffset: source.offset)
        fingerprint = try handle.read(upToCount: min(128, source.length)) ?? Data()
        bytesRead += UInt64(fingerprint.count)
        tailOffset = source.offset + UInt64(source.length - min(128, source.length))
        try handle.seek(toOffset: tailOffset)
        tailFingerprint = try handle.read(upToCount: min(128, source.length)) ?? Data()
        bytesRead += UInt64(tailFingerprint.count)
        try handle.seek(toOffset: source.offset)
    }
    deinit { try? handle.close() }
    func validate() throws {
        let fresh: FileIdentity
        do { fresh = try FileIdentity(path: source.path) }
        catch { throw LensError.unavailable("Source disparue : \(source.path).") }
        // Live JSONL files may grow while an already recorded event is inspected.
        // Same-size rewrites, truncations, file replacement and changed event boundaries fail.
        guard fresh.inode == identity.inode, fresh.creation == identity.creation,
              fresh.size >= identity.size,
              fresh.size > identity.size || fresh.modification == identity.modification else {
            throw LensError.unavailable("Source modifiée pendant la lecture : \(source.path). Actualisez l’événement.")
        }
        let verification = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
        defer { try? verification.close() }
        try verification.seek(toOffset: source.offset)
        let prefix = try verification.read(upToCount: fingerprint.count) ?? Data()
        bytesRead += UInt64(prefix.count)
        guard prefix == fingerprint else { throw LensError.unavailable("Empreinte source modifiée : \(source.path).") }
        try verification.seek(toOffset: tailOffset)
        let tail = try verification.read(upToCount: tailFingerprint.count) ?? Data()
        bytesRead += UInt64(tail.count)
        guard tail == tailFingerprint else { throw LensError.unavailable("Fin de l’événement source modifiée : \(source.path).") }
        identity = fresh
    }
    func peek() throws -> UInt8? {
        if let peeked { return peeked }
        peeked = try readByte(); return peeked
    }
    func take() throws -> UInt8? {
        if let value = peeked { peeked = nil; return value }
        return try readByte()
    }
    private func readByte() throws -> UInt8? {
        if cursor == buffer.count {
            guard loaded < UInt64(source.length) else {
                if !digestVerified, let expected = source.sha256 {
                    let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard actual == expected.lowercased() else {
                        throw LensError.corrupt("L’empreinte de l’événement diffère de celle enregistrée : \(source.path):\(source.line). Le contenu affiché ne peut plus être vérifié contre cette empreinte. Consultez le journal actuel ; l’intégrité de cette version passée n’est pas confirmée.")
                    }
                }
                digestVerified = true
                return nil
            }
            let count = min(4096, source.length - Int(loaded))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw LensError.corrupt("Événement partiel pendant la lecture : \(source.path).") }
            if source.sha256 != nil { hasher.update(data: data) }
            buffer = Array(data); cursor = 0; loaded += UInt64(data.count); bytesRead += UInt64(data.count)
        }
        let byte = buffer[cursor]; cursor += 1; return byte
    }
}

private struct FileIdentity: Equatable {
    var size: UInt64
    var inode: UInt64
    var modification: Date
    var creation: Date
    init(path: String) throws {
        try LocalContentGuard.requireResident(path: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        modification = attrs[.modificationDate] as? Date ?? .distantPast
        creation = attrs[.creationDate] as? Date ?? .distantPast
    }
}

private final class PageReader {
    let total: UInt64
    private let sources: [SourceRef]
    private let part: String
    private let decorateSources: Bool
    private var sourceIndex = 0
    private var source: RecordBytes?
    private var lexer: JSONPull?
    private var accumulatedRead: UInt64 = 0
    private var pending = Data()
    private var filter = SecretStream()
    private(set) var finished = false
    private(set) var hasSelectedField = false
    var bytesRead: UInt64 { accumulatedRead + (source?.bytesRead ?? 0) }
    init(sources: [SourceRef], part: String, decorateSources: Bool) throws {
        self.sources = sources; self.part = part; self.decorateSources = decorateSources
        total = sources.reduce(0) { $0 + UInt64(max(0, $1.length)) }
        if sources.isEmpty { throw LensError.unavailable("Aucune source enregistrée.") }
    }
    func validate() throws { try source?.validate() }
    func page(limit: Int) throws -> String {
        let initialRead = bytesRead
        let readBudget = UInt64(max(8192, limit + 8192))
        while pending.count < limit + 4 && !finished {
            // A field may occur after a very large irrelevant value. Return a continuation
            // rather than blocking on the remainder of the event to fill the display page.
            if bytesRead - initialRead >= readBudget { break }
            if source == nil {
                guard sourceIndex < sources.count else { pending.append(filter.finish()); finished = true; break }
                let ref = sources[sourceIndex]
                source = try RecordBytes(source: ref)
                lexer = JSONPull(bytes: source!, part: part)
                let label = "\(sourceIndex == 0 ? "" : "\n\n")[Source \(sourceIndex + 1) : \(ref.path):\(ref.line), octets \(ref.offset)…\(ref.offset + UInt64(ref.length))]\n"
                if decorateSources { pending.append(filter.feed(Data(label.utf8))) }
            }
            if let unit = try lexer!.step() { pending.append(filter.feed(unit)) }
            hasSelectedField = hasSelectedField || lexer!.matched || part == "raw"
            if lexer!.done {
                if decorateSources && !lexer!.matched && part != "raw" { pending.append(filter.feed(Data("[Couverture : aucun champ \(part) pris en charge dans cet événement.]".utf8))) }
                accumulatedRead += source!.bytesRead
                source = nil; lexer = nil; sourceIndex += 1
            }
            guard pending.count <= 131072 else { throw LensError.corrupt("Tampon de lecture dépassé.") }
        }
        var amount = min(limit, pending.count)
        // Preserve complete UTF-8 scalars at page boundaries. No replacement characters are introduced.
        while amount > 0 && amount < pending.count && (pending[pending.startIndex + amount] & 0xC0) == 0x80 { amount -= 1 }
        if String(data: pending.prefix(amount), encoding: .utf8) == nil {
            // A read-budget boundary can interrupt a raw UTF-8 scalar before its last byte.
            var repairs = 0
            while amount > 0 && repairs < 3 && String(data: pending.prefix(amount), encoding: .utf8) == nil { amount -= 1; repairs += 1 }
        }
        let prefix = pending.prefix(amount)
        guard let result = String(data: prefix, encoding: .utf8) else { throw LensError.corrupt("UTF-8 invalide dans la trace enregistrée.") }
        pending.removeFirst(amount)
        if finished && !pending.isEmpty { finished = false } // The next call drains the final buffered page.
        return result
    }
}

/// A validating, byte-at-a-time JSON traversal. String values are decoded incrementally;
/// containers selected as output retain their recorded JSON structure.
private final class JSONPull {
    private struct Frame {
        var object: Bool
        var phase: Int = 0 // object: key/colon/value/comma; array: value/comma
        var key = ""
        var path: [String]
        var capture: Bool
        var suppressed: Bool
        var count = 0
    }
    private struct StringState {
        var key: Bool
        var capture: Bool
        var suppressed: Bool
        var value = Data()
        var utf8 = Data()
    }
    private let bytes: RecordBytes
    private let part: String
    private var frames: [Frame] = []
    private var string: StringState?
    private var primitive: [UInt8]?
    private var primitiveCapture = false
    private var rootComplete = false
    private(set) var done = false
    private(set) var matched = false
    init(bytes: RecordBytes, part: String) { self.bytes = bytes; self.part = part }

    func step() throws -> Data? {
        if done { return nil }
        if string != nil { return try stringStep() }
        if primitive != nil { return try primitiveStep() }
        guard let b = try bytes.peek() else {
            guard frames.isEmpty && rootComplete else { throw malformed("événement JSON incomplet") }
            done = true; return nil
        }
        if [9, 10, 13, 32].contains(b) { _ = try bytes.take(); return emitted([b], capture: currentCapture, suppressed: currentSuppressed) }
        if rootComplete { throw malformed("données après l’événement JSON") }
        if var frame = frames.last {
            if frame.object {
                switch frame.phase {
                case 0:
                    if b == 125 { guard frame.count == 0 else { throw malformed("virgule finale") }; return try close(b) }
                    guard b == 34 else { throw malformed("clé attendue") }
                    _ = try bytes.take(); string = StringState(key: true, capture: frame.capture, suppressed: frame.suppressed)
                    return emitted([b], capture: frame.capture, suppressed: frame.suppressed)
                case 1:
                    guard b == 58 else { throw malformed("deux-points attendu") }; _ = try bytes.take()
                    frame.phase = 2; frames[frames.count - 1] = frame
                    return emitted([b], capture: frame.capture, suppressed: frame.suppressed)
                case 3:
                    if b == 125 { return try close(b) }
                    guard b == 44 else { throw malformed("virgule attendue") }; _ = try bytes.take()
                    frame.phase = 0; frame.count += 1; frames[frames.count - 1] = frame
                    return emitted([b], capture: frame.capture, suppressed: frame.suppressed)
                default: break
                }
            } else {
                if frame.phase == 1 {
                    if b == 93 { return try close(b) }
                    guard b == 44 else { throw malformed("virgule attendue") }; _ = try bytes.take()
                    frame.phase = 0; frame.count += 1; frames[frames.count - 1] = frame
                    return emitted([b], capture: frame.capture, suppressed: frame.suppressed)
                }
                if b == 93 { guard frame.count == 0 else { throw malformed("virgule finale") }; return try close(b) }
            }
        }
        let path = nextPath
        let selected = isSelected(path) && (part != "content" || b == 34)
        let capture = currentCapture || selected
        let sensitive = isSensitive(path.last ?? "")
        let suppressed = currentSuppressed || sensitive
        var prefix = Data()
        if selected && part != "raw" && !currentCapture { prefix.append(Data("\(matched ? "\n" : "")".utf8)) }
        if selected { matched = true }
        if sensitive && capture && !currentSuppressed { prefix.append(Data("\"[REDACTED]\"".utf8)) }
        _ = try bytes.take()
        switch b {
        case 123, 91:
            guard frames.count < 128 else { throw malformed("JSON trop profond") }
            frames.append(Frame(object: b == 123, path: path, capture: capture, suppressed: suppressed))
            prefix.append(emitted([b], capture: capture, suppressed: suppressed) ?? Data()); return prefix
        case 34:
            string = StringState(key: false, capture: capture, suppressed: suppressed)
            if part == "raw" || currentCapture { prefix.append(emitted([b], capture: capture, suppressed: suppressed) ?? Data()) }
            return prefix
        default:
            guard b == 45 || (48...57).contains(b) || [116, 102, 110].contains(b) else { throw malformed("valeur JSON invalide") }
            primitive = [b]; primitiveCapture = capture && !suppressed
            prefix.append(emitted([b], capture: capture, suppressed: suppressed) ?? Data()); return prefix
        }
    }

    private var currentCapture: Bool { part == "raw" || (frames.last?.capture ?? false) }
    private var currentSuppressed: Bool { frames.last?.suppressed ?? false }
    private var nextPath: [String] {
        guard let frame = frames.last else { return [] }
        return frame.path + [frame.object ? frame.key : "[]"]
    }
    private func isSelected(_ path: [String]) -> Bool {
        guard part != "raw", path.contains("payload") || path.contains("params"), let key = path.last else { return false }
        switch part {
        case "output": return ["output", "formatted_output", "aggregated_output", "result"].contains(key) || (key == "changes" && path.contains("item"))
        case "input", "arguments": return ["arguments", "input", "command"].contains(key)
        case "content": return key == "text" || key == "message" || (["summary", "summary_text", "raw_content"].contains(key) || (key == "[]" && path.contains(where: { ["summary", "summary_text", "raw_content"].contains($0) }))) || (key == "content" && !path.contains("output")) || key == "base_instructions"
        default: return false
        }
    }
    private func isSensitive(_ key: String) -> Bool {
        ["authorization", "api_key", "apikey", "access_token", "refresh_token", "id_token", "token", "password", "secret", "client_secret", "cookie", "set-cookie"].contains(key.lowercased())
    }
    private func emitted(_ bytes: [UInt8], capture: Bool, suppressed: Bool) -> Data? { capture && !suppressed ? Data(bytes) : nil }
    private func completeValue() {
        if frames.isEmpty { rootComplete = true }
        else { frames[frames.count - 1].phase = frames.last!.object ? 3 : 1 }
    }
    private func close(_ b: UInt8) throws -> Data? {
        _ = try bytes.take()
        let frame = frames.removeLast()
        guard (frame.object && b == 125) || (!frame.object && b == 93) else { throw malformed("conteneur JSON invalide") }
        completeValue(); return emitted([b], capture: frame.capture || part == "raw", suppressed: frame.suppressed)
    }
    private func primitiveStep() throws -> Data? {
        if let b = try bytes.peek(), ![9,10,13,32,44,93,125].contains(b) {
            guard primitive!.count < 512 else { throw malformed("scalaire JSON trop long") }
            _ = try bytes.take(); primitive!.append(b)
            return primitiveCapture ? Data([b]) : nil
        }
        let value = String(bytes: primitive!, encoding: .utf8) ?? ""
        guard ["true", "false", "null"].contains(value) || value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw malformed("scalaire JSON invalide") }
        primitive = nil; completeValue(); return nil
    }
    private func stringStep() throws -> Data? {
        var state = string!
        guard let b = try bytes.take() else { throw malformed("chaîne JSON incomplète") }
        let raw = part == "raw" || (frames.last?.capture ?? false)
        var original = Data([b]), decoded = Data()
        if b == 34 {
            guard state.utf8.isEmpty else { throw malformed("UTF-8 partiel") }
            string = nil
            if state.key {
                guard let key = String(data: state.value, encoding: .utf8) else { throw malformed("clé UTF-8 invalide") }
                frames[frames.count - 1].key = key; frames[frames.count - 1].phase = 1
            } else { completeValue() }
            return raw ? emitted([b], capture: state.capture, suppressed: state.suppressed) : nil
        }
        guard b >= 32 else { throw malformed("caractère de contrôle JSON") }
        if b == 92 {
            guard state.utf8.isEmpty else { throw malformed("UTF-8 invalide avant échappement") }
            guard let escape = try bytes.take() else { throw malformed("échappement partiel") }
            original.append(escape)
            switch escape {
            case 34, 47, 92: decoded.append(escape)
            case 98: decoded.append(8)
            case 102: decoded.append(12)
            case 110: decoded.append(10)
            case 114: decoded.append(13)
            case 116: decoded.append(9)
            case 117:
                var code = try hex4(into: &original)
                if (0xD800...0xDBFF).contains(code) {
                    guard try bytes.take() == 92, try bytes.take() == 117 else { throw malformed("paire Unicode incomplète") }
                    original.append(contentsOf: [92,117])
                    let low = try hex4(into: &original)
                    guard (0xDC00...0xDFFF).contains(low) else { throw malformed("surrogate Unicode invalide") }
                    code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                }
                guard let scalar = UnicodeScalar(code), !(0xDC00...0xDFFF).contains(code) else { throw malformed("Unicode invalide") }
                decoded.append(Data(String(scalar).utf8))
            default: throw malformed("échappement JSON invalide")
            }
        } else if b >= 128 || !state.utf8.isEmpty {
            state.utf8.append(b)
            let first = state.utf8.first!
            let expected = first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
            guard first >= 0xC2 && first <= 0xF4, state.utf8.count <= expected else { throw malformed("UTF-8 invalide") }
            if state.utf8.count == expected {
                guard String(data: state.utf8, encoding: .utf8) != nil else { throw malformed("UTF-8 invalide") }
                decoded = state.utf8; state.utf8.removeAll(keepingCapacity: true)
            }
        } else { decoded.append(b) }
        if state.key {
            state.value.append(decoded)
            guard state.value.count <= 512 else { throw malformed("clé JSON trop longue") }
        }
        string = state
        guard state.capture && !state.suppressed else { return nil }
        return raw ? original : decoded
    }
    private func hex4(into original: inout Data) throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let b = try bytes.take() else { throw malformed("Unicode échappé incomplet") }
            original.append(b)
            let digit: UInt32
            switch b { case 48...57: digit = UInt32(b - 48); case 65...70: digit = UInt32(b - 55); case 97...102: digit = UInt32(b - 87); default: throw malformed("Unicode échappé invalide") }
            value = value * 16 + digit
        }
        return value
    }
    private func malformed(_ reason: String) -> LensError { .corrupt("\(reason) : \(bytes.source.path):\(bytes.source.line).") }
}

/// Constant-space token redaction, including prefixes split across file and page boundaries.
private struct SecretStream {
    private var pending: [UInt8] = []
    private var dropping = false
    mutating func feed(_ data: Data) -> Data {
        var output = Data()
        for b in data { pending.append(b); drain(into: &output, final: false) }
        return output
    }
    mutating func finish() -> Data { var output = Data(); drain(into: &output, final: true); return output }
    private mutating func drain(into output: inout Data, final: Bool) {
        let bearer = Array("bearer ".utf8), key = Array("sk-".utf8)
        while !pending.isEmpty {
            if dropping {
                let b = pending[0]
                if (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45,95,46,43,47,61].contains(b) { pending.removeFirst(); continue }
                dropping = false
            }
            let lower = pending.map { (65...90).contains($0) ? $0 + 32 : $0 }
            if lower.starts(with: bearer) { output.append(Data("Bearer [REDACTED]".utf8)); pending.removeFirst(bearer.count); dropping = true; continue }
            if pending.starts(with: key) { output.append(Data("[REDACTED]".utf8)); pending.removeFirst(key.count); dropping = true; continue }
            if !final && (bearer.starts(with: lower) || key.starts(with: pending)) { return }
            output.append(pending.removeFirst())
        }
    }
}
