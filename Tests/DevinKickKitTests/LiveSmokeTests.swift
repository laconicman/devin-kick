import DevinOpenAPI
@testable import DevinKickKit
import Foundation
import Testing

/// The contract tests: real calls against Devin's API, the first thing to fail when the contract
/// drifts. Off by default; run with `KICK_LIVE=1 swift test --filter LiveSmoke`, with
/// `DEVIN_API_KEY` and `DEVIN_ORG_ID` exported. They read only; they create no session.
@Suite("LiveSmoke", .enabled(if: ProcessInfo.processInfo.environment["KICK_LIVE"] == "1"), .temporaryDirectories)
struct LiveSmokeTests {
    let kick: DevinKick

    init() throws {
        kick = DevinKick(configuration: try Configuration.fromEnvironment())
    }

    @Test func selfAnswersWithAPrincipalType() async throws {
        let principal = try await kick.whoami()
        #expect(!principal.type.isEmpty)
    }

    /// Amendment A5: the list endpoint's required `qs` object parameter has no declared style.
    /// The generator sends it form-exploded (`first=5&tags=…`). This asserts the server honors
    /// that: the call succeeds, and every session returned carries the tag asked for.
    @Test func sessionsFilterByTagThroughTheQsObject() async throws {
        let tag = ProcessInfo.processInfo.environment["KICK_LIVE_TAG"] ?? "devin-kick"
        let output = try await kick.client.getSessions(
            path: .init(orgId: try kick.configuration.requireOrgID()),
            query: .init(qs: .init(first: 5, tags: [tag]))
        )
        let page = try output.ok.body.json
        #expect(!page.items.isEmpty, "no session tagged \(tag); set KICK_LIVE_TAG to one that exists")
        for session in page.items {
            #expect(session.tags.contains(tag), "\(session.sessionId) lacks tag \(tag): the filter was ignored")
        }
    }
}
