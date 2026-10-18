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
        subcommands: [
            WhoAmI.self, UploadCommand.self, StartCommand.self, StatusCommand.self, WaitCommand.self,
            MessagesCommand.self, SaveCommand.self, ReplyCommand.self, ArchiveCommand.self, UnarchiveCommand.self,
            ListCommand.self,
        ]
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

/// Runs `body` for each item and prints the line it returns. One failure is printed and doesn't
/// stop the rest; the first one is rethrown at the end, so it sets the exit status.
func each<Item>(
    _ items: [Item], named name: (Item) -> String, _ body: (Item) async throws(KickError) -> String
) async throws(KickError) {
    var firstFailure: KickError?
    for item in items {
        do throws(KickError) {
            print(try await body(item))
        } catch {
            printError("\(name(item)): \(error.localizedDescription)")
            firstFailure = firstFailure ?? error
        }
    }
    if let firstFailure { throw firstFailure }
}

/// Writes `kick: <message>` to stderr.
func printError(_ message: String) {
    FileHandle.standardError.write(Data("kick: \(message)\n".utf8))
}

/// Runs `body`, printing a ``KickError`` to stderr and exiting with its documented status.
func reportingKickErrors(_ body: () async throws(KickError) -> Void) async throws {
    try await exitingWithStatus { () async throws(KickError) -> Int32 in
        try await body()
        return 0
    }
}

/// Runs `body` and exits with the status it returns, or with a ``KickError``'s, printed to
/// stderr.
func exitingWithStatus(_ body: () async throws(KickError) -> Int32) async throws {
    let code: Int32
    do {
        code = try await body()
    } catch {
        printError(error.localizedDescription)
        throw ExitCode(error.exitCode)
    }
    if code != 0 { throw ExitCode(code) }
}
