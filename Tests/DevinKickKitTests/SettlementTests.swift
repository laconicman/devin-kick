import DevinOpenAPI
@testable import DevinKickKit
import Foundation
import Testing

@Suite("Settlement — Devin's status pair → where a caller stands")
struct SettlementTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let status: String
        let detail: String?
        let hasOutput: Bool
        let expected: String
        var testDescription: String { "\(status)/\(detail ?? "nil")\(hasOutput ? "+output" : "") → \(expected)" }
    }

    static let cases: [Case] = [
        // The field's usual done state, and its asking twin.
        .init(status: "running", detail: "waiting_for_user", hasOutput: true, expected: "done"),
        .init(status: "running", detail: "waiting_for_user", hasOutput: false, expected: "needs-input"),
        // An approval is pending even when output exists.
        .init(status: "running", detail: "waiting_for_approval", hasOutput: true, expected: "needs-input"),
        .init(status: "running", detail: "waiting_for_approval", hasOutput: false, expected: "needs-input"),
        .init(status: "running", detail: "working", hasOutput: false, expected: "working"),
        .init(status: "running", detail: nil, hasOutput: false, expected: "working"),
        .init(status: "running", detail: "finished", hasOutput: true, expected: "done"),
        .init(status: "running", detail: "finished", hasOutput: false, expected: "failed"),
        // A finished session left idle sleeps with its output intact: done, not failed.
        .init(status: "suspended", detail: "inactivity", hasOutput: true, expected: "done"),
        .init(status: "suspended", detail: "inactivity", hasOutput: false, expected: "needs-input"),
        // Paused by a person, maybe mid-work: output may be partial (PR #1 review, r4306484713).
        .init(status: "suspended", detail: "user_request", hasOutput: true, expected: "needs-input"),
        .init(status: "suspended", detail: "user_request", hasOutput: false, expected: "needs-input"),
        .init(status: "suspended", detail: "out_of_credits", hasOutput: true, expected: "failed"),
        .init(status: "suspended", detail: "contract_expired", hasOutput: false, expected: "failed"),
        // Ended, maybe interrupted: output can't be told final from partial (r4306484713).
        .init(status: "exit", detail: nil, hasOutput: true, expected: "unknown"),
        .init(status: "exit", detail: nil, hasOutput: false, expected: "failed"),
        .init(status: "error", detail: nil, hasOutput: false, expected: "failed"),
        .init(status: "new", detail: nil, hasOutput: false, expected: "working"),
        .init(status: "claimed", detail: nil, hasOutput: false, expected: "working"),
        .init(status: "resuming", detail: nil, hasOutput: false, expected: "working"),
        // Vocabulary this version doesn't know is surfaced raw, never guessed.
        .init(status: "running", detail: "thinking_harder", hasOutput: false, expected: "unknown"),
        .init(status: "suspended", detail: "solar_flare", hasOutput: true, expected: "unknown"),
        .init(status: "teleported", detail: nil, hasOutput: true, expected: "unknown"),
        // A detail where the vocabulary has none (PR #1 review, r4306484630).
        .init(status: "new", detail: "blocked", hasOutput: false, expected: "unknown"),
        .init(status: "claimed", detail: "queued_behind_quota", hasOutput: false, expected: "unknown"),
        .init(status: "resuming", detail: "blocked", hasOutput: false, expected: "unknown"),
        .init(status: "exit", detail: "terminated_by_admin", hasOutput: true, expected: "unknown"),
    ]

    @Test(arguments: cases)
    func settles(_ c: Case) {
        let settlement = Settlement(status: c.status, detail: c.detail, hasOutput: c.hasOutput)
        #expect(settlement.label == c.expected)
    }

    @Test func exitCodesAreTheDocumentedOnes() {
        #expect(Settlement.done(detail: nil).exitCode == 0)
        #expect(Settlement.needsInput(detail: "waiting_for_user").exitCode == 10)
        #expect(Settlement.unknown(status: "x", detail: nil).exitCode == 11)
        #expect(Settlement.working(detail: nil).exitCode == 75)
        #expect(Settlement.failed(status: "error", detail: nil).exitCode == 1)
    }

    @Test func unknownKeepsTheRawValues() {
        let settlement = Settlement(status: "suspended", detail: "solar_flare", hasOutput: true)
        #expect(settlement == .unknown(status: "suspended", detail: "solar_flare"))
    }

    /// Real session records from field runs (2026-10-14), sanitized: ids, title, tags and the
    /// output replaced. They pin the decoding of the real shape through the generated types.
    @Test(arguments: [
        ("session-waiting-with-output.json", "done"),
        ("session-suspended-inactivity-with-output.json", "done"),
    ])
    func fieldRecordsDecodeAndSettle(fixture: String, expected: String) throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: nil))
        let session = try JSONDecoder().decode(Components.Schemas.SessionResponse.self, from: Data(contentsOf: url))
        let settlement = Settlement(
            status: session.status, detail: session.statusDetail, hasOutput: session.structuredOutput != nil
        )
        #expect(settlement.label == expected)
        #expect(session.devinMode == "swe-2-max")
    }
}
