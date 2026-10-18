@testable import DevinKickKit
import Foundation
import Testing

@Suite("Start — modes, manifests, the run tag, and a create whose answer was lost", .temporaryDirectories)
struct StartTests {
    /// A directory with a prompt, a schema and an attachment, and a façade over a temp store.
    struct Sandbox {
        let base = temporaryDirectory()
        /// Line endings, trailing space and non-ASCII text, all to be sent unchanged.
        static let promptText = "Summarise the three linked lectures.\r\nКратко, по-русски.  \n\tEnd.\n"

        var prompt: URL { base.appending(path: "prompt.md") }

        init() throws {
            try FileManager.default.createDirectory(at: base.appending(path: "prompts"), withIntermediateDirectories: true)
            try Data(Self.promptText.utf8).write(to: prompt)
            try Data("Second prompt".utf8).write(to: base.appending(path: "prompts/second.md"))
            try Data(#"{"type":"object","properties":{"verdict":{"type":"string"}},"required":["verdict"]}"#.utf8)
                .write(to: base.appending(path: "schema.json"))
        }

        func kick(_ transport: ScriptedTransport, sleeps: SleepRecorder = SleepRecorder(), warnings: WarningLog = WarningLog(), environment: [String: String] = [:]) throws -> DevinKick {
            try DevinKick.scripted(
                transport, sleeps: sleeps, warnings: warnings,
                environment: ["KICK_STORE": base.appending(path: "store").path, "KICK_UPLOAD_ROOTS": base.path].merging(environment) { $1 }
            )
        }

        func request(_ kick: DevinKick, options: StartOptions = StartOptions(tags: ["devin-kick-test"])) throws -> SessionRequest {
            try kick.prepare(promptFile: prompt.path, title: "[test] start", schemaFile: nil, attach: [], options: options)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    static let schemas: ScriptedTransport.Reply = .json(Fixture.schemas(modes: ["swe-2-max", "swe-2-high"]))

    /// A listing that answers with one session carrying the tag it was asked for.
    static func echoing(id: String = "00000000000000000000000000000009", createdAt: Int = 1_791_900_000) -> ScriptedTransport.Reply {
        .dynamic { sent in .json(Fixture.page([Fixture.session(id: id, tags: Fixture.queriedTags(sent), createdAt: createdAt)])) }
    }

    static func body(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aStartSendsThePromptByteForByteAndRecordsAtSubmit() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.json(Fixture.session())],
        ])
        let kick = try sandbox.kick(transport)
        let started = try await kick.start(try sandbox.request(kick))

        let sent = try Self.body(try #require(await transport.bodies("create_session").first))
        #expect(sent["prompt"] as? String == Sandbox.promptText)
        #expect(sent["devin_mode"] as? String == "swe-2-max")
        #expect(sent["bypass_approval"] as? Bool == true)
        #expect(sent["resumable"] as? Bool == true)
        #expect(sent["structured_output_required"] == nil, "left at the server's default")
        #expect(sent["tags"] as? [String] == ["devin-kick-test", "kick", started.run.runTag])
        let schema = try #require(sent["structured_output_schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains(Schema.finalField) == true)

        #expect(started.sessionID == "00000000000000000000000000000001")
        #expect(started.run.sessionID == started.sessionID)
        let files = try FileManager.default.contentsOfDirectory(atPath: started.run.directory.path)
        #expect(Set(files) == ["request.json", "session.json"])
        let record = try Self.body(Data(contentsOf: started.run.directory.appending(path: "request.json")))
        #expect((record["body"] as? [String: Any])?["prompt"] as? String == Sandbox.promptText)
        #expect(record["prompt_file"] as? String == sandbox.prompt.path)

        let index = try String(contentsOf: kick.store.indexURL, encoding: .utf8).split(separator: "\n")
        #expect(index.count == 2)
        #expect(index.first?.contains(#""event":"requested""#) == true)
        #expect(index.last?.contains(#""event":"created""#) == true)
    }

