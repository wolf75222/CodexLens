import Foundation

/// Resolve Return without interpreting a human search query as a session ID.
public enum SessionPickerTarget {
    /// Parse only the thread route; a URL never launches Codex or resumes its thread.
    public static func sessionID(from text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: typed) { return id.uuidString.lowercased() }
        guard let link = URLComponents(string: typed), link.scheme?.lowercased() == "codex",
              link.host?.lowercased() == "threads", link.user == nil, link.password == nil, link.port == nil,
              !typed.contains(where: { $0.isWhitespace }) else { return nil }
        let parts = link.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return id.uuidString.lowercased()
    }

    public static func sameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = UUID(uuidString: lhs), let right = UUID(uuidString: rhs) else { return false }
        return left == right
    }

    public static func resolve(text: String, selectedID: String?, visibleIDs: [String]) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = sessionID(from: typed) {
            return visibleIDs.first { $0.caseInsensitiveCompare(id) == .orderedSame } ?? id
        }
        // Invalid links must not fall back to a selected, unrelated session.
        if typed.contains("://") { return nil }
        if let selectedID, visibleIDs.contains(selectedID) { return selectedID }
        if visibleIDs.count == 1 { return visibleIDs[0] }
        return nil
    }
}
