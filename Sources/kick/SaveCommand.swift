import ArgumentParser
import DevinKickKit
import Foundation

/// `kick save` — a session's state into its run directory.
struct SaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save sessions into their run directories: session, result, messages, attachments.",
        discussion: """
        A session kick didn't start gets a run directory of its own; a deleted one is \
        recreated. Prints one line per session: run id, session id, state, directory, files.
        """
    )

    @Argument(help: "Session ids, run ids or run directories.")
    var ids: [String] = []

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("Name at least one session or run.") }
    }

    func run() async throws {
        try await eachSession(ids) { (kick, id) async throws(KickError) in
            try await kick.save(id).line
        }
    }
}

extension SavedRun {
    /// `run id  session id  state  directory  (n files)`.
    var line: String {
        let state = if case .settled(let settlement) = reading.outcome { settlement.label } else { "error" }
        return "\(run.runID)  \(run.sessionID ?? "-")  \(state)  \(run.directory.path)  (\(files.count) files)"
    }
}
