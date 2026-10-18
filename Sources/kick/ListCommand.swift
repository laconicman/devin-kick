import ArgumentParser
import DevinKickKit

/// `kick list` — the runs kick recorded, or the server's sessions.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List runs from the local index, newest first, or the server's sessions with --remote.",
        discussion: """
        A local line: run id, session id, state at the last save, title, run directory, notes. \
        A remote line reads as status does. Runs whose create answer was lost are first looked \
        for by their run tag.
        """
    )

    @Option(help: "Only runs or sessions with this tag.")
    var tag: String?

    @Flag(help: "List the server's sessions instead of the local index.")
    var remote = false

    @Option(help: "At most this many.")
    var limit: Int = 50

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit is at least 1.") }
    }

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            let kick = try DevinKick.fromEnvironment()
            if remote {
                for reading in try await kick.observeRemote(tagged: tag, limit: limit) { emit(reading.line()) }
                return
            }
            await kick.reconcileOrphans()
            for run in await kick.store.runs(tagged: tag).prefix(limit) { emit(run.line) }
        }
    }
}
