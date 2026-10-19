import ArgumentParser
import DevinKickKit
import Foundation

/// `kick reply` — a message to a session.
struct ReplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Post a message to a session; a suspended one is resumed.",
        discussion: """
        A session that has ended (exit or error) gets "start a new one" (exit 1) and nothing \
        is posted. After a reply, an earlier final output reads as stale until Devin gives a \
        new one.
        """
    )

    @Argument(help: "A session id, run id or run directory.")
    var id: String

    @Option(help: "The message text.")
    var text: String?

    @Option(help: "A file whose text is the message, byte for byte.")
    var file: String?

    @Option(help: "A file to attach, inside KICK_UPLOAD_ROOTS. Repeatable.")
    var attach: [String] = []

    func validate() throws {
        guard (text == nil) != (file == nil) else { throw ValidationError("Give exactly one of --text and --file.") }
    }

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            let kick = try DevinKick.fromEnvironment()
            if let file {
                try await kick.reply(id, file: file, attach: attach)
            } else {
                try await kick.reply(id, text: text ?? "", attach: attach)
            }
            emit("posted to \(try await kick.sessionID(of: id))")
        }
    }
}
