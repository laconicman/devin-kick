import DevinOpenAPI
@testable import DevinKickKit
import Foundation
import Testing

/// Live checks that create sessions: each is tagged `devin-kick-test`, uses only public
/// material, and is ended and archived on the way out. Off by default; run with
/// `KICK_LIVE=1 swift test --filter LiveSession`, with `DEVIN_API_KEY` and `DEVIN_ORG_ID`
/// exported. They answer the M1 plan's open live questions; the answers are in Design and
/// TechDebt.
@Suite("LiveSession", .enabled(if: ProcessInfo.processInfo.environment["KICK_LIVE"] == "1"), .timeLimit(.minutes(15)))
struct LiveSessionTests {
    static let testTag = "devin-kick-test"
    /// Prompts open like this, so a reader of the session knows what it is.
    static let preamble = "This is a test of a client tool, not a real task. Do not browse, do not write code, do not open a repository.\n\n"

    let kick: DevinKick
    let files: URL

    init() throws {
        files = temporaryDirectory()
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var configuration = try Configuration.fromEnvironment()
        configuration.storeURL = files.appending(path: "store")
        configuration.uploadRoots = [files.path]
        kick = DevinKick(configuration: configuration)
    }

    func request(_ prompt: String, title: String, attach: [String] = [], resumable: Bool = false) throws -> SessionRequest {
        let file = files.appending(path: "\(UUID().uuidString).md")
        try Data((Self.preamble + prompt).utf8).write(to: file)
        return try kick.prepare(
            promptFile: file.path, title: "[\(Self.testTag)] \(title)", schemaFile: nil, attach: attach,
            options: StartOptions(tags: [Self.testTag], resumable: resumable)
        )
    }

    /// Ends and archives a session. `archive` reads a terminate back until `exit`, a terminate
    /// sent early can be lost, so it is sent again if needed, and a sleeping session stays
    /// asleep under a terminate: archived, that is as retired as it gets.
    func retire(_ sessionID: String) async {
        for _ in 0..<3 {
            guard let session = try? await kick.archive(sessionID, terminate: true) else { continue }
            if session.status == "exit" || (session.status == "suspended" && session.isArchived == true) { return }
        }
        Issue.record("session \(sessionID) was not retired")
    }

    func settle(_ run: StartedRun, budget: Duration = .seconds(600)) async -> Reading {
        await kick.poll([run.run.runID], until: .all, budget: budget).first
            ?? Reading(argument: run.run.runID, run: nil, session: nil, verdict: nil, outcome: .unreadable(.transport("no reading")))
    }

    /// One small public job through `run`, the first message byte-identical to the prompt file.
    @Test func aSmallJobRunsEndToEnd() async throws {
        let request = try request("What is 17 multiplied by 23? Put the number in answer_md, leave doubts and questions_for_user empty, set kick_final to true, and stop.", title: "M1 live end to end")
        let started = try await kick.start(request)
        defer { await retire(started.sessionID) }

        let completed = try #require(await kick.run([started], budget: .seconds(600)).first)
        #expect(completed.reading.outcome == .settled(.done(detail: "waiting_for_user")))
        #expect(completed.reading.verdict == .final)
        #expect(completed.archived)
        let first = try #require(try await kick.messages(started.sessionID).first)
        #expect(first.source == "user")
        #expect(Data(first.message.utf8) == Data(request.prompt.utf8))
    }

