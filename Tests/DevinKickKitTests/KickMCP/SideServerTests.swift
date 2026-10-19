@testable import DevinKickKit
import Foundation
import HTTPTypes
@testable import KickMCP
import MCP
import Testing

@Suite("SideServer — the side profile over MCP, in-process", .temporaryDirectories)
struct SideServerTests {
    static let idA = "0000000000000000000000000000000a"
    static let idB = "0000000000000000000000000000000b"

    /// M3's main profile (amendment A17), which shares no name with the side profile.
    static let mainProfileNames: Set<String> = ["kick_delegate", "kick_check", "kick_answer", "kick_result", "kick_list"]

    /// The plan's table: read-only, destructive, idempotent, open world.
    static let annotations: [String: [Bool]] = [
        "kick_upload": [false, false, true, true],
        "kick_start": [false, false, false, true],
        "kick_status": [true, false, true, true],
        "kick_wait": [true, false, true, true],
        "kick_save": [false, false, true, true],
        "kick_messages": [true, false, true, true],
        "kick_reply": [false, false, false, true],
        "kick_archive": [false, false, true, true],
    ]

    /// `get_session` for `idA` working after `delay`, for any other done at once.
    static func sessions(working delay: Duration) -> ScriptedTransport {
        ScriptedTransport([
            "get_session": [.dynamic { sent in
                (sent.request.path ?? "").contains(idA)
                    ? .delayed(delay, .json(Fixture.session(id: idA)))
                    : .json(Fixture.session(id: idB, detail: "waiting_for_user", output: SideToolsTests.finalOutput))
            }],
            "get_session_messages": [.json(#"{"items":[],"has_next_page":false}"#)],
        ])
    }

    /// The side server over `kick`, and a client connected to it in-process.
    static func connect(_ kick: Result<DevinKick, KickError>) async throws -> (client: Client, server: Server, initialized: Initialize.Result) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await SideServer.makeServer(Toolbox(specs: SideProfile.tools(ServeOptions()), kick: kick))
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "0")
        let initialized = try await client.connect(transport: clientTransport)
        return (client, server, initialized)
    }

    /// Every argument name in `schema`, nested ones included.
    static func argumentNames(_ schema: Value) -> [String] {
        let object = schema.objectValue ?? [:]
        let properties = object["properties"]?.objectValue ?? [:]
        return properties.keys.sorted() + properties.values.flatMap(argumentNames) + (object["items"].map(argumentNames) ?? [])
    }

    /// swift-sdk 0.12.1 runs under Swift 6.4 with this package's upcoming features: a client
    /// initializes against the server in-process.
    @Test func aClientInitializesAgainstTheServer() async throws {
        let (client, server, initialized) = try await Self.connect(.success(try DevinKick.scripted(ScriptedTransport([:]))))
        #expect(initialized.serverInfo.name == "devin-kick")
        #expect(initialized.serverInfo.version == DevinKick.version)
        #expect(initialized.capabilities.tools != nil)
        #expect(initialized.instructions?.contains("kick_wait") == true)
        await client.disconnect()
        await server.stop()
    }

