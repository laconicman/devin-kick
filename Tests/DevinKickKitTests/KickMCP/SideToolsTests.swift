@testable import DevinKickKit
import Foundation
import HTTPTypes
@testable import KickMCP
import MCP
import Testing

@Suite("Side tools — compact lines, the next step, nothing inlined", .temporaryDirectories)
struct SideToolsTests {
    static let finalOutput = #"{"answer_md":"a","doubts":[],"questions_for_user":[],"kick_final":true}"#
    static let idA = "0000000000000000000000000000000a"
    static let idB = "0000000000000000000000000000000b"

    /// A prompt and a file inside the upload roots, and a store, all temporary.
    struct Sandbox {
        let base = temporaryDirectory()
        var prompt: URL { base.appending(path: "prompt.md") }
        var notes: URL { base.appending(path: "notes.txt") }

        init() throws {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try Data("Summarise the notes.\n".utf8).write(to: prompt)
            try Data("hello".utf8).write(to: notes)
        }

        func kick(_ transport: ScriptedTransport, sleeps: SleepRecorder = SleepRecorder(), environment: [String: String] = [:]) throws -> DevinKick {
            try DevinKick.scripted(
                transport, sleeps: sleeps,
                environment: ["KICK_STORE": base.appending(path: "store").path, "KICK_UPLOAD_ROOTS": base.path].merging(environment) { $1 }
            )
        }
    }

    static func toolbox(_ kick: DevinKick, bypassApproval: Bool = true, maxWait: Duration = DevinKick.maximumWait) -> Toolbox {
        Toolbox(
            specs: [
                .upload, .start(bypassApproval: bypassApproval), .status, .wait(maximum: maxWait),
                .save, .messages, .reply, .archive,
            ],
            kick: .success(kick)
        )
    }

    static let schemas = ScriptedTransport.Reply.json(Fixture.schemas(modes: ["swe-2-max", "swe-2-high", "fast"]))

