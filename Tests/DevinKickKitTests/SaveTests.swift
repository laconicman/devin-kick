@testable import DevinKickKit
import Foundation
import HTTPTypes
import Synchronization
import Testing

@Suite("Messages, attachments and save — into the run directory", .temporaryDirectories)
struct SaveTests {
    static let sessionID = "0000000000000000000000000000000c"
    static let attachmentID = "00000000-0000-0000-0000-00000000000c"
    static let finalOutput = #"{"answer_md":"a","doubts":[],"questions_for_user":[],"kick_final":true}"#

    static func message(_ text: String, at time: Int, source: String = "devin") -> String {
        #"{"event_id":"e\#(time)","source":"\#(source)","message":"\#(text)","created_at":\#(time)}"#
    }

    @Test func messagesDrainForwardAndKeepTheTail() async throws {
        let transport = ScriptedTransport(["get_session_messages": [
            .json(#"{"items":[\#(Self.message("one", at: 1, source: "user"))],"has_next_page":true,"end_cursor":"c1"}"#),
            .json(#"{"items":[\#(Self.message(#"two\nsecond line"#, at: 2)),\#(Self.message("three", at: 3))],"has_next_page":false}"#),
        ]])
        let kick = try DevinKick.scripted(transport)
        let all = try await kick.messages(Self.sessionID)
        #expect(all.map(\.message) == ["one", "two\nsecond line", "three"])
        #expect(all[1].compactLine.hasSuffix("  devin  two"))
        let requests = await transport.sent.map { $0.request.path ?? "" }
        #expect(requests.first?.contains("first=200") == true)
        #expect(requests.last?.contains("after=c1") == true)

        await transport.script("get_session_messages", [
            .json(#"{"items":[\#(Self.message("one", at: 1))],"has_next_page":true,"end_cursor":"c1"}"#),
            .json(#"{"items":[\#(Self.message("two", at: 2))],"has_next_page":true,"end_cursor":"c1"}"#),
        ])
        // A cursor that doesn't move stops the drain instead of looping.
        #expect(try await kick.messages(Self.sessionID, last: 1).map(\.message) == ["two"])
    }

    @Test(arguments: [
        ("../../request.json", "request.json"),
        ("/etc/passwd", "passwd"),
        ("..\\..\\win.ini", "win.ini"),
        (".hidden", "hidden"),
        ("..", "attachment"),
        ("", "attachment"),
        ("tab\there\u{0}.txt", "tabhere.txt"),
        ("report.pdf", "report-2.pdf"),
    ])
    func attachmentNamesAreReducedToSafeBasenames(_ name: String, expected: String) {
        #expect(DevinKick.safeName(name, taken: ["report.pdf"]) == expected)
    }

    @Test func aLongNameKeepsItsExtensionWithinTheCap() {
        let long = String(repeating: "я", count: 300) + ".tar.gz"
        let name = DevinKick.safeName(long, taken: [])
        #expect(name.utf8.count <= DevinKick.maximumNameBytes)
        #expect(name.hasSuffix(".gz"))
        // Numbered because taken, it still fits (from the 2026-10-18 diff review through kick).
        let numbered = DevinKick.safeName(long, taken: [name])
        #expect(numbered != name && numbered.hasSuffix("-2.gz"))
        #expect(numbered.utf8.count <= DevinKick.maximumNameBytes)
    }

    /// An "extension" longer than any real one is cut with the rest of the name (PR #11 review,
    /// r4308715273).
    @Test func anOversizedExtensionIsCutWithTheName() {
        let name = DevinKick.safeName("report." + String(repeating: "x", count: 300), taken: [])
        #expect(name.utf8.count <= DevinKick.maximumNameBytes)
        #expect(name.hasPrefix("report.x"))
    }

    /// A name of dots alone would be a dot-segment; its dots are encoded too.
    @Test(arguments: [("..", "%2E%2E"), (".", "%2E"), ("../x", "..%2Fx"), ("a.b c", "a.b%20c")])
    func namesTravelAsOneSegment(_ name: String, encoded: String) {
        #expect(DevinKick.pathSegment(name) == encoded)
    }

    /// A session kick didn't start: save adopts it as a run, writes every file, and the
    /// presigned hop of the attachment download carries no `Authorization`.
    @Test func saveWritesEveryFileAndStripsTheKeyOnTheRedirect() async throws {
        let api = "api-\(UUID().uuidString.lowercased()).test"
        let presigned = "bucket-\(UUID().uuidString.lowercased()).s3.us-west-2.amazonaws.com"
        RedirectingURLProtocol.routes.withLock {
            $0[api] = .init(location: URL(string: "https://\(presigned)/bucket/\(Self.attachmentID)?X-Amz-Signature=x"))
            $0[presigned] = .init(body: Data("attachment bytes".utf8))
        }
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID, detail: "waiting_for_user", output: Self.finalOutput))],
            "get_session_messages": [.json(#"{"items":[\#(Self.message("hello", at: 1, source: "user"))],"has_next_page":false}"#)],
            "get_session_attachments": [.json(#"[{"attachment_id":"\#(Self.attachmentID)","name":"../notes.txt","url":"https://app.devin.ai/attachments/\#(Self.attachmentID)/notes.txt","source":"devin"}]"#)],
        ])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_SERVER_URL": "https://\(api)"])
        let saved = try await kick.save(Self.sessionID)

        #expect(saved.reading.outcome == .settled(.done(detail: "waiting_for_user")))
        let names = Set(saved.files.map { $0.path.replacingOccurrences(of: saved.run.directory.path + "/", with: "") })
        #expect(names == ["session.json", "result.json", "messages.json", "attachments/notes.txt"])
        #expect(try Data(contentsOf: saved.run.directory.appending(path: "attachments/notes.txt")) == Data("attachment bytes".utf8))
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.run.directory.appending(path: "result.json"))) as? [String: Any]
        #expect(result?["kick_final"] as? Bool == true)

        let first = try #require(RedirectingURLProtocol.requests(to: api).first)
        // The server's name travels as one segment, its `/` encoded.
        #expect(first.url?.absoluteString == "https://\(api)/v3/organizations/org-test/attachments/\(Self.attachmentID)/..%2Fnotes.txt")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer cog_test")
        let hop = try #require(RedirectingURLProtocol.requests(to: presigned).first)
        #expect(hop.value(forHTTPHeaderField: "Authorization") == nil)

        // The foreign session is now a run: created, then settled, the rename recorded.
        let run = try #require(await kick.store.lookup(Self.sessionID))
        #expect(run.resumable == nil)
        #expect(run.lastSettlement == "done")
        let index = try String(contentsOf: kick.store.indexURL, encoding: .utf8)
        #expect(index.contains(#""renamed":{"../notes.txt":"notes.txt"}"#))
    }

    /// `KICK_LOG_TSV` gets one line per save, after a header when the file is new, so `kick save`,
    /// `kick run` and `kick_save` all log; a log that can't be written only warns.
    @Test func aSaveAppendsItsLineToTheTSVLog() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(path: "runs.tsv")
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID, detail: "waiting_for_user", output: Self.finalOutput))],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
        ])
        let warnings = WarningLog()
        let kick = try DevinKick.scripted(transport, warnings: warnings, environment: ["KICK_LOG_TSV": log.path])
        _ = try await kick.save(Self.sessionID)
        _ = try await kick.save(Self.sessionID)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == Substring(TSVLog.header.joined(separator: "\t")))
        #expect(lines[1].split(separator: "\t", omittingEmptySubsequences: false).count == TSVLog.header.count)
        #expect(lines[1].contains("\t\(Self.sessionID)\t"))
        #expect(warnings.all.isEmpty)

        let missing = directory.appending(path: "missing/runs.tsv")
        _ = try await DevinKick.scripted(transport, warnings: warnings, environment: ["KICK_LOG_TSV": missing.path]).save(Self.sessionID)
        #expect(warnings.all.count == 1)
        #expect(warnings.all.first?.contains("KICK_LOG_TSV") == true)
    }

    /// A save without output removes an earlier result.json rather than leaving it to read as
    /// the current result (PR #11 review, r4308714874).
    @Test func aSaveWithoutOutputRemovesTheStaleResult() async throws {
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID, detail: "waiting_for_user", output: Self.finalOutput)),
                            .json(Fixture.session(id: Self.sessionID, detail: "working"))],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
        ])
        let kick = try DevinKick.scripted(transport)
        let first = try await kick.save(Self.sessionID)
        let result = first.run.directory.appending(path: "result.json")
        #expect(FileManager.default.fileExists(atPath: result.path))
        _ = try await kick.save(first.run.runID)
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    /// A repeat download replaces the saved copy only once the new one is in place, and a failed
    /// install leaves the old copy (PR #11 review, r4308714933).
    @Test func anAttachmentIsReplacedAtomically() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "report.txt")
        try Data("old".utf8).write(to: destination)
        let fresh = directory.appending(path: "download.tmp")
        try Data("new".utf8).write(to: fresh)
        try DevinKick.move(fresh, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        // A download that vanished can't be installed: the saved copy stays, and nothing is left behind.
        #expect(throws: KickError.self) { try DevinKick.move(directory.appending(path: "missing.tmp"), to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["report.txt"])
    }

    /// The download follows only https into the service's own domains (PR #11 review,
    /// r4308715368, and its edit: a public-looking name can resolve to an internal address).
    @Test(arguments: [
        ("https://devin-public-attachments.s3.dualstack.us-west-2.amazonaws.com/a/b?X-Amz-Signature=x", true),
        ("https://proxy.devin.ai/attachments/x", true),
        ("http://devin-public-attachments.s3.amazonaws.com/a", false),
        ("https://169.254.169.254/latest/meta-data", false),
        ("https://[fd00::1]/x", false),
        ("https://localhost/x", false),
        ("https://rebind.example.com/x", false),
        ("https://evil-amazonaws.com/x", false),
        ("https://amazonaws.com.evil.net/x", false),
    ])
    func onlyHTTPSHostNamesAreFollowed(_ location: String, follows: Bool) throws {
        #expect(StripAuthorizationOnRedirect.mayFollow(try #require(URL(string: location))) == follows)
    }

    @Test func aRedirectToAnInternalAddressFailsTheDownload() async throws {
        let api = "api-\(UUID().uuidString.lowercased()).test"
        RedirectingURLProtocol.routes.withLock {
            $0[api] = .init(location: URL(string: "https://169.254.169.254/latest/meta-data"))
        }
        let transport = ScriptedTransport([:])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_SERVER_URL": "https://\(api)"])
        let attachment = SessionAttachment(id: Self.attachmentID, name: "notes.txt", url: "https://app.devin.ai/x", source: "devin", contentType: nil)
        await #expect {
            try await kick.download(attachment, to: temporaryDirectory().appending(path: "notes.txt"))
        } throws: { error in
            (error as? KickError)?.localizedDescription.contains("only https into amazonaws.com or devin.ai is followed") == true
        }
        #expect(RedirectingURLProtocol.requests(to: "169.254.169.254").isEmpty)
    }

    @Test func saveRecreatesADeletedRunDirectory() async throws {
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID))],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
        ])
        let kick = try DevinKick.scripted(transport)
        let first = try await kick.save(Self.sessionID)
        try FileManager.default.removeItem(at: first.run.directory)
        let second = try await kick.save(first.run.runID)
        #expect(second.run.directory == first.run.directory)
        #expect(FileManager.default.fileExists(atPath: first.run.directory.appending(path: "session.json").path))
    }

    /// The listing or a download can fail: the rest is saved, and the failure only warns.
    @Test func aFailedAttachmentListingOnlyWarns() async throws {
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.sessionID))],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.response(status: 403, body: Fixture.problem(status: 403, detail: "forbidden"))],
        ])
        let warnings = WarningLog()
        let saved = try await DevinKick.scripted(transport, warnings: warnings).save(Self.sessionID)
        #expect(saved.files.count == 2)
        #expect(warnings.all.count == 1)
    }

    @Test func aRunWithoutASessionCannotBeSaved() async throws {
        // Its tag is checked first; nothing carries it.
        let kick = try DevinKick.scripted(ScriptedTransport(["get_sessions": [.json(Fixture.page([]))]]))
        let orphan = RunState(runID: "20261018-120000-0001", directory: temporaryDirectory(), mode: nil, title: nil, tags: [], resumable: true)
        try await kick.store.append(IndexEvent(.requested, run: orphan))
        await #expect { try await kick.save(orphan.runID) } throws: { ($0 as? KickError)?.exitCode == 64 }
    }
}
