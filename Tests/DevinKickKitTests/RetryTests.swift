import DevinOpenAPI
@testable import DevinKickKit
import Foundation
import Testing

@Suite("Retries — transport errors, 429 and 5xx, by idempotency; error statuses read once")
struct RetryTests {
    /// Whether `delay` is `seconds` within the policy's ±20 % jitter.
    static func isBackoff(_ delay: Duration, around seconds: Double) -> Bool {
        delay >= .seconds(seconds * 0.8) && delay <= .seconds(seconds * 1.2)
    }

    static let sessionID = "00000000000000000000000000000001"

    static func getSession(_ kick: DevinKick) async throws(KickError) -> String {
        try await kick.call("get_session") {
            try await kick.client.getSession(path: .init(orgId: "org-test", devinId: sessionID)).ok.body.json.status
        }
    }

    static func postMessage(_ kick: DevinKick) async throws(KickError) -> String {
        try await kick.call("post_message") {
            try await kick.client.postMessage(
                path: .init(orgId: "org-test", devinId: sessionID),
                body: .json(.init(message: "hi"))
            ).ok.body.json.status
        }
    }

    @Test func a429ThenOKRetriesOnceAfterTheBackoff() async throws {
        let transport = ScriptedTransport(["get_self": [
            .response(status: 429, body: Fixture.problem(status: 429, detail: "slow down")), .json(Fixture.selfBody),
        ]])
        let sleeps = SleepRecorder()
        let principal = try await DevinKick.scripted(transport, sleeps: sleeps).whoami()
        #expect(principal.type == "pat_user")
        #expect(await transport.count("get_self") == 2)
        let delays = await sleeps.delays
        #expect(delays.count == 1)
        #expect(delays.allSatisfy { Self.isBackoff($0, around: 1) })
    }

    @Test(arguments: ["3", "Sun, 06 Nov 1994 08:49:37 GMT"])
    func retryAfterIsHonored(_ value: String) async throws {
        let transport = ScriptedTransport(["get_self": [
            .response(status: 429, headers: ["Retry-After": value]), .json(Fixture.selfBody),
        ]])
        let sleeps = SleepRecorder()
        _ = try await DevinKick.scripted(transport, sleeps: sleeps).whoami()
        // A date in the past asks for no wait at all.
        #expect(await sleeps.delays == [value == "3" ? .seconds(3) : .zero])
    }

    /// Longer than 60 s is surfaced as the 429 it is, so the caller retries later.
    @Test func aRetryAfterOverTheCapSurfacesThe429() async throws {
        let transport = ScriptedTransport(["get_self": [
            .response(status: 429, headers: ["Retry-After": "120"], body: Fixture.problem(status: 429, detail: "slow down")),
        ]])
        let sleeps = SleepRecorder()
        await #expect(throws: KickError.server(status: 429, code: nil, detail: "slow down")) {
            try await DevinKick.scripted(transport, sleeps: sleeps).whoami()
        }
        #expect(await transport.count("get_self") == 1)
        #expect(await sleeps.delays.isEmpty)
    }

    @Test func exhausted5xxRetriesFourTimesAndSurfacesAsRetryable() async throws {
        let transport = ScriptedTransport(["get_self": [.response(status: 503, body: "<html>Service Unavailable</html>")]])
        let sleeps = SleepRecorder()
        let kick = try DevinKick.scripted(transport, sleeps: sleeps)
        do {
            _ = try await kick.whoami()
            Issue.record("expected a 503")
        } catch {
            #expect(error == .server(status: 503, code: nil, detail: "no detail"))
            #expect(error.exitCode == 69)
        }
        #expect(await transport.count("get_self") == 5)
        let delays = await sleeps.delays
        #expect(delays.count == 4)
        #expect(zip(delays, [1.0, 2, 4, 8]).allSatisfy { Self.isBackoff($0, around: $1) })
    }

    /// A create, a post or an upload could act twice: a 5xx is never retried blindly.
    @Test func aPostIsNotRetriedOn5xx() async throws {
        let transport = ScriptedTransport(["post_message": [.response(status: 502)]])
        await #expect(throws: KickError.self) { try await Self.postMessage(try DevinKick.scripted(transport)) }
        #expect(await transport.count("post_message") == 1)
    }

    @Test func aDroppedConnectionRetriesAGetButNotAPost() async throws {
        let transport = ScriptedTransport([
            "get_session": [.failure(.networkConnectionLost), .json(Fixture.session())],
            "post_message": [.failure(.networkConnectionLost)],
        ])
        let kick = try DevinKick.scripted(transport)
        #expect(try await Self.getSession(kick) == "running")
        #expect(await transport.count("get_session") == 2)
        await #expect {
            try await Self.postMessage(kick)
        } throws: { error in
            (error as? KickError)?.exitCode == 69
        }
        #expect(await transport.count("post_message") == 1)
    }

    /// Where the request provably never left, a repeat can't act twice.
    @Test(arguments: [URLError.Code.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet])
    func anUnsentPostRetries(_ code: URLError.Code) async throws {
        let transport = ScriptedTransport(["post_message": [.failure(code), .json(Fixture.session())]])
        #expect(try await Self.postMessage(try DevinKick.scripted(transport)) == "running")
        #expect(await transport.count("post_message") == 2)
    }

    @Test(arguments: ["create_session", "post_message", "upload_attachment", "append_session_tags"])
    func nonIdempotentOperationsRetryOnlyUnsentAnd429(_ operationID: String) {
        let retryClass = RetryClass(operationID: operationID)
        #expect(retryClass == .unsentOnly)
        #expect(retryClass.retries(status: 429))
        #expect(!retryClass.retries(status: 500))
    }

    @Test func aProblemDetailIsQuotedAsCodeAndDetail() async throws {
        let transport = ScriptedTransport(["get_session": [
            .response(status: 404, body: Fixture.problem(status: 404, code: "session_not_found", detail: "No such session")),
        ]])
        await #expect(throws: KickError.server(status: 404, code: "session_not_found", detail: "No such session")) {
            try await Self.getSession(try DevinKick.scripted(transport))
        }
        #expect(await transport.count("get_session") == 1)
    }

    /// FastAPI's validation shape: `detail` is a list of `{loc, msg}`.
    @Test func validationIssuesAreQuotedWithTheirLocation() {
        let body = #"{"detail":[{"loc":["body","devin_mode"],"msg":"Input should be 'swe-2-max'","type":"enum"},{"loc":["body",0],"msg":"second"}]}"#
        let problem = ProblemMiddleware.problem(status: 422, body: Data(body.utf8))
        #expect(problem.detail == "body.devin_mode: Input should be 'swe-2-max'; body.0: second")
    }
}
