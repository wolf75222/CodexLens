import Foundation

/// Content and provenance travel separately. Text in a trace can never impersonate
/// a presentation header. The legacy pager/copy format is kept unchanged.
public struct RecordedDocumentSlice: Sendable {
    public let source: SourceRef
    public let text: String
    public let complete: Bool
    public let fieldFound: Bool
}

public struct RecordedDocumentPage: Sendable {
    public let slices: [RecordedDocumentSlice]
    public let token: String?
    public let bytesRead: UInt64
    public let totalSourceBytes: UInt64
}

public actor RecordedDocumentPager {
    private let pager = RecordedPager()
    private struct Cursor {
        let event: LensEvent
        let sources: [SourceRef]
        let part: String
        var index = 0
        var childToken: String?
        var closedBytes: UInt64 = 0
    }
    private var cursors: [String: Cursor] = [:]
    private var order: [String] = []
    public init() {}

    public func begin(event: LensEvent, relatedEvent: LensEvent? = nil, part: String, limit: Int = 65536) async throws -> RecordedDocumentPage {
        var seen = Set<SourceRef>()
        let sources = ([event.source] + event.supplementarySources + (relatedEvent.map { [$0.source] + $0.supplementarySources } ?? []))
            .filter { seen.insert($0).inserted }
        let token = UUID().uuidString
        while order.count >= 8 { cursors.removeValue(forKey: order.removeFirst()) }
        cursors[token] = Cursor(event: event, sources: sources, part: part)
        order.append(token)
        return try await next(token: token, limit: limit)
    }

    public func next(token: String, limit: Int = 65536) async throws -> RecordedDocumentPage {
        guard var cursor = cursors.removeValue(forKey: token) else {
            throw LensError.unavailable("Lecture expirée. Ouvrez à nouveau l’événement enregistré.")
        }
        order.removeAll { $0 == token }
        var slices: [RecordedDocumentSlice] = []
        var bytesRead = cursor.closedBytes
        // Skip at most eight empty completed sources per request. A large field
        // scan returns its continuation instead of reading the entire event.
        while cursor.index < cursor.sources.count {
            try Task.checkCancellation()
            let source = cursor.sources[cursor.index]
            let page: RecordedPage
            if let child = cursor.childToken { page = try await pager.next(token: child, limit: limit) }
            else {
                var isolated = cursor.event
                isolated.source = source; isolated.supplementarySources = []
                page = try await pager.begin(event: isolated, part: cursor.part, limit: limit, decorateSources: false)
            }
            bytesRead = cursor.closedBytes + page.bytesRead
            slices.append(RecordedDocumentSlice(source: source, text: page.text,
                complete: page.token == nil, fieldFound: page.hasSelectedField))
            cursor.childToken = page.token
            if page.token != nil { break }
            cursor.closedBytes += page.bytesRead
            cursor.index += 1
            if !page.text.isEmpty || slices.count >= 8 { break }
        }
        let continuation = cursor.index < cursor.sources.count ? token : nil
        try Task.checkCancellation()
        if continuation != nil {
            while order.count >= 8 { cursors.removeValue(forKey: order.removeFirst()) }
            cursors[token] = cursor; order.append(token)
        }
        return RecordedDocumentPage(slices: slices, token: continuation, bytesRead: bytesRead,
            totalSourceBytes: cursor.sources.reduce(0) { $0 + UInt64(max(0, $1.length)) })
    }
}
