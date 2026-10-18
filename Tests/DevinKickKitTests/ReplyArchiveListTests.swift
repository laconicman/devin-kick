@testable import DevinKickKit
import Foundation
import HTTPTypes
import Testing

@Suite("Reply, archive and list", .temporaryDirectories)
struct ReplyArchiveListTests {
    static let sessionID = "0000000000000000000000000000000d"
    static let runID = "20261018-120000-000d"
    static let finalOutput = #"{"answer_md":"a","doubts":[],"questions_for_user":[],"kick_final":true}"#

    /// A façade whose store holds run ``runID`` for ``sessionID``.
    static func kick(_ transport: ScriptedTransport, environment: [String: String] = [:]) async throws -> DevinKick {
        let kick = try DevinKick.scripted(transport, environment: environment)
        var run = RunState(runID: runID, directory: temporaryDirectory(), mode: "swe-2-max", title: "t", tags: ["kick", "batch"], resumable: true)
        run.sessionID = sessionID
        try await kick.store.append(IndexEvent(.created, run: run))
        return kick
    }

    @Test func aReplyIsPostedAndMakesTheFinalOutputStale() async throws {
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID, detail: "waiting_for_user", output: Self.finalOutput))],
            "post_message": [.json(Fixture.session(id: Self.sessionID))],
        ])
        let kick = try await Self.kick(transport)
        try await kick.reply(Self.runID, text: "Line one\nline two — ünïcode")
        let body = try #require(await transport.bodies("post_message").first)
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(sent?["message"] as? String == "Line one\nline two — ünïcode")
        #expect(await kick.store.lookup(Self.runID)?.replied == true)
        #expect(await kick.observe(Self.sessionID).verdict == .staleFinal)
    }

    /// A11: an ended session gets "start a new one", and nothing is posted.
    @Test(arguments: ["exit", "error"])
    func aReplyToAnEndedSessionIsRefusedBeforeThePost(_ status: String) async throws {
        let transport = ScriptedTransport(["get_session": [.json(Fixture.session(id: Self.sessionID, status: status, detail: nil))]])
        let kick = try await Self.kick(transport)
        await #expect(throws: KickError.ended(sessionID: Self.sessionID, status: status)) {
            try await kick.reply(Self.sessionID, text: "hello?")
        }
        #expect(KickError.ended(sessionID: "x", status: status).exitCode == 1)
        #expect(await transport.count("post_message") == 0)
        #expect(await kick.store.lookup(Self.runID)?.replied == false)
    }

    @Test func aReplyWithAnAttachmentOutsideTheRootsPostsNothing() async throws {
        let transport = ScriptedTransport([:])
        let kick = try await Self.kick(transport, environment: ["KICK_UPLOAD_ROOTS": temporaryDirectory().path])
        await #expect { try await kick.reply(Self.sessionID, text: "see file", attach: ["/etc/hosts"]) } throws: {
            ($0 as? KickError)?.exitCode == 64
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func archiveAndUnarchiveAreRecorded() async throws {
        let transport = ScriptedTransport([
            "archive_session": [.json(Fixture.session(id: Self.sessionID, status: "running", detail: "waiting_for_user"))],
            "unarchive_session": [.json(Fixture.session(id: Self.sessionID, status: "suspended", detail: "user_request"))],
            "get_session": [.json(Fixture.session(id: Self.sessionID, status: "suspended", detail: "user_request"))],
        ])
        let kick = try await Self.kick(transport)
        // The archive's own answer is from before it; the session is read again.
        #expect(try await kick.archive(Self.runID).status == "suspended")
        #expect(await kick.store.lookup(Self.runID)?.archived == true)
        _ = try await kick.unarchive(Self.sessionID)
        #expect(await kick.store.lookup(Self.runID)?.archived == false)
    }

    /// `--terminate` is one `DELETE …?archive=true`, not a terminate and an archive, and the
    /// session is read back until `exit`: live, a terminate settled through `running/finished`
    /// in about 4 s, and an early one answered 200 and never ended the session.
    @Test(arguments: [("exit", 2), ("running", 6), ("suspended", 2)])
    func terminateIsOneDeleteThatArchivesThenReadsBack(_ after: String, reads: Int) async throws {
        let transport = ScriptedTransport([
            "terminate_session": [.json(Fixture.session(id: Self.sessionID, status: "running", detail: "working"))],
            "get_session": [.json(Fixture.session(id: Self.sessionID, status: "running", detail: "finished")),
                            .json(Fixture.session(id: Self.sessionID, status: after, detail: nil))],
        ])
        let kick = try await Self.kick(transport)
        // Read until exit (or asleep, which a terminate doesn't change), or for the 15 s
        // settle at 3 s apart: 1 + 5 reads. One still running after that is a failure, exit 1
        // (PR #11 review, r4308714800).
        if after == "running" {
            await #expect(throws: KickError.notTerminated(sessionID: Self.sessionID, status: "running")) {
                try await kick.archive(Self.sessionID, terminate: true)
            }
        } else {
            #expect(try await kick.archive(Self.sessionID, terminate: true).status == after)
        }
        #expect(await transport.count("get_session") == reads)
        let request = try #require(await transport.sent.first?.request)
        #expect(request.method == .delete)
        #expect(request.path?.hasSuffix("/sessions/\(Self.sessionID)?archive=true") == true)
        #expect(await transport.count("archive_session") == 0)
        #expect(await kick.store.lookup(Self.runID)?.archived == true)
    }

    /// Live, a terminate of an exited session answers 400: kick reads the session, and archives
    /// one that has exited instead of failing; a 400 on a live session still fails.
    @Test(arguments: [("exit", true), ("running", false)])
    func aRepeatedTerminateOfAnExitedSessionArchivesIt(_ status: String, succeeds: Bool) async throws {
        let transport = ScriptedTransport([
            "terminate_session": [.response(status: 400, body: Fixture.problem(status: 400, detail: "Devin session already exited"))],
            "get_session": [.json(Fixture.session(id: Self.sessionID, status: status, detail: nil))],
            "archive_session": [.json(Fixture.session(id: Self.sessionID, status: status, detail: nil))],
        ])
        let kick = try await Self.kick(transport)
        if succeeds {
            #expect(try await kick.archive(Self.sessionID, terminate: true).status == "exit")
            #expect(await transport.count("archive_session") == 1)
        } else {
            await #expect(throws: KickError.server(status: 400, code: nil, detail: "Devin session already exited")) {
                try await kick.archive(Self.sessionID, terminate: true)
            }
            #expect(await transport.count("archive_session") == 0)
        }
    }

    @Test func listReadsTheLocalIndexByTag() async throws {
        let kick = try await Self.kick(ScriptedTransport([:]))
        let other = RunState(runID: "20261018-120001-000e", directory: temporaryDirectory(), mode: nil, title: "other", tags: ["kick"], resumable: true)
        var refused = IndexEvent(.failed, run: other)
        refused.message = "422: bad mode"
        try await kick.store.append(refused)
        let batch = await kick.store.runs(tagged: "batch")
        #expect(batch.map(\.runID) == [Self.runID])
        let lines = await kick.store.runs(tagged: "kick").map(\.line)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasPrefix("20261018-120001-000e  -  -  other") && $0.hasSuffix("[not created: 422: bad mode]") })
    }

    @Test func listRemoteReadsTheServersSessionsByTagWithinTheLimit() async throws {
        let transport = ScriptedTransport(["get_sessions": [
            .json(Fixture.page([Fixture.session(id: Self.sessionID, detail: "waiting_for_user", output: Self.finalOutput)], next: "c1")),
            .json(Fixture.page([Fixture.session(id: "0000000000000000000000000000000f")])),
        ]])
        let kick = try await Self.kick(transport)
        let readings = try await kick.observeRemote(tagged: "batch", limit: 1)
        #expect(readings.count == 1)
        #expect(readings.first?.run?.runID == Self.runID)
        #expect(readings.first?.outcome == .settled(.done(detail: "waiting_for_user")))
        let path = try #require(await transport.sent.first?.request.path)
        #expect(path.contains("first=1") && path.contains("tags=batch"))
        #expect(await transport.count("get_sessions") == 1)
    }
}
