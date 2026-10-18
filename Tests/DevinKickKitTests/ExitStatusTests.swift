@testable import DevinKickKit
import Foundation
import Testing

/// CLAUDE.md rule 2: an exit status lives in Settlement or KickError, the README's table and
/// `kick --help` at once. `--help` prints ``ExitStatus/help``; these hold the rest to it.
@Suite("Exit statuses — one table for the code, --help and the README", .temporaryDirectories)
struct ExitStatusTests {
    static let documented = Set(ExitStatus.rows.map(\.code))

    @Test(arguments: [
        Settlement.done(detail: nil), .needsInput(detail: "x"), .unknown(status: "x", detail: nil),
        .working(detail: nil), .failed(status: "x", detail: nil),
    ])
    func everySettlementStatusIsDocumented(_ settlement: Settlement) {
        #expect(Self.documented.contains(settlement.exitCode))
    }

    @Test(arguments: [
        KickError.config("x"), .usage("x"), .transport("x"), .server(status: 429, code: nil, detail: "x"),
        .server(status: 404, code: nil, detail: "x"), .decoding("x"), .store("x"), .ended(sessionID: "x", status: "exit"),
        .notTerminated(sessionID: "x", status: "running/working"),
    ])
    func everyErrorStatusIsDocumented(_ error: KickError) {
        #expect(Self.documented.contains(error.exitCode))
    }

    @Test func theReadmeTableMatches() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        for row in ExitStatus.rows {
            #expect(text.contains("| \(row.code) | \(row.meaning) |"), "README lacks the row for \(row.code)")
        }
    }

    @Test func helpListsEveryStatus() {
        for row in ExitStatus.rows {
            #expect(ExitStatus.help.contains("\(row.code)") && ExitStatus.help.contains(row.meaning))
        }
    }
}
