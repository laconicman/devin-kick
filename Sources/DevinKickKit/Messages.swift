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

extension DevinKick {
    /// Posts `text` (and `attach`, inside `KICK_UPLOAD_ROOTS`) to the session `argument` names,
    /// and records a `replied` event, which makes a final output stale (``OutputVerdict``).
    ///
    /// The status is read first: an `exit` or `error` session gets ``KickError/ended(sessionID:status:)``
    /// and nothing is posted (amendment A11). That check is a convenience, not a guarantee: the
    /// status can change before the POST, whose answer is authoritative. A suspended session is
    /// resumed by the post (the spec's `post_message`). The post's answer may lack
    /// `structured_output`, which the spec fills only on get and list, so results are read
    /// with a GET, never from here.
    public func reply(_ argument: String, text: String, attach: [String] = []) async throws(KickError) {
        let sessionID = try await sessionID(of: argument)
        let files = try checkUploadable(attach, relativeTo: nil)
        let current = try await session(sessionID)
        guard !["exit", "error"].contains(current.status) else {
            throw .ended(sessionID: sessionID, status: current.status)
        }
        var attachmentURLs: [String] = []
        for file in files {
            attachmentURLs.append(try await upload(resolved: file).url)
        }
        let orgID = try configuration.requireOrgID()
        _ = try await call(Operations.PostMessage.id) {
            try await client.postMessage(
                path: .init(orgId: orgID, devinId: sessionID),
                body: .json(.init(attachmentUrls: attachmentURLs.isEmpty ? nil : attachmentURLs, message: text))
            ).ok.body.json
        }
        try await record(.replied, for: argument)
    }

    /// ``reply(_:text:attach:)`` with a file's text, sent byte for byte: `kick reply --file` and
    /// `kick_reply`'s `file`. A relative path resolves against the working directory.
    public func reply(_ argument: String, file: String, attach: [String] = []) async throws(KickError) {
        let text = try Self.readText(Self.resolve(file, relativeTo: nil), what: "message")
        try await reply(argument, text: text, attach: attach)
    }
}
