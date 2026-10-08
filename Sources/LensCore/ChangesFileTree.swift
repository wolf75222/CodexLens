import Foundation

/// Navigation prepared solely from the retained changed-file projection. It never reads files or Git.
public struct ChangesFileTree: Hashable, Sendable {
    public let roots: [ChangesFileTreeNode]
    public let nodesByID: [String: ChangesFileTreeNode]
    /// Root-to-parent identities, excluding the file itself, for revealing a selected file.
    public let ancestorsByFileID: [String: [String]]

    public init(groups: [ChangesOverviewEnvironment]) {
        var builder = ChangesFileTreeBuilder()
        for group in groups where !group.files.isEmpty {
            builder.append(group)
        }
        let result = builder.finish()
        roots = result.roots
        nodesByID = result.nodesByID
        ancestorsByFileID = result.ancestorsByFileID
    }

    /// Pure navigation filtering; matching a visible container label retains its descendant files.
    public func filtered(matching query: String) -> ChangesFileTree {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self }

        var pending = roots.map { (node: $0, inheritedMatch: false) }
        var traversal: [(node: ChangesFileTreeNode, matches: Bool)] = []
        while let entry = pending.popLast() {
            let node = entry.node
            let matches = entry.inheritedMatch || node.label.localizedStandardContains(query)
                || (node.kind == .file && node.path.localizedStandardContains(query))
            traversal.append((node, matches))
            pending.append(contentsOf: node.children.map { (node: $0, inheritedMatch: matches) })
        }

        var retained: [String: ChangesFileTreeNode] = [:]
        var ancestors: [String: [String]] = [:]
        for entry in traversal.reversed() {
            let node = entry.node
            if node.kind == .file {
                guard entry.matches else { continue }
                retained[node.id] = node
                ancestors[node.id] = ancestorsByFileID[node.id]
            } else {
                let children = node.children.compactMap { retained[$0.id] }
                guard !children.isEmpty else { continue }
                retained[node.id] = ChangesFileTreeNode(id: node.id, kind: node.kind, label: node.label,
                    environmentID: node.environmentID, fileID: node.fileID, path: node.path,
                    fileCount: children.reduce(0) { $0 + $1.fileCount }, children: children)
            }
        }
        return ChangesFileTree(roots: roots.compactMap { retained[$0.id] }, nodesByID: retained,
            ancestorsByFileID: ancestors)
    }

    private init(roots: [ChangesFileTreeNode], nodesByID: [String: ChangesFileTreeNode],
                 ancestorsByFileID: [String: [String]]) {
        self.roots = roots
        self.nodesByID = nodesByID
        self.ancestorsByFileID = ancestorsByFileID
    }
}

public struct ChangesFileTreeNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case worktree, directory, file, outsidePaths
    }

    public let id: String
    public let kind: Kind
    public let label: String
    /// Exact recorded environment identity, including an unknown one.
    public let environmentID: String
    /// Leaves reuse the corresponding ChangesOverviewFile identity; containers have no file identity.
    public let fileID: String?
    /// Leaves retain the projection's complete lexical path. No current filesystem path is substituted.
    public let path: String
    public let fileCount: Int
    public let children: [ChangesFileTreeNode]
}

private struct ChangesFileTreeBuilder {
    // At most 64 directory nodes precede a leaf. Deeper directory suffixes are compacted into
    // one lexical label/path, so construction, navigation and value hashing have bounded depth.
    private static let maximumDirectoryDepth = 64

    private struct Entry {
        let id: String
        let kind: ChangesFileTreeNode.Kind
        let label: String
        let environmentID: String
        let fileID: String?
        let path: String
        let parent: Int?
        var children: [Int] = []
    }

    private var entries: [Entry] = []
    private var indicesByID: [String: Int] = [:]
    private var rootIndices: [Int] = []

