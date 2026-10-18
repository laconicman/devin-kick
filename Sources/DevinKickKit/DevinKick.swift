import DevinOpenAPI
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// The façade the CLI and the MCP server share: one place that talks to Devin's v3 API.
///
/// Its public surface uses the Kit's own types, never the generated ones, so the generated
/// target stays an implementation detail (`InternalImportsByDefault` enforces this).
public struct DevinKick: Sendable {
    public static let version = "0.1.0"

    let client: Client
    let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.client = Client(
            serverURL: configuration.serverURL,
            transport: URLSessionTransport(),
            middlewares: [
                HeaderMiddleware(fields: [
                    (.authorization, "Bearer \(configuration.apiKey)"),
                    (.userAgent, "devin-kick/\(Self.version)"),
                ]),
            ]
        )
    }

    /// `GET /v3/self`: who the key acts as. It is the one endpoint no permission gates, so it
    /// is the connectivity check.
    public func whoami() async throws(KickError) -> Principal {
        let output: Operations.GetSelf.Output
        do {
            output = try await client.getSelf()
        } catch {
            throw KickError(clientError: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let body) = ok.body else { throw .decoding("get_self: not JSON") }
            if let pat = body.value2 {
                return Principal(type: pat.principalType.rawValue, name: pat.userName, orgID: pat.orgId)
            }
            if let service = body.value1 {
                return Principal(type: service.principalType.rawValue, name: service.serviceUserName, orgID: service.orgId)
            }
            if let brain = body.value3 {
                return Principal(type: brain.principalType.rawValue, name: nil, orgID: brain.orgId)
            }
            if let windsurf = body.value4 {
                return Principal(type: windsurf.principalType.rawValue, name: windsurf.userName, orgID: windsurf.orgId)
            }
            throw .decoding("get_self: none of the four principal shapes matched")
        case .unauthorized(let response):
            throw KickError(status: 401, problem: try? response.body.json)
        case .forbidden(let response):
            throw KickError(status: 403, problem: try? response.body.json)
        case .notFound(let response):
            throw KickError(status: 404, problem: try? response.body.json)
        case .conflict(let response):
            throw KickError(status: 409, problem: try? response.body.json)
        case .unprocessableContent(let response):
            throw KickError(status: 422, problem: try? response.body.json)
        case .tooManyRequests(let response):
            throw KickError(status: 429, problem: try? response.body.json)
        case .undocumented(let status, _):
            throw .server(status: status, code: nil, detail: "undocumented response")
        }
    }
}

/// Who a key acts as: `principal_type` (`pat_user`, `service_user`, …) and a display name.
public struct Principal: Sendable, Hashable {
    public var type: String
    public var name: String?
    public var orgID: String?
}

extension KickError {
    init(status: Int, problem: Components.Schemas.ProblemDetail?) {
        self = .server(status: status, code: problem?.errorCode, detail: problem?.detail ?? "no detail")
    }
}
