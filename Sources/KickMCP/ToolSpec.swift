import DevinKickKit
import Foundation
import MCP

/// What a tool answers, before the cap: one line per item, and the next step.
struct ToolReply: Sendable, Equatable {
    /// One line per item; the cap cuts from the end.
    var lines: [String]
    /// What to do next, repeated in every result (deepwiki-mcp's lesson); the cap never cuts it.
    var next: String?
    /// Where the lines the cap leaves out can be read: a run directory, or the CLI command.
    var rest: String
    /// Whether the call failed as a whole; a batch where some items failed is not.
    var isError = false

    init(lines: [String], next: String? = nil, rest: String, isError: Bool = false) {
        self.lines = lines
        self.next = next
        self.rest = rest
        self.isError = isError
    }

    /// A failure as a model reads it: the message, then the status the CLI would exit with and
    /// what it means, so a model reads the same contract a shell does.
    init(_ error: KickError) {
        self.init(
            lines: [error.localizedDescription], next: Self.status(of: error),
            rest: "the same command through the kick CLI prints it whole", isError: true
        )
    }

    /// `status 69: no answer, or 429 / 5xx: retry`.
    static func status(of error: KickError) -> String {
        status(error.exitCode)
    }

    /// `status 75: still working: poll again`: a status the CLI would exit with, and what it means.
    static func status(_ code: Int32) -> String {
        "status \(code): \(ExitStatus.meaning(of: code) ?? "failed")"
    }

    /// One item of a batch that failed: `name: message (status 64: usage error)`.
    static func failure(_ name: String, _ error: KickError) -> String {
        "\(name): \(error.localizedDescription) (\(status(of: error)))"
    }

    /// The most characters of a message a result quotes: its first line, at most this long.
    static let messageLength = 160

    /// `2026-10-18 14:05  devin  The first line…`: never the whole message (plan decision 5).
    static func compact(_ message: SessionMessage) -> String {
        let line = message.compactLine
        return line.count > messageLength ? String(line.prefix(messageLength)) + "…" : line
    }
}

/// One tool (amendment A17): its definition, and a handler from the call's arguments to a reply.
struct ToolSpec: Sendable {
    let tool: Tool
    /// Decodes the arguments into the tool's own input, then runs it over the façade. It runs
    /// `@concurrent`: the SDK starts each handler from its `Server` actor, so under
    /// `NonisolatedNonsendingByDefault` a handler's synchronous stretches (hashing an upload)
    /// would otherwise stall the dispatch of every other call (Design: "Explicit `@concurrent`").
    let run: @concurrent @Sendable (_ arguments: [String: Value], _ kick: DevinKick) async throws(KickError) -> ToolReply

    init<Input: Decodable & Sendable>(
        name: String, title: String, description: String, schema: Value, annotations: Tool.Annotations,
        body: @escaping @concurrent @Sendable (Input, DevinKick) async throws(KickError) -> ToolReply
    ) {
        tool = Tool(name: name, title: title, description: description, inputSchema: schema, annotations: annotations)
        run = { arguments, kick throws(KickError) in
            try await body(try ToolInput.decode(Input.self, from: arguments, schema: schema), kick)
        }
    }
}

/// A profile's tools, and the one boundary every call crosses: look the tool up, decode its
/// arguments, call it, render, cap (plan decision 2).
struct Toolbox: Sendable {
    let specs: [ToolSpec]
    /// The façade, or the configuration error every tool answers (status 78): the server starts
    /// without a key, so the model can tell the user what to set (plan decision 10).
    let kick: Result<DevinKick, KickError>

    var tools: [Tool] { specs.map(\.tool) }

    /// The result of the call `params` names. A ``KickError`` becomes an `isError` result: it is
    /// advice for the model, which a thrown error would turn into a protocol error. Two things
    /// are thrown: an unknown tool, a protocol error by the MCP spec (2025-11-25, "Error
    /// Handling"), and cancellation, so the SDK sends no response at all (plan decision 9).
    ///
    /// `@concurrent`, so the lookup, the decoding and the cap run off the SDK's `Server` actor
    /// too: the closure registered with the SDK is ours, so under `NonisolatedNonsendingByDefault`
    /// it may start on that actor (DeepWiki on swift-sdk, 2026-10-19).
    @concurrent func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let spec = specs.first(where: { $0.tool.name == params.name }) else {
            throw MCPError.invalidParams("Unknown tool: \(params.name). This server's tools: \(specs.map(\.tool.name).joined(separator: ", ")).")
        }
        let reply: ToolReply
        // TODO(TD-10): only kick_wait bounds its requests; a hung Devin can outlast the client here.
        do throws(KickError) {
            reply = try await spec.run(params.arguments ?? [:], try kick.get())
        } catch {
            reply = ToolReply(error)
        }
        try Task.checkCancellation()
        return CallTool.Result(content: [.text(text: ResultCap.apply(reply), annotations: nil, _meta: nil)], isError: reply.isError)
    }
}
