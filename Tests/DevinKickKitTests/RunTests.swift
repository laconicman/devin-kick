@testable import DevinKickKit
import Foundation
import Synchronization
import Testing

@Suite("Run — start, poll, save, archive what's done", .temporaryDirectories)
struct RunTests {
    static let finalOutput = #"{"answer_md":"a","doubts":[],"questions_for_user":[],"kick_final":true}"#

    @Test(arguments: [("3h", 10_800), ("45m", 2_700), ("90s", 90), ("1h30m", 5_400), ("600", 600)])
    func budgetsParse(_ text: String, seconds: Int64) throws {
        #expect(try DevinKick.budget(text) == .seconds(seconds))
    }

    @Test(arguments: ["", "0", "3d", "h", "1h30", "-5", "1.5h"])
    func badBudgetsAreUsageErrors(_ text: String) {
        #expect { try DevinKick.budget(text) } throws: { ($0 as? KickError)?.exitCode == 64 }
    }

    /// The scripted façade, its store, and one started run for session 1.
    static func started(_ transport: ScriptedTransport, sleeps: SleepRecorder = SleepRecorder()) async throws -> (DevinKick, StartedRun) {
        let base = temporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("Do the thing.".utf8).write(to: base.appending(path: "prompt.md"))
        let kick = try DevinKick.scripted(transport, sleeps: sleeps, environment: ["KICK_STORE": base.appending(path: "store").path])
        let request = try kick.prepare(promptFile: base.appending(path: "prompt.md").path, title: "run", schemaFile: nil, attach: [], options: StartOptions())
        return (kick, try await kick.start(request))
    }

    static func scripts(sessions: [ScriptedTransport.Reply]) -> [String: [ScriptedTransport.Reply]] {
        [
            "get_automation_schemas": [.json(Fixture.schemas(modes: ["swe-2-max"]))],
            "create_session": [.json(Fixture.session())],
            "get_session": sessions,
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
            "archive_session": [.json(Fixture.session(status: "suspended", detail: "user_request"))],
        ]
    }

    @Test func aDoneRunIsSavedAndArchived() async throws {
        let transport = ScriptedTransport(Self.scripts(sessions: [
            .json(Fixture.session()),
            .json(Fixture.session(detail: "waiting_for_user", output: Self.finalOutput)),
        ]))
        let (kick, started) = try await Self.started(transport)
        let heard = Mutex<[String]>([])
        let completed = await kick.run([started], budget: .seconds(3600)) { reading in
            heard.withLock { $0.append(reading.outcome.label) }
        }
        let result = try #require(completed.first)
        #expect(result.reading.outcome == .settled(.done(detail: "waiting_for_user")))
        #expect(result.archived)
        #expect(result.saved?.files.map(\.lastPathComponent).sorted() == ["messages.json", "result.json", "session.json"])
        #expect(heard.withLock { $0 } == ["working", "done"])
        #expect(await transport.count("archive_session") == 1)
        #expect(Reading.exitCode(completed.map(\.reading)) == 0)
    }

    /// A done session whose archive fails isn't a clean exit: the failure counts, alone with its
    /// own status (from the 2026-10-18 diff review through kick).
    @Test func anArchiveFailureCountsInTheExitStatus() async throws {
        var scripts = Self.scripts(sessions: [.json(Fixture.session(detail: "waiting_for_user", output: Self.finalOutput))])
        scripts["archive_session"] = [.response(status: 403, body: Fixture.problem(status: 403, detail: "forbidden"))]
        let (kick, started) = try await Self.started(ScriptedTransport(scripts))
        let completed = await kick.run([started], budget: .seconds(3600))
        let result = try #require(completed.first)
        #expect(result.reading.outcome == .settled(.done(detail: "waiting_for_user")))
        #expect(!result.archived)
        #expect(Reading.exitCode(completed.map(\.reading)) == 0)
        #expect(Reading.exitCode(completed.map(\.exitReading)) == 1)
    }

    /// At the budget a working session is saved as it stands, not archived, and exits 75.
    @Test func aSessionStillWorkingAtTheBudgetIsSavedNotArchived() async throws {
        let transport = ScriptedTransport(Self.scripts(sessions: [.json(Fixture.session())]))
        let sleeps = SleepRecorder()
        let (kick, started) = try await Self.started(transport, sleeps: sleeps)
        let completed = await kick.run([started], budget: .seconds(600))
        #expect(completed.first?.archived == false)
        #expect(completed.first?.saved != nil)
        #expect(Reading.exitCode(completed.map(\.reading)) == 75)
        #expect(sleeps.delays.reduce(.zero, +) == .seconds(600))
        #expect(await transport.count("archive_session") == 0)
    }

    /// A session that asks is left for a reply: saved, not archived.
    @Test func anAskingSessionIsLeftForAReply() async throws {
        let transport = ScriptedTransport(Self.scripts(sessions: [
            .json(Fixture.session(detail: "waiting_for_user", output: #"{"answer_md":"","questions_for_user":["Which repo?"],"kick_final":false}"#)),
        ]))
        let (kick, started) = try await Self.started(transport)
        let completed = await kick.run([started], budget: .seconds(3600))
        #expect(completed.first?.reading.outcome == .settled(.needsInput(detail: "waiting_for_user")))
        #expect(completed.first?.archived == false)
        #expect(Reading.exitCode(completed.map(\.reading)) == 10)
    }
}
