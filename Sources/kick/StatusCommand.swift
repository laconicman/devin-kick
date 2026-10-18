import ArgumentParser
import DevinKickKit

/// `kick status` — one line per session, and the aggregate exit status.
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show where sessions stand, one line each.",
        discussion: """
        Each line: session id, state, Devin's status/detail, kick's reading of the output \
        (final, stale-final, provisional, none, unmarked), age, mode, title, and notes such \
        as a session past the 14-day resume window. Runs whose create answer was lost are \
        first looked for by their run tag. With several sessions, the exit status is the \
        worst: failed > unknown > needs input > working > done.
        """
    )

    @Argument(help: "Session ids, run ids or run directories.")
    var ids: [String] = []

    @Option(help: "Also every session on the server carrying this tag.")
    var tag: String?

    func validate() throws {
        guard !ids.isEmpty || tag != nil else { throw ValidationError("Name a session, a run, or --tag.") }
    }

    func run() async throws {
        try await exitingWithStatus { () async throws(KickError) -> Int32 in
            let kick = try DevinKick.fromEnvironment()
            await kick.reconcileOrphans()
            var readings: [Reading] = []
            for id in ids {
                readings.append(await kick.observe(id))
            }
            if let tag {
                let tagged = try await kick.observe(tagged: tag)
                guard !tagged.isEmpty || !readings.isEmpty else { throw .usage("No session carries the tag \(tag).") }
                readings += tagged
            }
            return printed(readings)
        }
    }
}

/// Prints one line per reading and returns their aggregate exit status.
func printed(_ readings: [Reading]) -> Int32 {
    for reading in readings { print(reading.line()) }
    return Reading.exitCode(readings)
}
