import ArgumentParser
import DevinKickKit
import KickMCP

/// `kick serve` — the MCP stdio server, for an agent such as Claude Code.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the MCP server on stdio, for an agent such as Claude Code.",
        discussion: """
        --profile side serves eight kick_* tools to a model that delegates bounded jobs to \
        Devin and checks the results itself: upload, start, status, wait, save, messages, \
        reply and archive. Results are compact and never inline a session's output; kick_save \
        writes it to the run directory. stdout carries the protocol, and warnings go to \
        stderr. The server reads the same environment as the CLI. Without DEVIN_API_KEY it \
        still starts, and every tool answers the configuration error.
        """
    )

    /// The tool profiles; M3 adds `main`.
    enum Profile: String, ExpressibleByArgument, CaseIterable {
        case side
    }

    @Option(help: "The tool profile: side, for a model that delegates and checks the results itself.")
    var profile: Profile

    @Flag(name: .customLong("no-bypass-approval"), help: "Let Devin wait for approvals (they read as needs input). No tool can change it.")
    var noBypassApproval = false

    @Option(name: .customLong("max-wait"), help: "The longest one kick_wait call blocks, 1 to 240 seconds; lower it for a client that aborts a call sooner.")
    var maxWait = Int(DevinKick.maximumWait.components.seconds)

    func validate() throws {
        guard (1...DevinKick.maximumWait.components.seconds).contains(Int64(maxWait)) else {
            throw ValidationError("--max-wait is 1 to \(DevinKick.maximumWait.components.seconds) seconds.")
        }
    }

    func run() async throws {
        let kick = Result { () throws(KickError) in try DevinKick.fromEnvironment() }
        let options = ServeOptions(maxWait: .seconds(maxWait), bypassApproval: !noBypassApproval)
        switch profile {
        case .side: try await SideServer.serve(kick, options: options)
        }
    }
}
