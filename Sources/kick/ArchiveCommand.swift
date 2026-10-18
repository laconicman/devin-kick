import ArgumentParser
import DevinKickKit

/// `kick archive` — archive sessions, optionally ending them first.
struct ArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive sessions (a running one is put to sleep); --terminate ends them first."
    )

    @Argument(help: "Session ids, run ids or run directories.")
    var ids: [String] = []

    @Flag(help: "End each session, then archive it, in one call.")
    var terminate = false

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("Name at least one session or run.") }
    }

    func run() async throws {
        try await eachSession(ids) { (kick, id) async throws(KickError) in
            let session = try await kick.archive(id, terminate: terminate)
            let state = session.status + (session.statusDetail.map { "/\($0)" } ?? "")
            switch (terminate, session.status) {
            case (false, _): return "\(session.id)  archived  \(state)"
            case (true, "exit"): return "\(session.id)  terminated and archived  \(state)"
            case (true, "suspended"):
                // A terminate leaves a sleeping session asleep; archived, it is as good as ended.
                return "\(session.id)  archived, asleep (a terminate doesn't end a sleeping session)  \(state)"
            case (true, _):
                printError("\(session.id): the terminate was answered, but the session still reads \(state); terminate it again to stop it.")
                return "\(session.id)  archived, not terminated  \(state)"
            }
        }
    }
}

/// `kick unarchive` — undo `archive`.
struct UnarchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unarchive", abstract: "Unarchive sessions.")

    @Argument(help: "Session ids, run ids or run directories.")
    var ids: [String] = []

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("Name at least one session or run.") }
    }

    func run() async throws {
        try await eachSession(ids) { (kick, id) async throws(KickError) in
            let session = try await kick.unarchive(id)
            return "\(session.id)  unarchived"
        }
    }
}

/// Runs `body` for each id with one façade (see ``each(_:named:_:)``).
func eachSession(_ ids: [String], _ body: (DevinKick, String) async throws(KickError) -> String) async throws {
    try await reportingKickErrors { () async throws(KickError) in
        let kick = try DevinKick.fromEnvironment()
        try await each(ids, named: { $0 }) { id async throws(KickError) in try await body(kick, id) }
    }
}
