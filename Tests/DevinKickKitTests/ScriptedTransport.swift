@testable import DevinKickKit
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

/// A `ClientTransport` that answers each operation from a script and records what was sent, so
/// the Kit's flows run offline. Adapted from deepwiki-mcp's `ScriptedTransport`
/// (`Tests/DeepWikiKitTests/AskFlowMockTransportTests.swift`), itself from GitLabKit's
/// `MockTransport`; routed by the generated operation id.
actor ScriptedTransport: ClientTransport {
    /// One scripted answer: a response, or an error the transport throws.
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: String = "{}")
        case failure(URLError.Code)

        static func json(_ body: String) -> Reply { .response(status: 200, body: body) }
    }

    /// A request as the transport saw it.
    struct Sent: Sendable {
        var request: HTTPRequest
        var body: Data?
        var operationID: String
    }

    private var scripts: [String: [Reply]]
    private(set) var sent: [Sent] = []

    /// `scripts` maps an operation id to its replies in order; the last one repeats once drained.
    init(_ scripts: [String: [Reply]]) {
        self.scripts = scripts
    }

    func script(_ operationID: String, _ replies: [Reply]) {
        scripts[operationID] = replies
    }

    func count(_ operationID: String) -> Int {
        sent.count(where: { $0.operationID == operationID })
    }

    func bodies(_ operationID: String) -> [Data] {
        sent.filter { $0.operationID == operationID }.compactMap(\.body)
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data: Data?
        if let body { data = try await Data(collecting: body, upTo: 1 << 24) }
        sent.append(Sent(request: request, body: data, operationID: operationID))
        guard var replies = scripts[operationID], !replies.isEmpty else {
            Issue.record("unscripted operation: \(operationID)")
            return (HTTPResponse(status: .notFound), nil)
        }
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        scripts[operationID] = replies
        switch reply {
        case .failure(let code):
            throw URLError(code)
        case .response(let status, let headers, let body):
            var response = HTTPResponse(status: .init(code: status))
            response.headerFields[.contentType] = "application/json"
            for (name, value) in headers {
                if let field = HTTPField.Name(name) { response.headerFields[field] = value }
            }
            return (response, HTTPBody(body))
        }
    }
}

/// Records the delays the Kit asked for instead of sleeping.
actor SleepRecorder {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }

    nonisolated var timing: Timing {
        var timing = Timing()
        timing.sleep = { [self] delay in await self.record(delay) }
        return timing
    }
}

extension DevinKick {
    /// A façade over `transport` with instant, recorded delays and its own temporary store, so
    /// no test writes to the real one.
    static func scripted(
        _ transport: ScriptedTransport,
        sleeps: SleepRecorder = SleepRecorder(),
        warnings: WarningLog = WarningLog(),
        environment: [String: String] = [:]
    ) throws -> DevinKick {
        let configuration = try Configuration.fromEnvironment(
            ["DEVIN_API_KEY": "cog_test", "DEVIN_ORG_ID": "org-test", "KICK_STORE": temporaryDirectory().path]
                .merging(environment) { $1 }
        )
        return DevinKick(configuration: configuration, transport: transport, timing: sleeps.timing, warn: warnings.sink)
    }
}

/// JSON bodies in the shapes the vendored spec documents, with zeroed ids.
enum Fixture {
    static let selfBody = #"{"principal_type":"pat_user","user_id":"u","user_name":"tester","api_key_id":"k","api_key_name":"n"}"#

    /// A `SessionResponse` with the required fields and the ones Settlement reads.
    static func session(
        id: String = "00000000000000000000000000000001",
        status: String = "running",
        detail: String? = "working",
        output: String? = nil,
        tags: [String] = [],
        createdAt: Int = 1_791_900_000,
        updatedAt: Int = 1_791_900_100,
        mode: String? = "swe-2-max"
    ) -> String {
        let tagList = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let detailField = detail.map { #","status_detail":"\#($0)""# } ?? ""
        let outputField = output.map { #","structured_output":\#($0)"# } ?? ""
        let modeField = mode.map { #","devin_mode":"\#($0)""# } ?? ""
        return #"{"session_id":"\#(id)","url":"https://app.devin.ai/sessions/\#(id)","status":"\#(status)","title":"[test] \#(id)","tags":[\#(tagList)],"org_id":"org-test","created_at":\#(createdAt),"updated_at":\#(updatedAt),"acus_consumed":0.0,"pull_requests":[]\#(detailField)\#(outputField)\#(modeField)}"#
    }

    static func problem(status: Int, code: String? = nil, detail: String) -> String {
        let code = code.map { #","error_code":"\#($0)""# } ?? ""
        return #"{"status":\#(status),"title":"t","detail":"\#(detail)"\#(code)}"#
    }
}