    /// TD-4: an asking turn provides output too, marked not final; after a reply the final is
    /// stale, so `exit` reads unknown; a post's answer carries no output; and the server
    /// refuses a post to an ended session.
    @Test func anAskingSessionMarksItsOutputNotFinal() async throws {
        let started = try await kick.start(try request(
            "Before answering, you must ask me one question: should the answer be in English or in French? Ask it, and wait for my reply. Once I reply, write the word hello in that language in answer_md and stop.",
            title: "M1 live asking session"
        ))
        defer { await retire(started.sessionID) }

        let asking = await settle(started)
        #expect(asking.outcome == .settled(.needsInput(detail: "waiting_for_user")))
        #expect(asking.verdict == .provisional)
        let output = try #require(asking.session?.structuredOutput)
        let object = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(object[Schema.finalField] as? Bool == false)
        #expect((object["questions_for_user"] as? [String])?.isEmpty == false)

        try await kick.reply(started.run.runID, text: "English")
        let answered = await settle(started)
        #expect(answered.outcome == .settled(.done(detail: "waiting_for_user")))
        #expect(answered.verdict == .staleFinal)

        // The post's own answer carries no output (the spec fills it only on get and list).
        let orgID = try kick.configuration.requireOrgID()
        let posted = try await kick.client.postMessage(
            path: .init(orgId: orgID, devinId: started.sessionID),
            body: .json(.init(message: "Thank you, that is all. No further work is needed."))
        ).ok.body.json
        #expect(posted.structuredOutput == nil, "the post's answer carries no output")
        #expect(try await kick.session(started.sessionID).structuredOutput != nil, "while a GET does")

        await retire(started.sessionID)
        #expect(await kick.observe(started.run.runID).outcome == .settled(.unknown(status: "exit", detail: "ended after a reply; the final output may predate it")))
        await #expect(throws: KickError.ended(sessionID: started.sessionID, status: "exit")) {
            try await kick.reply(started.sessionID, text: "Still there?")
        }
        // The server refuses it too, past kick's own check.
        await #expect(throws: KickError.server(status: 400, code: nil, detail: "Session already exited")) {
            try await kick.call("post_message") {
                try await kick.client.postMessage(path: .init(orgId: orgID, devinId: started.sessionID), body: .json(.init(message: "Still there?"))).ok.body.json
            }
        }
    }

    /// A7, corrected: the listing's `attachment_id` is the URL's uuid; the download answers 307
    /// to a presigned host; and kick's delegate takes the key off that hop, which S3 requires
    /// (it answers 400 to a request carrying both).
    @Test func anAttachmentDownloadsWithoutTheKeyOnTheRedirect() async throws {
        let notes = files.appending(path: "notes.txt")
        try Data("line one of a public test attachment\nline two\n".utf8).write(to: notes)
        let started = try await kick.start(try request("Describe the attached file in one sentence, set kick_final to true, and stop.", title: "M1 live attachment", attach: [notes.path]))
        defer { await retire(started.sessionID) }

        let attachment = try #require(try await kick.attachments(started.sessionID).first)
        #expect(attachment.source == "user")
        #expect(attachment.url.contains(attachment.id))
        let download = try await kick.download(attachment, to: files.appending(path: "downloaded.txt"))
        #expect(download.redirected)
        #expect(try Data(contentsOf: download.file) == Data(contentsOf: notes))
        // URLSession itself already drops Authorization on this cross-host redirect (measured
        // 2026-10-18, macOS 26); the delegate keeps it so whatever the OS does.
        #expect(!download.authorizationOffered)
    }

    /// Two sessions under one run tag: the earliest `created_at` is the run's session.
    @Test func twoSessionsUnderOneRunTagResolveToTheEarliest() async throws {
        let runID = await kick.store.newRunID()
        let tags = [RunStore.runTag(runID), Self.testTag]
        let orgID = try kick.configuration.requireOrgID()
        var ids: [String] = []
        for _ in 0..<2 {
            let body = Components.Schemas.SessionCreateRequest(prompt: Self.preamble + "Do nothing and stop.", resumable: false, tags: tags, title: "[\(Self.testTag)] M1 live duplicate")
            ids.append(try await kick.client.createSession(path: .init(orgId: orgID), body: .json(body)).ok.body.json.sessionId)
            try await Task.sleep(for: .seconds(2))
        }
        defer { for id in ids { await retire(id) } }

        let directory = files.appending(path: "duplicate-run")
        let requested = RunState(runID: runID, directory: directory, mode: nil, title: nil, tags: tags, resumable: false)
        try await kick.store.append(IndexEvent(.requested, run: requested))
        let orphan = try #require(await kick.store.lookup(runID))
        #expect(orphan.isOrphan)
        let tagged = try await kick.settledListing(RunStore.runTag(runID))
        #expect(Set(tagged.map(\.id)) == Set(ids))
        let reconciled = try await kick.reconcile(orphan)
        #expect(reconciled.sessionID == tagged.first?.id)
        #expect(reconciled.duplicates.count == 1)
    }
}
