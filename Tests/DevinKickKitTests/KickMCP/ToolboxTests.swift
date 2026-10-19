import DevinKickKit
import Foundation
@testable import KickMCP
import MCP
import Testing

@Suite("Toolbox — one dispatch boundary, one isError funnel, one cap", .temporaryDirectories)
struct ToolboxTests {
    struct EchoInput: Decodable, Sendable {
        var ids: StringList
        var count: Int?
        var fail: String?
        var sleep: Bool?
    }

    /// A tool that echoes its ids, or `count` lines of 100 bytes, or fails, or sleeps, as asked.
    static let echo = ToolSpec(
        name: "kick_echo", title: "Echo", description: "A test tool.",
        schema: InputSchema.object([
            "ids": InputSchema.list("Echoed one per line."),
            "count": InputSchema.integer("Lines of 100 bytes instead.", minimum: 0),
            "fail": InputSchema.string("A transport failure to throw."),
            "sleep": InputSchema.boolean("Sleep until cancelled."),
        ], required: ["ids"]),
        annotations: .init(readOnlyHint: true)
    ) { (input: EchoInput, _: DevinKick) async throws(KickError) -> ToolReply in
        if let fail = input.fail { throw .transport(fail) }
        if input.sleep == true { try? await Task.sleep(for: .seconds(30)) }
        let lines = input.count.map { count in (0..<count).map { String(format: "%04d ", $0) + String(repeating: "x", count: 95) } }
        return ToolReply(lines: lines ?? input.ids.items, next: "next: call kick_echo again", rest: "kick echo in a shell")
    }

    static func toolbox() throws -> Toolbox {
        Toolbox(specs: [echo], kick: .success(try DevinKick.scripted(ScriptedTransport([:]))))
    }

    static func call(_ toolbox: Toolbox, _ arguments: [String: Value]) async throws -> (text: String, isError: Bool) {
        try await toolbox.reply("kick_echo", arguments)
    }

    /// An unknown tool is a protocol error, as the MCP spec (2025-11-25) has it: -32602.
    @Test func anUnknownToolIsAProtocolError() async throws {
        let toolbox = try Self.toolbox()
        await #expect {
            try await toolbox.call(.init(name: "kick_nope"))
        } throws: { error in
            (error as? MCPError)?.code == -32602 && error.localizedDescription.contains("kick_echo")
        }
    }

    @Test(arguments: [
        (["ids": ["a"], "count": "three"], "count has the wrong type"),
        ([:], "ids is missing"),
        (["ids": ["a"], "idz": ["b"]], "Unknown argument idz"),
    ] as [([String: Value], String)])
    func aBadArgumentIsAUsageErrorNamingIt(_ arguments: [String: Value], says: String) async throws {
        let (text, isError) = try await Self.call(try Self.toolbox(), arguments)
        #expect(isError)
        #expect(text.contains(says), "\(text)")
        #expect(text.hasSuffix("status 64: usage error"))
    }

    /// The SDK reads a string argument that is a whole data URL as bytes; passed on, it would be
    /// re-encoded as base64, so it is refused rather than sent rewritten.
    @Test func aStringTheSDKReadsAsADataURLIsRefused() async throws {
        let arguments = try JSONDecoder().decode([String: Value].self, from: Data(#"{"ids": "data: a list, of ids"}"#.utf8))
        guard case .data = arguments["ids"] else {
            Issue.record("this SDK version no longer reads it as a data URL: \(String(describing: arguments["ids"]))")
            return
        }
        let (text, isError) = try await Self.call(try Self.toolbox(), arguments)
        #expect(isError)
        #expect(text.contains("ids reads as a data: URL"))
    }

    @Test(arguments: [["a", " b "] as Value, "a, b,,"])
    func aListIsAnArrayOrOneCommaSeparatedString(_ ids: Value) async throws {
        let (text, isError) = try await Self.call(try Self.toolbox(), ["ids": ids])
        #expect(!isError)
        #expect(text == "a\nb\nnext: call kick_echo again")
    }

    /// A failure renders its message and the status the CLI would exit with, never thrown.
    @Test func aKickErrorCarriesTheStatusTheCLIWouldGive() async throws {
        let (text, isError) = try await Self.call(try Self.toolbox(), ["ids": ["a"], "fail": "reset"])
        #expect(isError)
        #expect(text == "No answer from Devin (reset). Retry; sessions already created are unaffected.\nstatus 69: no answer, or 429 / 5xx: retry")
    }

    /// Without a key the server still starts, and every tool answers the configuration error.
    @Test func withoutAKeyEveryToolAnswersTheConfigurationError() async throws {
        let missing = Result { () throws(KickError) in try Configuration.fromEnvironment([:]) }.map { DevinKick(configuration: $0) }
        let (text, isError) = try await Self.call(Toolbox(specs: [Self.echo], kick: missing), ["ids": ["a"]])
        #expect(isError)
        #expect(text.contains("DEVIN_API_KEY"))
        #expect(text.hasSuffix("status 78: configuration error"))
    }

    /// Over 4 KB a result keeps whole lines, says how many it left out and where they are, and
    /// keeps the next step.
    @Test func aLongResultIsCutAtALineBoundaryAndNamesTheRest() async throws {
        let (text, isError) = try await Self.call(try Self.toolbox(), ["ids": ["a"], "count": 1000])
        #expect(!isError)
        #expect(text.utf8.count <= ResultCap.maximumBytes)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.last == "next: call kick_echo again")
        let note = try #require(lines.dropLast().last)
        let kept = lines.dropLast(2)
        #expect(note == "… \(1000 - kept.count) more lines left out at the 4 KB result cap; the rest: kick echo in a shell")
        #expect(kept.allSatisfy { $0.utf8.count == 100 })
        #expect(kept.count > 30)
    }

    @Test func aSingleLineOverTheCapIsCutWithin() {
        let text = ResultCap.apply(ToolReply(lines: [String(repeating: "é", count: 5000)], next: "next", rest: "elsewhere"))
        #expect(text.utf8.count <= ResultCap.maximumBytes)
        #expect(text.hasSuffix("…\n… the line above was cut at the 4 KB result cap; the rest: elsewhere\nnext"))
    }

    /// A call cancelled while its tool runs throws, so the SDK sends no response (plan decision 9).
    @Test func aCancelledCallThrowsCancellation() async throws {
        let toolbox = try Self.toolbox()
        let call = Task { try await toolbox.call(.init(name: "kick_echo", arguments: ["ids": ["a"], "sleep": true])) }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
    }
}
