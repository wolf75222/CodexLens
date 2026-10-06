import Foundation
import CryptoKit
import Darwin

/// Catalog hints only: no prompts, event bodies or complete session snapshots.
/// Every hit requires a fresh source stamp; database/title/ownership data is merged anew.
struct SessionCatalogHeader: Codable {
    var id: String, sessionID: String?, cwd: String, cliVersion: String?, name: String
    var branch: String?, gitRef: String?, parent: String?, relation: RelationKind, historyStart: Int?
    var source: SourceRef
    var estimatedBytes: Int {
        [id, sessionID ?? "", cwd, cliVersion ?? "", name, branch ?? "", gitRef ?? "", parent ?? "", source.path]
            .reduce(512) { $0 + $1.utf8.count * 2 }
    }
    func isValid(path: String) -> Bool {
        !id.isEmpty && source.path == path && source.offset == 0 && source.line == 1
            && source.length > 0 && source.length <= 16 * 1024 * 1024
            && source.sha256?.count == 64 && estimatedBytes <= 128 * 1024
    }
}

/// Nanosecond mtime + ctime catch same-size edits with a restored mtime; inode/device
/// catch replacement. Permissions and cloud flags prevent reuse of unreadable bytes.
struct SessionCatalogStamp: Codable, Equatable {
    let device: Int64, inode: UInt64, size: Int64, mode: UInt32, flags: UInt32
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    var modifiedAt: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1_000_000_000) }
    static func read(path: String) throws -> Self {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { throw LensError.unavailable("Journal local inaccessible : \(path)") }
        if value.st_mode & S_IFMT == S_IFLNK {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.withCString({ lstat($0, &value) }) == 0 else { throw LensError.unavailable("Journal local inaccessible : \(path)") }
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw LensError.unavailable("Journal local inaccessible : \(path)")
        }
        try LocalContentGuard.requireResident(path: path, flags: value.st_flags)
        return Self(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: value.st_size,
                    mode: UInt32(value.st_mode), flags: value.st_flags,
                    modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }
}

/// Actor-confined, bounded metadata cache. Persistent files are optional and private.
struct SessionCatalogCache {
    private struct Entry: Codable { var stamp: SessionCatalogStamp; var header: SessionCatalogHeader; var used: UInt64 }
    private struct Envelope: Codable { var version: Int; var home: String; var entries: [String: Entry] }
    private struct Container: Codable { var payload: Data; var checksum: Data }
    static let maximumBytes = 8 * 1024 * 1024
    private static let maximumEntries = 16_384
    private let home: String, directory: URL, file: URL
    private var entries: [String: Entry] = [:]
    private var loaded = false, dirty = false
    private var clock: UInt64 = 0
    private(set) var estimatedBytes = 0
    var count: Int { entries.count }

    init(home: URL, cacheDirectory: URL) {
        self.home = home.standardizedFileURL.path
        directory = cacheDirectory.appendingPathComponent("Catalog-v1", isDirectory: true)
        let key = SHA256.hash(data: Data(self.home.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(key + ".plist")
    }
    mutating func prepare(paths: Set<String>) {
        if !loaded {
            loaded = true
            if let stamp = try? SessionCatalogStamp.read(path: file.path), stamp.size <= Self.maximumBytes,
               let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes,
               let container = try? PropertyListDecoder().decode(Container.self, from: data),
               container.checksum == Data(SHA256.hash(data: container.payload)),
               let envelope = try? PropertyListDecoder().decode(Envelope.self, from: container.payload),
               envelope.version == 1, envelope.home == home, envelope.entries.count <= Self.maximumEntries {
                for (path, entry) in envelope.entries where paths.contains(path) && entry.header.isValid(path: path) {
                    guard estimatedBytes <= Self.maximumBytes - entry.header.estimatedBytes else { break }
                    entries[path] = entry; estimatedBytes += entry.header.estimatedBytes; clock = max(clock, entry.used)
                }
            }
        }
        for path in entries.keys where !paths.contains(path) { remove(path: path) }
    }
    mutating func header(path: String, stamp: SessionCatalogStamp) -> SessionCatalogHeader? {
        guard var entry = entries[path] else { return nil }
        guard entry.stamp == stamp else { remove(path: path); return nil }
        clock &+= 1; entry.used = clock; entries[path] = entry
        return entry.header
    }
    mutating func insert(_ header: SessionCatalogHeader, stamp: SessionCatalogStamp) {
        let path = header.source.path
        guard header.isValid(path: path) else { return }
        remove(path: path)
        if estimatedBytes > Self.maximumBytes - header.estimatedBytes || entries.count >= Self.maximumEntries {
            // Evict a batch rather than sort the entire cache for every new entry.
            let count = max(1, entries.count / 8)
            for path in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(count).map(\.key) { remove(path: path) }
        }
        guard estimatedBytes <= Self.maximumBytes - header.estimatedBytes else { return }
        clock &+= 1; entries[path] = Entry(stamp: stamp, header: header, used: clock)
        estimatedBytes += header.estimatedBytes; dirty = true
    }
    mutating func remove(path: String) {
        if let previous = entries.removeValue(forKey: path) { estimatedBytes -= previous.header.estimatedBytes; dirty = true }
    }
    mutating func persist() {
        guard dirty, !Task.isCancelled else { return }
        do {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let payload = try encoder.encode(Envelope(version: 1, home: home, entries: entries))
            let data = try encoder.encode(Container(payload: payload, checksum: Data(SHA256.hash(data: payload))))
            guard data.count <= Self.maximumBytes else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false
            // The namespace has an 8 MiB disk budget across all source homes.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "plist" }.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
            var bytes = 0
            for candidate in files {
                bytes += (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if bytes > Self.maximumBytes && candidate != file { try? FileManager.default.removeItem(at: candidate) }
            }
        } catch { /* An absent/corrupt/unwritable cache never prevents reading the sources. */ }
    }
}
