import ArgumentParser
import DevinKickKit
import Foundation

/// `kick run` — start, wait, save, and archive what's done.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start sessions, wait for them (up to --budget), save them, and archive the done ones.",
        discussion: """
        Takes start's options. Prints each run as it starts, a status line on stderr when a \
        session's state changes, then one line per run when it is saved. Polls every 15 s, \
        backing off to 60 s. The exit status is the worst session's, as for status; a \
        session still working at the budget exits 75, and `kick wait` or `kick save` pick it up.
        """
    )

    @OptionGroup var flags: StartFlags

    @Option(help: "How long to wait for the sessions: like 3h, 45m, 90s, or seconds.")
    var budget = "3h"

    func run() async throws {
        try await exitingWithStatus { () async throws(KickError) -> Int32 in
            let kick = try DevinKick.fromEnvironment()
            let budget = try DevinKick.budget(budget)
            var started: [StartedRun] = []
            var failures: [Reading] = []
            for request in try flags.requests(kick) {
                do throws(KickError) {
                    let run = try await kick.start(request)
                    print(run.line)
                    started.append(run)
                } catch {
                    printError("\(request.name): \(error.localizedDescription)")
                    failures.append(Reading(argument: request.name, run: nil, session: nil, verdict: nil, outcome: .unreadable(error)))
                }
            }
            let completed = await kick.run(started, budget: budget) { reading in printError(reading.line()) }
            for result in completed {
                if let saved = result.saved {
                    print(saved.line + (result.archived ? "  [archived]" : ""))
                    TSVLog.append(saved)
                }
                if let error = result.error { printError("\(result.started.run.runID): \(error.localizedDescription)") }
            }
            return Reading.exitCode(completed.map(\.reading) + failures)
        }
    }
}
