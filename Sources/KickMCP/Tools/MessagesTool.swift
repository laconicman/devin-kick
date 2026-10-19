import DevinKickKit
import MCP

extension ToolSpec {
    struct MessagesInput: Decodable, Sendable {
        var id: String
        var last: Int?
    }

    /// How many of the latest messages `kick_messages` shows unless asked for more or fewer.
    static let messagesShown = 10

    /// `kick_messages`: the latest messages' first lines, never the transcript (deepwiki-mcp's
    /// TD-10: re-sending a whole conversation on each poll pushed users off MCP).
    static let messages = ToolSpec(
        name: "kick_messages",
        title: "Read a Devin session's messages",
        description: """
        Show a session's latest messages, oldest first: time, sender and each message's first \
        line, the last \(messagesShown) unless last says otherwise. Use it to see what a session \
        asks, or why it stopped. It never returns whole messages: kick_save writes the whole \
        transcript to messages.json in the run directory.
        """,
        schema: InputSchema.object([
            "id": InputSchema.string("A run id, session id or run directory."),
            "last": InputSchema.integer("How many of the latest messages. Default \(messagesShown).", minimum: 1),
        ], required: ["id"]),
        annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    ) { (input: MessagesInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        let last = input.last ?? messagesShown
        guard last >= 1 else { throw .usage("last is at least 1.") }
        let messages = try await kick.messages(try await kick.sessionID(of: input.id), last: last)
        return ToolReply(
            lines: messages.map(ToolReply.compact),
            next: "next: answer a question with kick_reply; kick_save writes every message whole to messages.json.",
            rest: "`kick messages \(input.id) --last \(last)` in a shell, or messages.json after kick_save"
        )
    }
}
