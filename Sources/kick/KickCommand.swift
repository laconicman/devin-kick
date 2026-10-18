import ArgumentParser
import DevinKickKit
import Foundation

/// `kick` — one binary, both faces: CLI subcommands for people and scripts, and (from M2)
/// `kick serve` as an MCP stdio server for agents, both over the same ``DevinKick`` façade.
@main
struct KickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kick",
        abstract: "Devin as a side kick or a main kick, over Devin's official v3 API.",
        discussion: """
        Credentials come from the environment: DEVIN_API_KEY (a cog_ key) and DEVIN_ORG_ID. \
        Export them from ~/.zshenv so every shell, and every agent's shell, sees them.

        Exit status (stable; scripts may rely on it):
        \(ExitStatus.help)
        """,
        version: DevinKick.version,
        subcommands: [WhoAmI.self, UploadCommand.self, StartCommand.self]
    )
}

/// `kick self` — who the key acts as.
struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self",
        abstract: "Show who the key acts as (GET /v3/self). Never prints the key."
    )

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            let kick = DevinKick(configuration: try Configuration.fromEnvironment())
            let principal = try await kick.whoami()
            print("principal_type: \(principal.type)")
            if let name = principal.name { print("name: \(name)") }
        }
    }
}

extension DevinKick {
    /// The façade over the environment's configuration, warnings to stderr.
    static func fromEnvironment() throws(KickError) -> DevinKick {
        DevinKick(configuration: try Configuration.fromEnvironment())
    }
}

/// Writes `kick: <message>` to stderr.
func printError(_ message: String) {
    FileHandle.standardError.write(Data("kick: \(message)\n".utf8))
}

/// Runs `body`, printing a ``KickError`` to stderr and exiting with its documented status.
func reportingKickErrors(_ body: () async throws(KickError) -> Void) async throws {
    do {
        try await body()
    } catch {
        printError(error.localizedDescription)
        throw ExitCode(error.exitCode)
    }
}