    mutating func append(_ group: ChangesOverviewEnvironment) {
        let environmentID = group.id
        let rootID = treeIdentity("worktree", [environmentID])
        let root = insert(id: rootID, kind: .worktree,
            label: environmentID.split(separator: "/").last.map(String.init)
                ?? (environmentID.isEmpty ? "Unknown environment" : environmentID),
            environmentID: environmentID, path: group.environment.path, parent: nil)
        for file in group.files {
            let relativePath = file.relativePath
            guard !environmentID.isEmpty, relativePath != file.path else {
                let outside = insert(id: treeIdentity("outside", [environmentID]), kind: .outsidePaths,
                    label: "Outside worktree", environmentID: environmentID, path: "", parent: root)
                // Absolute/external and unknown relative paths remain explicit complete paths.
                // Nesting them beneath worktree directories would invent false ancestry.
                insertFile(file, label: file.path, parent: outside)
                continue
            }

            let components = relativePath.split(separator: "/").map(String.init)
            let fileLabel = components.last ?? relativePath
            var directoryLabels = Array(components.dropLast())
            if directoryLabels.count > Self.maximumDirectoryDepth {
                let tail = directoryLabels.dropFirst(Self.maximumDirectoryDepth - 1).joined(separator: "/")
                directoryLabels = Array(directoryLabels.prefix(Self.maximumDirectoryDepth - 1)) + [tail]
            }

            let basePath = String(file.path.dropLast(relativePath.count))
            var directoryPath = basePath
            var parent = root
            for label in directoryLabels {
                directoryPath += label
                parent = insert(id: treeIdentity("directory", [environmentID, directoryPath]), kind: .directory,
                    label: label, environmentID: environmentID, path: directoryPath, parent: parent)
                directoryPath += "/"
            }
            insertFile(file, label: fileLabel, parent: parent)
        }
    }

    private mutating func insertFile(_ file: ChangesOverviewFile, label: String, parent: Int) {
        _ = insert(id: file.id, kind: .file, label: label, environmentID: file.environmentID,
            fileID: file.id, path: file.path, parent: parent)
    }

    @discardableResult
    private mutating func insert(id: String, kind: ChangesFileTreeNode.Kind, label: String,
                                 environmentID: String, fileID: String? = nil, path: String, parent: Int?) -> Int {
        if let existing = indicesByID[id] { return existing }
        let index = entries.count
        entries.append(Entry(id: id, kind: kind, label: label, environmentID: environmentID,
            fileID: fileID, path: path, parent: parent))
        indicesByID[id] = index
        if let parent { entries[parent].children.append(index) }
        else { rootIndices.append(index) }
        return index
    }

    func finish() -> (roots: [ChangesFileTreeNode], nodesByID: [String: ChangesFileTreeNode],
                      ancestorsByFileID: [String: [String]]) {
        // Entries always follow their parents. Freeze from the bottom up without recursive traversal.
        var frozen = [ChangesFileTreeNode?](repeating: nil, count: entries.count)
        var nodesByID: [String: ChangesFileTreeNode] = [:]
        var ancestorsByFileID: [String: [String]] = [:]
        for index in entries.indices.reversed() {
            let entry = entries[index]
            let children = entry.children.map { frozen[$0]! }.sorted(by: treeNodeOrder)
            let node = ChangesFileTreeNode(id: entry.id, kind: entry.kind, label: entry.label,
                environmentID: entry.environmentID, fileID: entry.fileID, path: entry.path,
                fileCount: entry.kind == .file ? 1 : children.reduce(0) { $0 + $1.fileCount }, children: children)
            frozen[index] = node
            nodesByID[node.id] = node
            if let fileID = entry.fileID {
                var ancestors: [String] = []
                var parent = entry.parent
                while let ancestor = parent {
                    ancestors.append(entries[ancestor].id)
                    parent = entries[ancestor].parent
                }
                ancestorsByFileID[fileID] = Array(ancestors.reversed())
            }
        }
        return (roots: rootIndices.map { frozen[$0]! }.sorted(by: treeNodeOrder),
            nodesByID: nodesByID, ancestorsByFileID: ancestorsByFileID)
    }
}

private func treeIdentity(_ kind: String, _ fields: [String]) -> String {
    "changes-tree-" + kind + ":" + fields.map { String($0.utf8.count) + ":" + $0 }.joined()
}

private func treeNodeOrder(_ left: ChangesFileTreeNode, _ right: ChangesFileTreeNode) -> Bool {
    if (left.kind == .file) != (right.kind == .file) { return left.kind != .file }
    let compared = left.label.compare(right.label, options: [.numeric, .caseInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
    if compared != .orderedSame { return compared == .orderedAscending }
    if left.label != right.label { return left.label < right.label }
    return left.id < right.id
}
