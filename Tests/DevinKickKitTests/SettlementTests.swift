import DevinOpenAPI
@testable import DevinKickKit
import Foundation
import Testing

@Suite("Settlement — Devin's status pair and an output verdict → where a caller stands")
struct SettlementTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let status: String
        let detail: String?
        let output: OutputVerdict
        let expected: String
        var testDescription: String { "\(status)/\(detail ?? "nil") + \(output.rawValue) → \(expected)" }
    }

    /// One row of the M1 table: a status pair and its reading under each verdict, in the order
    /// final, stale-final, provisional, none, unmarked (unmarked is M0's reading of any output).
    struct Row {
        let status: String
        let detail: String?
        let readings: [String]
    }

    static let verdicts: [OutputVerdict] = [.final, .staleFinal, .provisional, .none, .unmarked]

    static let table: [Row] = [
        // The field's usual done state, and its asking twin.
        .init(status: "running", detail: "waiting_for_user", readings: ["done", "done", "needs-input", "needs-input", "done"]),
        // An approval wait beats any verdict.
        .init(status: "running", detail: "waiting_for_approval", readings: ["needs-input", "needs-input", "needs-input", "needs-input", "needs-input"]),
        .init(status: "running", detail: "working", readings: ["working", "working", "working", "working", "working"]),
        .init(status: "running", detail: nil, readings: ["working", "working", "working", "working", "working"]),
        .init(status: "running", detail: "finished", readings: ["done", "done", "unknown", "failed", "done"]),
        // A finished session left idle sleeps with its output intact: done, not failed.
        .init(status: "suspended", detail: "inactivity", readings: ["done", "done", "needs-input", "needs-input", "done"]),
        // Paused, by kick's own archive or by a person: read as exit is (owner, 2026-10-18).
        // Without kick's field, output may be partial (PR #1 review, r4306484713).
        .init(status: "suspended", detail: "user_request", readings: ["done", "unknown", "needs-input", "needs-input", "needs-input"]),
        .init(status: "suspended", detail: "out_of_credits", readings: ["failed", "failed", "failed", "failed", "failed"]),
        .init(status: "suspended", detail: "contract_expired", readings: ["failed", "failed", "failed", "failed", "failed"]),
        // kick's own field tells a final exit from an interrupted one; a reply since makes it stale.
        .init(status: "exit", detail: nil, readings: ["done", "unknown", "failed", "failed", "unknown"]),
        .init(status: "error", detail: nil, readings: ["failed", "failed", "failed", "failed", "failed"]),
        .init(status: "new", detail: nil, readings: ["working", "working", "working", "working", "working"]),
        .init(status: "claimed", detail: nil, readings: ["working", "working", "working", "working", "working"]),
        .init(status: "resuming", detail: nil, readings: ["working", "working", "working", "working", "working"]),
        // Vocabulary this version doesn't know is surfaced raw, never guessed.
        .init(status: "running", detail: "thinking_harder", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        .init(status: "suspended", detail: "solar_flare", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        .init(status: "teleported", detail: nil, readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        // A detail where the vocabulary has none (PR #1 review, r4306484630).
        .init(status: "new", detail: "blocked", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        .init(status: "claimed", detail: "queued_behind_quota", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        .init(status: "resuming", detail: "blocked", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
        .init(status: "exit", detail: "terminated_by_admin", readings: ["unknown", "unknown", "unknown", "unknown", "unknown"]),
    ]

    static let cases: [Case] = table.flatMap { row in
        zip(verdicts, row.readings).map { Case(status: row.status, detail: row.detail, output: $0, expected: $1) }
    }

    @Test(arguments: cases)
    func settles(_ c: Case) {
        let settlement = Settlement(status: c.status, detail: c.detail, output: c.output)
        #expect(settlement.label == c.expected)
    }

    @Test func everyRowReadsEveryVerdict() {
        #expect(Self.table.allSatisfy { $0.readings.count == Self.verdicts.count })
    }

    @Test func exitCodesAreTheDocumentedOnes() {
        #expect(Settlement.done(detail: nil).exitCode == 0)
        #expect(Settlement.needsInput(detail: "waiting_for_user").exitCode == 10)
        #expect(Settlement.unknown(status: "x", detail: nil).exitCode == 11)
        #expect(Settlement.working(detail: nil).exitCode == 75)
        #expect(Settlement.failed(status: "error", detail: nil).exitCode == 1)
    }

    @Test func unknownKeepsTheRawValues() {
        let settlement = Settlement(status: "suspended", detail: "solar_flare", output: .unmarked)
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
        let output = try session.structuredOutput.map { try JSONEncoder().encode($0) }
        let settlement = Settlement(
            status: session.status, detail: session.statusDetail,
            output: OutputVerdict(output: output, repliedByKick: false)
        )
        #expect(settlement.label == expected)
        #expect(session.devinMode == "swe-2-max")
    }
}
