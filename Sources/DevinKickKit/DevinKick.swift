import DevinOpenAPI
import Foundation
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
    let timing: Timing
    /// The run store at ``Configuration/storeURL``.
    public let store: RunStore

    /// `warn` receives what the Kit reports without failing: a derived file it couldn't write,
    /// a mode the organization may not offer.
    public init(configuration: Configuration, warn: @escaping RunStore.Warn = RunStore.standardError) {
        self.init(configuration: configuration, transport: URLSessionTransport(), warn: warn)
    }

    /// The injection point for tests (`@testable`): a scripted transport and instant delays.
    /// Internal, because a public init taking the generated `Client` or its transport would
    /// break the generated-type boundary (Design: "One binary, two faces, three layers").
    init(
        configuration: Configuration,
        transport: any ClientTransport,
        timing: Timing = .standard,
        warn: @escaping RunStore.Warn = RunStore.standardError
    ) {
        self.configuration = configuration
        self.timing = timing
        self.store = RunStore(root: configuration.storeURL, warn: warn)
        self.client = Client(
            serverURL: configuration.serverURL,
            transport: transport,
            middlewares: [
                HeaderMiddleware(fields: [
                    (.authorization, "Bearer \(configuration.apiKey)"),
                    (.userAgent, "devin-kick/\(Self.version)"),
                ]),
                ProblemMiddleware(),
                RetryMiddleware(policy: timing.retry, sleep: timing.sleep),
            ]
        )
    }

    /// `GET /v3/self`: who the key acts as. It is the one endpoint no permission gates, so it
    /// is the connectivity check.
    public func whoami() async throws(KickError) -> Principal {
        let body = try await call(Operations.GetSelf.id) { try await client.getSelf().ok.body.json }
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
    }

    /// Runs one generated call and maps whatever it throws to a ``KickError``. Error statuses
    /// arrive here as `ProblemMiddleware`'s throws, so `body` reads only `.ok`; a status `.ok`
    /// can't read (a 2xx or 3xx the spec doesn't name) is an unreadable answer.
    func call<Output: Sendable>(
        _ operationID: String,
        _ body: () async throws -> Output
    ) async throws(KickError) -> Output {
        do {
            return try await body()
        } catch let error as ClientError {
            throw KickError(clientError: error)
        } catch {
            throw .decoding("\(operationID): an answer this version can't read (\(error.localizedDescription))")
        }
    }
}

/// The delays the Kit waits, in one value so tests can make them instant.
struct Timing: Sendable {
    var retry = RetryPolicy()
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let standard = Timing()
}

/// Who a key acts as: `principal_type` (`pat_user`, `service_user`, …) and a display name.
public struct Principal: Sendable, Hashable {
    public var type: String
    public var name: String?
    public var orgID: String?
}
