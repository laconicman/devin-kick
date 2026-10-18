import ArgumentParser
import DevinKickKit

/// `kick wait` — a bounded wait for sessions to settle.
struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait (at most 240 s) for sessions to settle, then show them as status does.",
        discussion: """
        Polls every 15 s, backing off to 60 s. A 429, a 5xx or no answer counts as transient \
        and is polled again. Call it again to wait longer; the exit status says whether to.
        """
    )

    enum Condition: String, EnumerableFlag {
        case all, any

        static func help(for value: Condition) -> ArgumentHelp? {
            switch value {
            case .all: "Return when every session has settled (the default)."
            case .any: "Return at the first session that settles."
            }
        }
    }

    @Argument(help: "Session ids, run ids or run directories.")
    var ids: [String] = []

    @Flag var condition: Condition = .all

    @Option(help: "Seconds to wait at most, 1 to 240.")
    var timeout: Int = Int(DevinKick.maximumWait.components.seconds)

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("Name at least one session or run.") }
        guard (1...DevinKick.maximumWait.components.seconds).contains(Int64(timeout)) else {
            throw ValidationError("--timeout is 1 to \(DevinKick.maximumWait.components.seconds) seconds; call wait again to wait longer.")
        }
    }

    func run() async throws {
        try await exitingWithStatus { () async throws(KickError) -> Int32 in
            let kick = try DevinKick.fromEnvironment()
            let readings = try await kick.wait(ids, until: condition == .any ? .any : .all, timeout: .seconds(timeout))
            return printed(readings)
        }
    }
}
