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
            return "\(session.id)  archived  \(session.status)"
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
            return "\(session.id)  unarchived  \(session.status)"
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
