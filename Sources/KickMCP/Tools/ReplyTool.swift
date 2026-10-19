import DevinKickKit
import MCP

extension ToolSpec {
    struct ReplyInput: Decodable, Sendable {
        var id: String
        var text: String?
        var file: String?
        var attach: StringList?
    }

    /// `kick_reply`: a message to a session that asks or sleeps, then where it stands.
    static let reply = ToolSpec(
        name: "kick_reply",
        title: "Reply to a Devin session",
        description: """
        Post a message to a session that asks, waits or sleeps; a sleeping one wakes. Give \
        exactly one of text, or file: a file whose text is sent byte for byte. attach files must \
        lie inside KICK_UPLOAD_ROOTS. A session that has ended (exit or error) is refused: start \
        a new one. Returns the post and the session's status; then call kick_wait. After a \
        reply, an earlier final output reads stale-final until Devin gives a new one.
        """,
        schema: InputSchema.object([
            "id": InputSchema.string("A run id, session id or run directory."),
            "text": InputSchema.string("The message."),
            "file": InputSchema.string("A file whose text is the message, byte for byte."),
            "attach": InputSchema.list("Files to attach, inside KICK_UPLOAD_ROOTS."),
        ], required: ["id"]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    ) { (input: ReplyInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        let attach = input.attach?.items ?? []
        switch (input.text, input.file) {
        case (let text?, nil): try await kick.reply(input.id, text: text, attach: attach)
        case (nil, let file?): try await kick.reply(input.id, file: file, attach: attach)
        default: throw .usage("Give exactly one of text and file.")
        }
        let attached = attach.isEmpty ? "" : " with \(attach.count) attachment\(attach.count == 1 ? "" : "s")"
        return ToolReply(
            lines: ["posted to \(input.id)\(attached)", await kick.observe(input.id).line()],
            next: "next: call kick_wait with ids [\"\(input.id)\"], and again until it settles.",
            rest: "`kick status \(input.id)` in a shell"
        )
    }
}