    static func body(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `get_session` answering by the session id in the path: `idA` as `a`, any other as `other`.
    static func bySession(_ a: String, other: String) -> ScriptedTransport.Reply {
        .dynamic { sent in .json((sent.request.path ?? "").contains(idA) ? a : other) }
    }

    // MARK: - kick_upload

    @Test func uploadListsEachFileAndReusesTheCache() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["upload_attachment": [.json(UploadTests.uploaded)]])
        let toolbox = Self.toolbox(try sandbox.kick(transport))
        let first = try await toolbox.reply("kick_upload", ["paths": [.string(sandbox.notes.path)]])
        #expect(!first.isError)
        // Each file is named as resolved, symlinks followed (`/private/var/…`).
        let resolved = try #require(UploadRoots.realPath(sandbox.notes.path))
        #expect(first.text.hasPrefix("\(resolved) → https://app.devin.ai/attachments/"))
        #expect(first.text.contains("(uploaded)\nnext: name these files in attach"))
        let second = try await toolbox.reply("kick_upload", ["paths": .string(sandbox.notes.path)])
        #expect(second.text.contains("(cached)"))
        #expect(await transport.count("upload_attachment") == 1)
    }

    @Test func uploadOutsideTheRootsIsAUsageError() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([:])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_upload", ["paths": ["/etc/hosts"]])
        #expect(isError)
        #expect(text.contains("outside KICK_UPLOAD_ROOTS"))
        #expect(text.hasSuffix("status 64: usage error"))
        #expect(await transport.sent.isEmpty)
    }

    // MARK: - kick_start

    /// One call starts a batch from a file and from inline text, returns at once with each run,
    /// and names the next step with the run ids.
    @Test func startReturnsEachRunAndTheNextStep() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "upload_attachment": [.json(UploadTests.uploaded)],
            "create_session": [.json(Fixture.session())],
        ])
        let kick = try sandbox.kick(transport)
        let (text, isError) = try await Self.toolbox(kick).reply("kick_start", ["sessions": [
            ["prompt_file": .string(sandbox.prompt.path), "title": "from a file", "tags": ["devin-kick-test"]],
            ["prompt": "Inline text, sent as is.\n", "attach": [.string(sandbox.notes.path)], "tags": "devin-kick-test, b"],
        ]])
        #expect(!isError)
        let runs = await kick.store.runs(tagged: "devin-kick-test")
        #expect(runs.count == 2)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines.first == "started 2 of 2:")
        let ids = lines.dropFirst().prefix(2).map { "\"\($0.prefix { $0 != " " })\"" }
        #expect(Set(ids) == Set(runs.map { "\"\($0.runID)\"" }))
        #expect(lines.last == "next: call kick_wait with ids [\(ids.joined(separator: ", "))], and again until every session has settled.")

        let bodies = try await transport.bodies("create_session").map(Self.body)
        #expect(bodies.map { $0["prompt"] as? String } == ["Summarise the notes.\n", "Inline text, sent as is.\n"])
        #expect(bodies.allSatisfy { $0["bypass_approval"] as? Bool == true })
        #expect((bodies[1]["tags"] as? [String])?.prefix(2) == ["devin-kick-test", "b"])
        #expect((bodies[1]["attachment_urls"] as? [String])?.count == 1)
        let inline = try #require(runs.first { $0.title == nil })
        #expect(try Data(contentsOf: inline.directory.appending(path: "prompt.md")) == Data("Inline text, sent as is.\n".utf8))
    }

    /// More than 20 sessions need the operator's confirmation; nothing is sent without it.
    @Test func aBatchOverTheLimitNeedsTheOperator() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["get_automation_schemas": [Self.schemas], "create_session": [.json(Fixture.session())]])
        let toolbox = Self.toolbox(try sandbox.kick(transport))
        let sessions = Value.array(Array(repeating: Value.object(["prompt": "Do nothing."]), count: ToolSpec.startBatchLimit + 1))
        let refused = try await toolbox.reply("kick_start", ["sessions": sessions])
        #expect(refused.isError)
        #expect(refused.text.contains("over the limit of 20"))
        #expect(refused.text.contains("confirmed_by_operator: true"))
        #expect(refused.text.hasSuffix("status 64: usage error"))
        #expect(await transport.sent.isEmpty)

        let confirmed = try await toolbox.reply("kick_start", ["sessions": sessions, "confirmed_by_operator": true])
        #expect(!confirmed.isError)
        #expect(confirmed.text.hasPrefix("started 21 of 21:"))
        #expect(await transport.count("create_session") == 21)
    }

    /// Every session is checked before the first is started: one bad session starts nothing.
    @Test(arguments: [
        (["prompt": "a", "prompt_file": "b"], "sessions[1] (untitled): Give exactly one of prompt_file and prompt."),
        ([:], "sessions[1] (untitled): Give exactly one of prompt_file and prompt."),
        (["prompt": "a", "title": "t", "mode": "swe-3"], "sessions[1] (t): Unknown mode \"swe-3\"."),
        (["prompt": "a", "attach": ["/etc/hosts"]], "outside KICK_UPLOAD_ROOTS"),
    ] as [([String: Value], String)])
    func aBadSessionStartsNothing(_ session: [String: Value], says: String) async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([:])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply(
            "kick_start", ["sessions": [["prompt": "fine"], .object(session)]]
        )
        #expect(isError)
        #expect(text.contains(says), "\(text)")
        #expect(text.contains("Nothing was started."))
        #expect(await transport.sent.isEmpty)
    }

    /// The call's mode overrides every session's, a session's overrides `KICK_MODE`.
    @Test func modesResolveCallThenSessionThenEnvironment() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["get_automation_schemas": [Self.schemas], "create_session": [.json(Fixture.session())]])
        let toolbox = Self.toolbox(try sandbox.kick(transport, environment: ["KICK_MODE": "swe-2-high"]))
        let sessions: Value = [["prompt": "a", "mode": "fast"], ["prompt": "b"]]
        _ = try await toolbox.reply("kick_start", ["sessions": sessions])
        _ = try await toolbox.reply("kick_start", ["sessions": sessions, "mode": "swe-2-max"])
        let modes = try await transport.bodies("create_session").map { try Self.body($0)["devin_mode"] as? String }
        #expect(modes == ["fast", "swe-2-high", "swe-2-max", "swe-2-max"])
    }

    /// A refused create is that session's line; the others start, and the result is no error,
    /// so the model doesn't start the started ones again.
    @Test func oneFailedStartDoesNotStopTheRest() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.response(status: 400, body: Fixture.problem(status: 400, detail: "bad prompt")), .json(Fixture.session())],
        ])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_start", ["sessions": [
            ["prompt": "a", "title": "refused"], ["prompt": "b", "title": "fine"],
        ]])
        #expect(!isError)
        #expect(text.hasPrefix("started 1 of 2:\nsessions[0] (refused): Devin answered 400: bad prompt (status 1: failed)"))
        #expect(text.hasSuffix("The ones that failed did not start: fix them and start them again."))
    }

    /// Untitled inline prompts share a name, so a failed start is named by its index too
    /// (swe-2-max review, 2026-10-19).
    @Test func aFailedStartIsNamedByItsIndex() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.json(Fixture.session()), .response(status: 400, body: Fixture.problem(status: 400, detail: "bad prompt"))],
        ])
        let (text, _) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_start", ["sessions": [["prompt": "a"], ["prompt": "b"]]])
        #expect(text.contains("\nsessions[1] (an inline prompt): Devin answered 400: bad prompt (status 1: failed)\n"))
    }

    /// Bypass is the operator's choice at launch: no argument carries it.
    @Test func bypassIsSetAtLaunchNotByAnArgument() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["get_automation_schemas": [Self.schemas], "create_session": [.json(Fixture.session())]])
        let toolbox = Self.toolbox(try sandbox.kick(transport), bypassApproval: false)
        _ = try await toolbox.reply("kick_start", ["sessions": [["prompt": "a"]]])
        let body = try Self.body(try #require(await transport.bodies("create_session").first))
        #expect(body["bypass_approval"] as? Bool == false)
        let refused = try await toolbox.reply("kick_start", ["sessions": [["prompt": "a"]], "bypass_approval": true])
        #expect(refused.isError)
        #expect(refused.text.contains("Unknown argument bypass_approval"))
    }

    // MARK: - kick_status and kick_wait

    @Test func statusNeedsIdsOrATag() async throws {
        let sandbox = try Sandbox()
        let (text, isError) = try await Self.toolbox(try sandbox.kick(ScriptedTransport([:]))).reply("kick_status")
        #expect(isError)
        #expect(text.hasPrefix("Name sessions in ids"))
    }

    /// One line per session, a working one with its latest message's first line, then the
    /// batch's state and what to do about each part of it.
    @Test func statusShowsEachLineTheOverallStateAndTheNextStep() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_session": [Self.bySession(
                Fixture.session(id: Self.idA, detail: "waiting_for_user", output: Self.finalOutput),
                other: Fixture.session(id: Self.idB, detail: "working")
            )],
            "get_session_messages": [.json(#"{"items":[\#(SaveTests.message(#"Reading the notes\nand more"#, at: 1_791_900_050))],"has_next_page":false}"#)],
        ])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_status", ["ids": [.string(Self.idA), .string(Self.idB)]])
        #expect(!isError)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("\(Self.idA)  done  running/waiting_for_user  final"))
        #expect(lines[1].hasPrefix("\(Self.idB)  working  running/working"))
        #expect(lines[1].hasSuffix("  devin  Reading the notes]"))
        #expect(lines[2] == "overall: working (status 75: still working: poll again) — done 1, working 1")
        #expect(lines[3] == "next: not settled: call kick_wait with the same ids, and again until they settle; kick_save the done ones, then read result.json in each run directory.")
        #expect(await transport.count("get_session_messages") == 1, "only the working session's")
    }

    @Test func aWaitLongerThanTheServersBoundIsRefused() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([:])
        let toolbox = Self.toolbox(try sandbox.kick(transport), maxWait: .seconds(100))
        let (text, isError) = try await toolbox.reply("kick_wait", ["ids": [.string(Self.idA)], "timeout": 120])
        #expect(isError)
        #expect(text.hasPrefix("This server waits at most 100 s per call"))
        #expect(await transport.sent.isEmpty)
        let tool = try #require(toolbox.tools.first { $0.name == "kick_wait" })
        #expect(tool.description?.contains("at most 100 s per call") == true)
    }

    @Test func aWaitReturnsOnceTheSessionsSettle() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["get_session": [
            .json(Fixture.session(id: Self.idA, detail: "working")),
            .json(Fixture.session(id: Self.idA, detail: "waiting_for_user", output: Self.finalOutput)),
        ], "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)]])
        let sleeps = SleepRecorder()
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport, sleeps: sleeps)).reply("kick_wait", ["ids": [.string(Self.idA)]])
        #expect(!isError)
        #expect(text.contains("\noverall: done (status 0: done)\nnext: kick_save the done ones"))
        #expect(sleeps.delays == [.seconds(15)])
    }

    // MARK: - kick_save, kick_messages, kick_reply, kick_archive

    /// Each run directory, its files with their sizes, and the result's keys; never the result.
    @Test func saveNamesTheFilesAndTheResultsShapeNeverTheResult() async throws {
        let sandbox = try Sandbox()
        let output = #"{"answer_md":"the secret answer","doubts":[],"questions_for_user":[],"kick_final":true}"#
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.idA, detail: "waiting_for_user", output: output))],
            "get_session_messages": [.json(#"{"items":[\#(SaveTests.message("hello", at: 1, source: "user"))],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
        ])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_save", ["ids": [.string(Self.idA)]])
        #expect(!isError)
        #expect(!text.contains("secret"))
        let lines = text.split(separator: "\n").map(String.init)
        let fields = try #require(lines.first).components(separatedBy: "  ")
        #expect(fields.dropFirst().prefix(2) == [Self.idA, "done"])
        let directory = try #require(fields.last)
        for name in ["session.json", "result.json", "messages.json"] {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: directory + "/" + name)[.size] as? Int)
            #expect(lines.contains("  \(name)  \(size) B"))
        }
        #expect(lines.contains("  result.json: kick_final true; keys answer_md, doubts, kick_final, questions_for_user"))
        #expect(lines.last == "next: read result.json in each run directory; kick_archive the sessions you are done with.")
    }

    /// One session that can't be saved is its line; the others are saved.
    @Test func aSaveThatFailsForOneSessionSavesTheOthers() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_session": [.dynamic { sent in
                (sent.request.path ?? "").contains(Self.idA)
                    ? .response(status: 404, body: Fixture.problem(status: 404, detail: "not found"))
                    : .json(Fixture.session(id: Self.idB, detail: "waiting_for_user", output: Self.finalOutput))
            }],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
            "get_session_attachments": [.json("[]")],
        ])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_save", ["ids": [.string(Self.idA), .string(Self.idB)]])
        #expect(!isError)
        #expect(text.hasPrefix("\(Self.idA): Devin answered 404: not found"))
        #expect(text.contains("(status 1: failed)\n"))
        #expect(text.contains("  \(Self.idB)  done  "))
    }

    /// The latest messages' first lines, each cut to a quotable length: never a whole message.
    @Test func messagesShowTheLatestFirstLinesOnly() async throws {
        let sandbox = try Sandbox()
        let items = (1...12).map { SaveTests.message(#"message \#($0)\nsecond line"#, at: 1_791_900_000 + $0) }
            + [SaveTests.message(String(repeating: "word ", count: 60), at: 1_791_900_100)]
        let transport = ScriptedTransport(["get_session_messages": [.json(#"{"items":[\#(items.joined(separator: ","))],"has_next_page":false}"#)]])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_messages", ["id": .string(Self.idA)])
        #expect(!isError)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == ToolSpec.messagesShown + 1)
        #expect(lines.first?.hasSuffix("  devin  message 4") == true)
        #expect(!text.contains("second line"))
        #expect(lines[ToolSpec.messagesShown - 1].count == ToolReply.messageLength + 1)
        #expect(lines[ToolSpec.messagesShown - 1].hasSuffix("…"))
    }

    @Test func replyPostsAFileThenShowsTheStatus() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "get_session": [.json(Fixture.session(id: Self.idA, detail: "waiting_for_user"))],
            "post_message": [.json(Fixture.session(id: Self.idA))],
        ])
        let toolbox = Self.toolbox(try sandbox.kick(transport))
        let (text, isError) = try await toolbox.reply("kick_reply", ["id": .string(Self.idA), "file": .string(sandbox.prompt.path)])
        #expect(!isError)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "posted to \(Self.idA)")
        #expect(lines[1].hasPrefix("\(Self.idA)  needs-input  running/waiting_for_user"))
        #expect(lines.last == "next: call kick_wait with ids [\"\(Self.idA)\"], and again until it settles.")
        let body = try Self.body(try #require(await transport.bodies("post_message").first))
        #expect(body["message"] as? String == "Summarise the notes.\n")

        let both = try await toolbox.reply("kick_reply", ["id": .string(Self.idA), "text": "a", "file": "b"])
        #expect(both.isError)
        #expect(both.text.hasPrefix("Give exactly one of text and file."))
    }

    @Test func aReplyToAnEndedSessionIsRefused() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["get_session": [.json(Fixture.session(id: Self.idA, status: "exit", detail: nil))]])
        let (text, isError) = try await Self.toolbox(try sandbox.kick(transport)).reply("kick_reply", ["id": .string(Self.idA), "text": "still there?"])
        #expect(isError)
        #expect(text == "Session \(Self.idA) has ended (exit): a reply can't reach it. Start a new session.\nstatus 1: failed")
        #expect(await transport.count("post_message") == 0)
    }

    /// Archive puts sessions away and never ends one: no argument asks for that.
    @Test func archiveArchivesAndNeverTerminates() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport([
            "archive_session": [.json(Fixture.session(id: Self.idA, status: "running", detail: "waiting_for_user"))],
            "get_session": [.json(Fixture.session(id: Self.idA, status: "suspended", detail: "user_request"))],
        ])
        let toolbox = Self.toolbox(try sandbox.kick(transport))
        let (text, isError) = try await toolbox.reply("kick_archive", ["ids": [.string(Self.idA)]])
        #expect(!isError)
        #expect(text.hasPrefix("\(Self.idA)  archived; reads suspended/user_request now\n"))
        // Read back before it sleeps, a running session says where it is going (the dogfood).
        await transport.script("get_session", [.json(Fixture.session(id: Self.idA, status: "running", detail: nil))])
        let early = try await toolbox.reply("kick_archive", ["ids": [.string(Self.idA)]])
        #expect(early.text.hasPrefix("\(Self.idA)  archived; reads running now, going to sleep\n"))
        let refused = try await toolbox.reply("kick_archive", ["ids": [.string(Self.idA)], "terminate": true])
        #expect(refused.isError)
        #expect(refused.text.contains("Unknown argument terminate"))
        #expect(await transport.count("terminate_session") == 0)
    }
}
