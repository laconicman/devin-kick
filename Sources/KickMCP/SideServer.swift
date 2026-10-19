import DevinKickKit
import MCP

/// The MCP face of `kick`: `kick serve --profile side` runs this server over stdio, on the same
/// ``DevinKick`` façade as the CLI (Design: "One binary, two faces, three layers").
public enum SideServer {
    /// The `serverInfo.name` the server announces: the package's name, distinct from Devin's
    /// official connector, which Claude Desktop would merge with one of the same display name
    /// (Design: "A name distinct from the service").
    public static let name = "devin-kick"

    /// A server that announces tools, versioned as the package is.
    static func makeServer() -> Server {
        Server(name: name, version: DevinKick.version, capabilities: .init(tools: .init(listChanged: false)))
    }
}
