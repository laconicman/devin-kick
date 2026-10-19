// Public: `serve` takes the Kit's façade and error, KickMCP's vocabulary as they are the CLI's.
public import DevinKickKit
import MCP

/// What a person sets when launching `kick serve`, which no tool argument can change (plan
/// decisions 4 and 6).
public struct ServeOptions: Sendable {
    /// The longest one `kick_wait` call blocks: `--max-wait`, at most ``DevinKick/maximumWait``,
    /// lowered for a client that aborts a call sooner than Claude Code's 300 s.
    public var maxWait: Duration
    /// Whether sessions bypass approvals: on unless `--no-bypass-approval` (Design: "Approvals").
    public var bypassApproval: Bool

    public init(maxWait: Duration = DevinKick.maximumWait, bypassApproval: Bool = true) {
        self.maxWait = maxWait
        self.bypassApproval = bypassApproval
    }
}

/// The MCP face of `kick`: `kick serve --profile side` runs this server over stdio, on the same
/// ``DevinKick`` façade as the CLI (Design: "One binary, two faces, three layers").
public enum SideServer {
    /// The `serverInfo.name` the server announces: the package's name, distinct from Devin's
    /// official connector, which Claude Desktop would merge with one of the same display name
    /// (Design: "A name distinct from the service").
    public static let name = "devin-kick"

    /// How the tools fit together, for the client to show the model beside their descriptions.
    static let instructions = """
    devin-kick delegates bounded jobs to Devin sessions and keeps a local record of every run. \
    A session runs for minutes to hours, so no tool waits for one to finish: kick_start returns \
    at once; kick_wait waits a bounded time and is called again until the sessions settle; \
    kick_save writes each result to its run directory, where you read it, never from a tool \
    result. A session that asks is answered with kick_messages and kick_reply. kick_archive puts \
    away what you are done with.
    """

    /// Serves the side profile on stdio until stdin closes. `kick` is the façade, or the
    /// configuration error every tool then answers: the server starts either way, so the model
    /// can tell the user what to set (plan decision 10). stdout carries only the protocol; the
    /// Kit's warnings go to stderr.
    public static func serve(_ kick: Result<DevinKick, KickError>, options: ServeOptions) async throws {
        let server = await makeServer(Toolbox(specs: SideProfile.tools(options), kick: kick))
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// A server answering `tools/list` and `tools/call` from `toolbox`. The SDK runs each
    /// request in a task of its own, so a long `kick_wait` holds up no other call.
    static func makeServer(_ toolbox: Toolbox) async -> Server {
        let server = Server(
            name: name, version: DevinKick.version, instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: toolbox.tools) }
        await server.withMethodHandler(CallTool.self) { params in try await toolbox.call(params) }
        return server
    }
}