    /// The request is on disk before the POST: a create that never answers leaves an orphan
    /// with its request, never nothing.
    @Test func aLostAnswerIsFoundByRunTagWithoutCreatingAgain() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.failure(.networkConnectionLost)],
            "get_sessions": [Self.echoing()],
        ])
        let sleeps = SleepRecorder()
        let kick = try sandbox.kick(transport, sleeps: sleeps)
        let started = try await kick.start(try sandbox.request(kick))
        #expect(started.sessionID == "00000000000000000000000000000009")
        #expect(await transport.count("create_session") == 1)
        #expect(sleeps.delays.isEmpty, "found on the first listing: no settle")
    }

    @Test func anEmptyListingCountsOnlyAfterTheSettleThenTheCreateIsRetried() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.response(status: 502), .json(Fixture.session(id: "00000000000000000000000000000002"))],
            "get_sessions": [.json(Fixture.page([]))],
        ])
        let sleeps = SleepRecorder()
        let kick = try sandbox.kick(transport, sleeps: sleeps)
        let started = try await kick.start(try sandbox.request(kick))
        #expect(started.sessionID == "00000000000000000000000000000002")
        #expect(await transport.count("create_session") == 2)
        // Two listings around the settle, then one after the retry to catch a late duplicate.
        #expect(await transport.count("get_sessions") == 3)
        #expect(sleeps.delays.first == .seconds(15))
    }

    @Test func theEarliestOfTwoSessionsUnderOneRunTagIsTheRun() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.failure(.timedOut)],
            "get_sessions": [.dynamic { sent in
                let tags = Fixture.queriedTags(sent)
                return .json(Fixture.page([
                    Fixture.session(id: "00000000000000000000000000000004", tags: tags, createdAt: 1_791_900_200),
                    Fixture.session(id: "00000000000000000000000000000003", tags: tags, createdAt: 1_791_900_100),
                ]))
            }],
        ])
        let kick = try sandbox.kick(transport)
        let started = try await kick.start(try sandbox.request(kick))
        #expect(started.sessionID == "00000000000000000000000000000003")
        #expect(started.run.duplicates == ["00000000000000000000000000000004"])
        #expect(await kick.store.lookup(started.run.runID)?.duplicates == ["00000000000000000000000000000004"])
    }

    /// A refusal (here 422) and an exhausted 429 mean no session exists: the run records its
    /// failure, is no orphan, and nothing is listed or created again.
    @Test(arguments: [422, 429])
    func aRefusedCreateIsRecordedAsFailed(_ status: Int) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.response(status: status, body: Fixture.problem(status: status, code: "bad_request", detail: "no"))],
        ])
        let kick = try sandbox.kick(transport)
        await #expect(throws: KickError.server(status: status, code: "bad_request", detail: "no")) {
            try await kick.start(try sandbox.request(kick))
        }
        let run = try #require(await kick.store.runs(tagged: "kick").first)
        #expect(!run.isOrphan)
        #expect(run.failure?.contains("bad_request") == true)
        #expect(await transport.count("get_sessions") == 0)
        #expect(await transport.count("create_session") == (status == 429 ? 5 : 1))
    }

    /// A refused create whose failure can't be recorded surfaces as the store error, quoting
    /// the refusal, rather than leaving a phantom orphan behind (PR #11 review, r4308714989).
    @Test func aRefusalThatCantBeRecordedIsAStoreError() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let store = sandbox.base.appending(path: "store")
        let index = store.appending(path: "index.jsonl")
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            // By the time the refusal arrives, the index can't be written to.
            "create_session": [.dynamic { _ in
                try? FileManager.default.removeItem(at: index)
                try? FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
                return .response(status: 422, body: Fixture.problem(status: 422, code: "bad_mode", detail: "no such mode"))
            }],
        ])
        let kick = try sandbox.kick(transport)
        await #expect {
            try await kick.start(try sandbox.request(kick))
        } throws: { error in
            let error = error as? KickError
            return error?.exitCode == 73 && error?.localizedDescription.contains("bad_mode: no such mode") == true
        }
    }

    @Test func aListingThatFailsLeavesAnOrphanAndCreatesNothingMore() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.failure(.networkConnectionLost)],
            "get_sessions": [.response(status: 403, body: Fixture.problem(status: 403, detail: "forbidden"))],
        ])
        let kick = try sandbox.kick(transport)
        await #expect(throws: KickError.self) { try await kick.start(try sandbox.request(kick)) }
        #expect(await transport.count("create_session") == 1)
        #expect(await kick.store.runs(tagged: "kick").first?.isOrphan == true)
    }

    /// The caller is cancelled while the POST is in flight: the shield lets it finish and be
    /// recorded.
    @Test func theShieldRecordsTheCreateWhenTheCallerIsCancelled() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([
            "get_automation_schemas": [Self.schemas],
            "create_session": [.delayed(.milliseconds(300), .json(Fixture.session()))],
        ])
        let kick = try sandbox.kick(transport)
        let request = try sandbox.request(kick)
        let caller = Task { try await kick.start(request) }
        while await transport.count("create_session") == 0 { try await Task.sleep(for: .milliseconds(5)) }
        caller.cancel()
        _ = await caller.result
        let run = try #require(await RunStore(root: kick.store.root).runs(tagged: "kick").first)
        #expect(run.sessionID == "00000000000000000000000000000001")
    }

    /// An empty listing past the settle window can't prove a create failed (TD-7): the run is
    /// recorded as unfound, reads unknown, drops out of the sweep, and a direct lookup still
    /// finds a session listed late.
    @Test func anOrphanIsReconciledAtLookupOrMarkedUnfoundAfterTheSettle() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["get_sessions": [Self.echoing(), .json(Fixture.page([]))]])
        let kick = try sandbox.kick(transport)
        let store = kick.store
        for runID in ["20261018-120000-0001", "20261018-120000-0002"] {
            let run = RunState(runID: runID, directory: sandbox.base, mode: nil, title: nil, tags: [RunStore.runTag(runID)], resumable: true)
            try await store.append(IndexEvent(.requested, run: run, at: Date(timeIntervalSinceNow: -60)))
        }
        await kick.reconcileOrphans()
        let runs = await store.runs(tagged: nil)
        #expect(runs.filter { $0.sessionID != nil }.count == 1)
        let unfound = try #require(runs.first { $0.unfoundAt != nil })
        #expect(unfound.failure == nil)
        #expect(!unfound.isOrphan && unfound.awaitsSession)
        #expect(DevinKick.reading(unfound.runID, unstartedRun: unfound).outcome.label == "unknown")

        let listings = await transport.count("get_sessions")
        await kick.reconcileOrphans()
        #expect(await transport.count("get_sessions") == listings, "a sweep skips an unfound run")

        await transport.script("get_sessions", [Self.echoing(id: "00000000000000000000000000000005")])
        await transport.script("get_session", [.json(Fixture.session(id: "00000000000000000000000000000005"))])
        let late = await kick.observe(unfound.runID)
        #expect(late.session?.id == "00000000000000000000000000000005")
        #expect(await store.lookup(unfound.runID)?.sessionID == "00000000000000000000000000000005")
    }

    // MARK: - Modes

    struct ModeCase: Sendable, CustomTestStringConvertible {
        let flag: String?, entry: String?, environment: String?, expected: String
        var testDescription: String { "flag \(flag ?? "-") entry \(entry ?? "-") env \(environment ?? "-") → \(expected)" }
    }

    @Test(arguments: [
        ModeCase(flag: "swe-2-high", entry: "fast", environment: "lite", expected: "swe-2-high"),
        ModeCase(flag: nil, entry: "fast", environment: "lite", expected: "fast"),
        ModeCase(flag: nil, entry: nil, environment: "lite", expected: "lite"),
        ModeCase(flag: nil, entry: nil, environment: nil, expected: "swe-2-max"),
    ])
    func modesResolveFlagThenEntryThenEnvironment(_ c: ModeCase) throws {
        let mode = DevinMode.resolve(
            flag: try c.flag.map(DevinMode.init), entry: try c.entry.map(DevinMode.init),
            environment: try c.environment.map(DevinMode.init)
        )
        #expect(mode.rawValue == c.expected)
    }

    @Test func aBadModeFailsFastListingTheModes() {
        #expect {
            try DevinMode("swe-3")
        } throws: { error in
            let message = (error as? KickError)?.localizedDescription ?? ""
            return (error as? KickError)?.exitCode == 64 && DevinMode.known.allSatisfy(message.contains)
        }
        #expect(throws: KickError.self) { try Configuration.fromEnvironment(["DEVIN_API_KEY": "cog_x", "KICK_MODE": "swe-3"]) }
    }

    /// The list is documented for automations, so a miss, an absent list, a refusal and an
    /// answer the closed schema can't decode (TD-8: a key the spec doesn't list) all warn.
    @Test(arguments: [
        ScriptedTransport.Reply.json(Fixture.schemas(modes: ["normal"])),
        .json(Fixture.schemas(modes: nil)),
        .response(status: 403, body: Fixture.problem(status: 403, detail: "forbidden")),
        .json(#"{"update_semantics":"merge_patch","sources":{},"available_devin_modes":["swe-2-max"],"preflight_available":true}"#),
    ])
    func availableModesOnlyWarn(_ reply: ScriptedTransport.Reply) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["get_automation_schemas": [reply], "create_session": [.json(Fixture.session())]])
        let warnings = WarningLog()
        let kick = try sandbox.kick(transport, warnings: warnings)
        _ = try await kick.start(try sandbox.request(kick))
        _ = try await kick.start(try sandbox.request(kick))
        #expect(warnings.all.count == 1, "once per process: \(warnings.all)")
        #expect(await transport.count("get_automation_schemas") == 1)
        #expect(await transport.count("create_session") == 2)
    }

    // MARK: - Manifests

    static func manifest(_ sandbox: Sandbox, _ json: String) throws -> Manifest {
        let file = sandbox.base.appending(path: "batch.json")
        try Data(json.utf8).write(to: file)
        return try Manifest.load(file)
    }

    @Test func aManifestMixesModesAndResolvesPathsAgainstItsDirectory() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["get_automation_schemas": [Self.schemas], "create_session": [.json(Fixture.session())]])
        let kick = try sandbox.kick(transport, environment: ["KICK_MODE": "swe-2-high"])
        let manifest = try Self.manifest(sandbox, """
        [{"prompt_file": "prompt.md", "title": "one", "mode": "swe-2-max", "tags": ["a"]},
         {"prompt_file": "prompts/second.md", "title": "two", "schema_file": "schema.json"}]
        """)
        let requests = try kick.prepare(manifest: manifest, options: StartOptions())
        #expect(requests.map(\.mode.rawValue) == ["swe-2-max", "swe-2-high"])
        #expect(requests.map(\.tags) == [["a"], []])
        #expect(requests[1].prompt == "Second prompt")
        for request in requests { _ = try await kick.start(request) }
        let modes = try await transport.bodies("create_session").map { try Self.body($0)["devin_mode"] as? String }
        #expect(modes == ["swe-2-max", "swe-2-high"])
        // The flag is an explicit override for the whole batch.
        #expect(try kick.prepare(manifest: manifest, options: StartOptions(mode: try DevinMode("fast"))).map(\.mode.rawValue) == ["fast", "fast"])
    }

    @Test(arguments: [
        (#"[{"prompt_file": "prompt.md", "title": "ok"}, {"prompt_file": "prompt.md", "title": "bad", "mode": "swe-3"}]"#, "entry 2"),
        (#"[{"prompt_file": "missing.md", "title": "gone"}]"#, "entry 1"),
        (#"[{"prompt_file": "prompt.md", "title": "far", "attach": ["/etc/hosts"]}]"#, "KICK_UPLOAD_ROOTS"),
    ])
    func aManifestIsValidatedBeforeTheFirstPost(_ json: String, mentions: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport([:])
        let kick = try sandbox.kick(transport)
        let manifest = try Self.manifest(sandbox, json)
        #expect {
            try kick.prepare(manifest: manifest, options: StartOptions())
        } throws: { error in
            (error as? KickError)?.exitCode == 64 && (error as? KickError)?.localizedDescription.contains(mentions) == true
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test(arguments: [
        (#"[{"title": "no prompt"}]"#, "[0].prompt_file is missing"),
        (#"{"prompt_file": "p.md"}"#, "the root has the wrong type"),
        (#"[]"#, "no entries"),
        ("not json", "not JSON"),
    ])
    func manifestErrorsNameWhatIsWrong(_ json: String, says: String) throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        #expect {
            try Self.manifest(sandbox, json)
        } throws: { error in
            (error as? KickError)?.localizedDescription.contains(says) == true
        }
    }
}