    /// The eight side tools, in order, each with the table's annotations, a title, a description
    /// and a closed schema. None shares a name with M3's main profile, no argument reaches
    /// bypass, terminate, the ACU limit or the store, and an unknown tool is a protocol error.
    @Test func theSideProfileListsItsEightTools() async throws {
        let (client, server, _) = try await Self.connect(.success(try DevinKick.scripted(ScriptedTransport([:]))))
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == ["kick_upload", "kick_start", "kick_status", "kick_wait", "kick_save", "kick_messages", "kick_reply", "kick_archive"])
        #expect(Set(tools.map(\.name)).isDisjoint(with: Self.mainProfileNames))
        for tool in tools {
            let hints = [tool.annotations.readOnlyHint, tool.annotations.destructiveHint, tool.annotations.idempotentHint, tool.annotations.openWorldHint]
            #expect(hints == Self.annotations[tool.name]?.map(Optional.some), "\(tool.name)")
            #expect(tool.title?.isEmpty == false && tool.description?.isEmpty == false, "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == false, "\(tool.name)")
        }
        let names = Set(tools.flatMap { Self.argumentNames($0.inputSchema) })
        #expect(names.allSatisfy { name in !["bypass", "terminat", "acu"].contains { name.contains($0) } }, "\(names)")
        #expect(names.isDisjoint(with: ["out", "store"]))
        await #expect {
            let _: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: "kick_nope")
        } throws: { error in
            (error as? MCPError)?.code == -32602
        }
        await client.disconnect()
        await server.stop()
    }

    /// Without a key the server starts anyway, and every tool answers the configuration error,
    /// so the model can tell the user what to set (plan decision 10).
    @Test func withoutAKeyTheServerStartsAndToolsAnswerStatus78() async throws {
        let missing = Result { () throws(KickError) in try Configuration.fromEnvironment([:]) }.map { DevinKick(configuration: $0) }
        let (client, server, _) = try await Self.connect(missing)
        let result: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: "kick_status", arguments: ["ids": ["x"]])
        #expect(result.isError == true)
        #expect(CallTool.Result(content: result.content).text.hasSuffix("status 78: configuration error"))
        await client.disconnect()
        await server.stop()
    }

    /// The SDK runs each request in its own task: a status answers while a wait still waits.
    @Test(.timeLimit(.minutes(1)))
    func aStatusAnswersWhileAWaitWaits() async throws {
        let (client, server, _) = try await Self.connect(.success(try DevinKick.scripted(Self.sessions(working: .seconds(3)))))
        let started = ContinuousClock.now
        async let waited: (content: [Tool.Content], isError: Bool?) = client.callTool(name: "kick_wait", arguments: ["ids": [.string(Self.idA)], "timeout": 4])
        try await Task.sleep(for: .milliseconds(100))
        let status: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: "kick_status", arguments: ["ids": [.string(Self.idB)]])
        let statusTook = ContinuousClock.now - started
        let wait = try await waited
        let waitTook = ContinuousClock.now - started
        #expect(status.isError == false)
        #expect(wait.isError == false)
        #expect(statusTook < .milliseconds(1500))
        // A 4 s timeout waits 2 s for the sessions and keeps the rest for their latest messages.
        #expect(waitTook >= .milliseconds(1900))
        await client.disconnect()
        await server.stop()
    }

    /// A cancelled kick_wait gets no response at all (plan decision 9): the Kit stops polling,
    /// and the funnel throws CancellationError, on which the SDK sends nothing. The SDK's client
    /// drops a late response itself, so a raw peer reads every frame the server sends.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledWaitGetsNoResponse() async throws {
        let transport = Self.sessions(working: .milliseconds(300))
        let (peer, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await SideServer.makeServer(Toolbox(specs: SideProfile.tools(ServeOptions()), kick: .success(try DevinKick.scripted(transport))))
        try await server.start(transport: serverTransport)
        try await peer.connect()
        let frames = FrameLog()
        let stream = await peer.receive()
        let reader = Task {
            for try await frame in stream { await frames.append(frame) }
        }

        try await peer.send(Data(#"{"jsonrpc":"2.0","id":"wait-1","method":"tools/call","params":{"name":"kick_wait","arguments":{"ids":["\#(Self.idA)"]}}}"#.utf8))
        while await transport.count("get_session") == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await peer.send(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"wait-1","reason":"test"}}"#.utf8))
        try await peer.send(Data(#"{"jsonrpc":"2.0","id":"status-2","method":"tools/call","params":{"name":"kick_status","arguments":{"ids":["\#(Self.idB)"]}}}"#.utf8))
        while await !frames.ids.contains("status-2") { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await frames.ids == ["status-2"])

        reader.cancel()
        await server.stop()
    }
}

/// The frames a raw peer received from the server.
actor FrameLog {
    private var frames: [Data] = []

    func append(_ frame: Data) {
        frames.append(frame)
    }

    /// The JSON-RPC ids of the frames, in order.
    var ids: [String] {
        frames.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String }
    }
}
