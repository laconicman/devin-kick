@testable import KickMCP
import MCP

extension CallTool.Result {
    /// The result's text, as a model reads it.
    var text: String {
        content.map { content in
            if case .text(let text, _, _) = content { text } else { "" }
        }.joined()
    }
}

extension Toolbox {
    /// The text of calling `name` with `arguments`, and whether it is an error.
    func reply(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
        let result = try await call(.init(name: name, arguments: arguments))
        return (result.text, result.isError == true)
    }
}
