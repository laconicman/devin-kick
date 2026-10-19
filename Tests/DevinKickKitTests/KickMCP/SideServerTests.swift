import DevinKickKit
@testable import KickMCP
import MCP
import Testing

@Suite("SideServer — the MCP server over the Kit", .temporaryDirectories)
struct SideServerTests {
    /// swift-sdk 0.12.1 runs under Swift 6.4 with this package's upcoming features: a client
    /// initializes against the server in-process, over the SDK's own paired transport.
    @Test func aClientInitializesAgainstTheServer() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = SideServer.makeServer()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "0")
        let result = try await client.connect(transport: clientTransport)
        #expect(result.serverInfo.name == "devin-kick")
        #expect(result.serverInfo.version == DevinKick.version)
        #expect(result.capabilities.tools != nil)
        await client.disconnect()
        await server.stop()
    }
}
