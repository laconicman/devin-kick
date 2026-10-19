@testable import DevinKickKit
import Foundation
@testable import KickMCP
import MCP
import Testing

/// The side profile against Devin itself: one small public job driven only through the MCP
/// tools, over the SDK's own client in-process. The session is tagged `devin-kick-test`, and
/// ended and archived on the way out. Off by default; run with
/// `KICK_LIVE=1 swift test --filter LiveServer`, with `DEVIN_API_KEY` and `DEVIN_ORG_ID` exported.
@Suite("LiveServer", .enabled(if: ProcessInfo.processInfo.environment["KICK_LIVE"] == "1"), .timeLimit(.minutes(15)), .temporaryDirectories)
struct LiveServerTests {
    let kick: DevinKick

    init() throws {
        var configuration = try Configuration.fromEnvironment()
        configuration.storeURL = temporaryDirectory().appending(path: "store")
        configuration.logTSV = nil
        kick = DevinKick(configuration: configuration)
    }

    /// Calls `name` and checks the two bounds the milestone is done by: a result within the cap,
    /// and a call far from Claude Code's 300 s idle limit.
    func call(_ client: Client, _ name: String, _ arguments: [String: Value]) async throws -> String {
        let started = ContinuousClock.now
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        let took = ContinuousClock.now - started
        let text = CallTool.Result(content: content).text
        print("LiveServer: \(name) took \(took), \(text.utf8.count) bytes")
        #expect(isError != true, "\(name): \(text)")
        #expect(text.utf8.count <= ResultCap.maximumBytes)
        #expect(took < DevinKick.maximumWait + .seconds(30))
        return text
    }

    @Test func aSmallJobRunsThroughTheTools() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await SideServer.makeServer(Toolbox(specs: SideProfile.tools(ServeOptions()), kick: .success(kick)))
        try await server.start(transport: serverTransport)
        let client = Client(name: "devin-kick-live", version: DevinKick.version)
        try await client.connect(transport: clientTransport)

        let started = try await call(client, "kick_start", [
            "sessions": [[
                "prompt": .string(LiveSessionTests.preamble + "What is 17 multiplied by 23? Put the number in answer_md, leave doubts and questions_for_user empty, set kick_final to true, and stop."),
                "title": "[\(LiveSessionTests.testTag)] M2 live server",
                "tags": [.string(LiveSessionTests.testTag)],
            ]],
            "resumable": false,
        ])
        let runID = try #require(started.split(separator: "\n").dropFirst().first?.split(separator: " ").first.map(String.init))
        let run = try #require(await kick.store.lookup(runID))
        let sessionID = try #require(run.sessionID)
        defer { await kick.retire(sessionID) }

        // Three bounded waits of 240 s each fit the suite's time limit; M1's job took 42 s.
        var status = ""
        for _ in 0..<3 where !status.contains("\noverall: done") {
            status = try await call(client, "kick_wait", ["ids": [.string(runID)]])
        }
        #expect(status.contains("\noverall: done (status 0: done)"), "\(status)")

        let saved = try await call(client, "kick_save", ["ids": [.string(runID)]])
        #expect(saved.contains("result.json: kick_final true"))
        let result = try Data(contentsOf: run.directory.appending(path: "result.json"))
        let answer = try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])["answer_md"] as? String
        #expect(answer?.contains("391") == true)

        _ = try await call(client, "kick_messages", ["id": .string(runID)])
        let archived = try await call(client, "kick_archive", ["ids": [.string(runID)]])
        #expect(archived.contains("  archived; reads "))
        await client.disconnect()
        await server.stop()
    }
}
