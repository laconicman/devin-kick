import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A client middleware that injects fixed header fields into every request: here the
/// `Authorization: Bearer` credential and an honest `User-Agent`.
///
/// Adapted from deepwiki-mcp's `HeaderMiddleware`, itself from GitLabKit's (laconicman/swift-gitlab).
/// deepwiki-mcp's browser identity presets are deliberately not carried over: they served an
/// anonymous, undocumented API, and this one is official and authenticated.
struct HeaderMiddleware: Sendable {
    private let fields: [(HTTPField.Name, String)]

    init(fields: [(HTTPField.Name, String)]) {
        self.fields = fields
    }
}

extension HeaderMiddleware: ClientMiddleware {
    // `@concurrent` is spelled out: this module enables NonisolatedNonsendingByDefault
    // (SE-0461), under which a bare async closure type means `nonisolated(nonsending)`, while
    // OpenAPIRuntime, compiled without the flag, requires a concurrent `next`. The explicit
    // spelling means the same in both modes.
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for (name, value) in fields {
            request.headerFields[name] = value
        }
        return try await next(request, body, baseURL)
    }
}
