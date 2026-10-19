import DevinKickKit
import MCP

extension ToolSpec {
    struct WaitInput: Decodable, Sendable {
        enum Until: String, Decodable, Sendable {
            case all, any
        }

        var ids: StringList
        var timeout: Int?
        var until: Until?
    }

    /// `kick_wait`: a bounded wait, called again until the sessions settle (plan decision 6).
    /// `maximum` is `kick serve --max-wait`, at most ``DevinKick/maximumWait``; no argument can
    /// raise it.
    static func wait(maximum: Duration) -> ToolSpec {
        let seconds = Int(maximum.components.seconds)
        return ToolSpec(
            name: "kick_wait",
            title: "Wait for Devin sessions",
            description: """
            Wait until sessions settle, at most \(seconds) s per call, then show them as \
            kick_status does. It returns as soon as every session has settled (until: all, the \
            default) or the first one has (until: any). If any is still working when the time is \
            up, call kick_wait again with the same ids: one call never waits longer, so it stays \
            under the client's time limit.
            """,
            schema: InputSchema.object([
                "ids": InputSchema.list("Run ids, session ids or run directories."),
                "timeout": InputSchema.integer("Seconds to wait at most, 1 to \(seconds). Default \(seconds).", minimum: 1, maximum: seconds),
                "until": InputSchema.oneOf(["all", "any"], "all (default): until every session settles; any: until the first does."),
            ], required: ["ids"]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ) { (input: WaitInput, kick: DevinKick) async throws(KickError) -> ToolReply in
            guard !input.ids.items.isEmpty else { throw .usage("Name at least one session in ids.") }
            let timeout = input.timeout.map { Duration.seconds($0) } ?? maximum
            guard timeout <= maximum else {
                throw .usage("This server waits at most \(seconds) s per call (kick serve --max-wait); call kick_wait again to wait longer.")
            }
            let readings = try await kick.wait(input.ids.items, until: input.until == .any ? .any : .all, timeout: timeout)
            return await .readings(readings, kick: kick)
        }
    }
}
