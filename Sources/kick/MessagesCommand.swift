import ArgumentParser
import DevinKickKit
import Foundation

/// `kick messages` — a session's chat transcript.
struct MessagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Print a session's messages, oldest first: time, source, first line.",
        discussion: "The API pages forward only, so --last drains to the end and keeps the tail."
    )

    @Argument(help: "A session id, run id or run directory.")
    var id: String

    @Option(help: "Keep only the last N messages.")
    var last: Int?

    @Flag(help: "Print each message whole.")
    var full = false

    func validate() throws {
        if let last, last < 1 { throw ValidationError("--last is at least 1.") }
    }

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            let kick = try DevinKick.fromEnvironment()
            let sessionID = try await kick.sessionID(of: id)
            for message in try await kick.messages(sessionID, last: last) {
                emit(full ? message.fullText : message.compactLine)
            }
        }
    }
}
