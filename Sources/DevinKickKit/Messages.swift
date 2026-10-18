import DevinOpenAPI
public import Foundation

/// One message of a session's chat transcript (not its event stream; amendment A6).
public struct SessionMessage: Sendable, Hashable {
    public var createdAt: Date
    /// Who sent it, as the API names them (`user`, `devin`, …).
    public var source: String
    public var message: String

    /// The server's record, for `messages.json`.
    let record: Components.Schemas.SessionMessage

    init(_ record: Components.Schemas.SessionMessage) {
        self.record = record
        createdAt = Date(timeIntervalSince1970: TimeInterval(record.createdAt))
        source = record.source
        message = record.message
    }

    /// `2026-10-18 14:05  devin  The first line…`.
    public var compactLine: String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "\(Self.timestamp(createdAt))  \(source)  \(firstLine)"
    }

    /// The header line and the whole message.
    public var fullText: String {
        "--- \(Self.timestamp(createdAt))  \(source)\n\(message)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension DevinKick {
    /// The most messages one page asks for (the spec's `first`, at most 200).
    static let messagePageSize = 200

    /// The whole transcript of `sessionID`, oldest first. Pages run forward only (`after`), so
    /// the tail is the end of a full drain; `last` keeps that many.
    public func messages(_ sessionID: String, last: Int? = nil) async throws(KickError) -> [SessionMessage] {
        let orgID = try configuration.requireOrgID()
        var messages: [SessionMessage] = []
        var cursor: String?
        repeat {
            let page = try await call(Operations.GetSessionMessages.id) {
                try await client.getSessionMessages(
                    path: .init(orgId: orgID, devinId: sessionID),
                    query: .init(after: cursor, first: Self.messagePageSize)
                ).ok.body.json
            }
            messages += page.items.map(SessionMessage.init)
            // A cursor that doesn't move would loop forever: stop there.
            let next = page.hasNextPage == true ? page.endCursor : nil
            cursor = next == cursor ? nil : next
        } while cursor != nil
        return last.map { Array(messages.suffix($0)) } ?? messages
    }
}
