@testable import DevinKickKit
import Foundation
import HTTPTypes
import Testing

@Suite("Status and wait — one line per session, a bounded wait, one exit status")
struct StatusTests {
    static let finalOutput = #"{"answer_md":"a","doubts":[],"questions_for_user":[],"kick_final":true}"#
    static let idA = "0000000000000000000000000000000a"
    static let idB = "0000000000000000000000000000000b"

    static func reading(_ settlement: Settlement) -> Reading {
        Reading(argument: "x", run: nil, session: nil, verdict: nil, outcome: .settled(settlement))
    }

    static func unreadable(_ error: KickError) -> Reading {
        Reading(argument: "x", run: nil, session: nil, verdict: nil, outcome: .unreadable(error))
    }

    static let done = reading(.done(detail: nil))
    static let working = reading(.working(detail: nil))
    static let asking = reading(.needsInput(detail: "waiting_for_user"))
    static let unknown = reading(.unknown(status: "x", detail: nil))
    static let failed = reading(.failed(status: "error", detail: nil))

    /// failed > unknown > needs input > working > done: an explicit rank, not numeric order.
    static let aggregates: [([Reading], Int32)] = [
        ([done], 0),
        ([done, working], 75),
        ([working, asking, done], 10),
        ([asking, unknown], 11),
        ([unknown, failed, working], 1),
        ([unreadable(.server(status: 404, code: nil, detail: "x"))], 1),
        ([unreadable(.transport("x"))], 69),
        // In a batch, a reading that couldn't be read ranks as unknown.
        ([done, unreadable(.server(status: 404, code: nil, detail: "x"))], 11),
        ([failed, unreadable(.transport("x"))], 1),
    ]

    @Test(arguments: aggregates)
    func severalSessionsExitWithTheWorst(_ readings: [Reading], expected: Int32) {
        #expect(Reading.exitCode(readings) == expected)
    }

    static func kick(_ transport: ScriptedTransport, sleeps: SleepRecorder = SleepRecorder()) throws -> DevinKick {
        try DevinKick.scripted(transport, sleeps: sleeps)
    }

    @Test func aLineCarriesTheStatusTheVerdictAndTheMode() async throws {
        let transport = ScriptedTransport(["get_session": [.json(Fixture.session(
            id: Self.idA, status: "running", detail: "waiting_for_user", output: Self.finalOutput, mode: nil
        ))]])
        let reading = await (try Self.kick(transport)).observe(Self.idA)
        let line = reading.line(now: Date(timeIntervalSince1970: 1_791_900_000 + 3_900))
        #expect(line.hasPrefix("\(Self.idA)  done  running/waiting_for_user  final  1h05m  preview/other  [test] \(Self.idA)"))
        #expect(!line.contains("\t") && !line.contains("\n"))
    }

    /// A reply kick posted makes an old final stale: `exit` then reads unknown.
    @Test func aReplyRecordedInTheStoreMakesAFinalStale() async throws {
        let transport = ScriptedTransport(["get_session": [.json(Fixture.session(id: Self.idA, status: "exit", detail: nil, output: Self.finalOutput))]])
        let kick = try Self.kick(transport)
        var run = RunState(runID: "20261018-120000-0001", directory: temporaryDirectory(), mode: nil, title: nil, tags: [], resumable: true)
        run.sessionID = Self.idA
        try await kick.store.append(IndexEvent(.created, run: run))
        #expect(await kick.observe(Self.idA).outcome == .settled(.done(detail: "exit")))
        try await kick.store.append(IndexEvent(.replied, run: run))
        let reading = await kick.observe("20261018-120000-0001")
        #expect(reading.verdict == .staleFinal)
        #expect(reading.outcome == .settled(.unknown(status: "exit", detail: "ended after a reply; the final output may predate it")))
    }

    @Test func runsWithoutASessionReadAsUnknownOrFailed() async throws {
        let kick = try Self.kick(ScriptedTransport([:]))
        let orphan = RunState(runID: "20261018-120000-0001", directory: temporaryDirectory(), mode: nil, title: nil, tags: [], resumable: true)
        try await kick.store.append(IndexEvent(.requested, run: orphan))
        var refused = IndexEvent(.failed, run: RunState(runID: "20261018-120000-0002", directory: temporaryDirectory(), mode: nil, title: nil, tags: [], resumable: true))
        refused.message = "422: no"
        try await kick.store.append(refused)
        #expect(await kick.observe(orphan.runID).outcome.label == "unknown")
        #expect(await kick.observe("20261018-120000-0002").outcome.label == "failed")
    }

    @Test(arguments: [(true as Bool?, "[past the 14-day resume window]"), (false, "[not resumable]"), (nil, "[resumable: unknown, past 14 days]")])
    func aSleepingSessionPastTheResumeWindowIsFlagged(_ resumable: Bool?, flag: String) async throws {
        let session = Fixture.session(id: Self.idA, status: "suspended", detail: "inactivity", output: Self.finalOutput)
        let kick = try Self.kick(ScriptedTransport(["get_session": [.json(session)]]))
        if let resumable {
            var run = RunState(runID: "20261018-120000-0001", directory: temporaryDirectory(), mode: nil, title: nil, tags: [], resumable: resumable)
            run.sessionID = Self.idA
            try await kick.store.append(IndexEvent(.created, run: run))
        }
        let reading = await kick.observe(Self.idA)
        let fifteenDaysLater = Date(timeIntervalSince1970: 1_791_900_100 + 15 * 86_400)
        #expect(reading.line(now: fifteenDaysLater).hasSuffix(flag))
        #expect(!reading.line(now: Date(timeIntervalSince1970: 1_791_900_100 + 86_400)).contains("resum"))
    }

    // MARK: - Wait

    @Test func waitPollsUntilEverySessionSettles() async throws {
        let transport = ScriptedTransport(["get_session": [
            .json(Fixture.session(id: Self.idA)), .json(Fixture.session(id: Self.idA)),
            .json(Fixture.session(id: Self.idA, detail: "waiting_for_user", output: Self.finalOutput)),
        ]])
        let sleeps = SleepRecorder()
        let readings = try await Self.kick(transport, sleeps: sleeps).wait([Self.idA])
        #expect(readings.map(\.outcome.label) == ["done"])
        #expect(sleeps.delays == [.seconds(15), .seconds(22.5)])
    }

    @Test func waitAnyReturnsAtTheFirstSettledSession() async throws {
        let transport = ScriptedTransport(["get_session": [.dynamic { sent in
            sent.request.path?.contains(Self.idB) == true
                ? .json(Fixture.session(id: Self.idB, detail: "waiting_for_user"))
                : .json(Fixture.session(id: Self.idA))
        }]])
        let readings = try await Self.kick(transport).wait([Self.idA, Self.idB], until: .any)
        #expect(readings.map(\.outcome.label) == ["working", "needs-input"])
        #expect(Reading.exitCode(readings) == 10)
    }

    @Test func waitStopsAtItsTimeoutWithTheSessionStillWorking() async throws {
        let transport = ScriptedTransport(["get_session": [.json(Fixture.session(id: Self.idA))]])
        let sleeps = SleepRecorder()
        let readings = try await Self.kick(transport, sleeps: sleeps).wait([Self.idA], timeout: .seconds(100))
        #expect(Reading.exitCode(readings) == 75)
        #expect(sleeps.delays.reduce(.zero, +) == .seconds(100))
    }

    /// A 5xx is transient inside a wait: polled again, never the result.
    @Test func a5xxInsideAWaitIsPolledAgain() async throws {
        let transport = ScriptedTransport(["get_session": [
            .response(status: 503), .response(status: 503), .response(status: 503), .response(status: 503), .response(status: 503),
            .json(Fixture.session(id: Self.idA, detail: "waiting_for_user", output: Self.finalOutput)),
        ]])
        let readings = try await Self.kick(transport).wait([Self.idA])
        #expect(readings.map(\.outcome.label) == ["done"])
    }

    /// The bound holds against a request that never answers: the GET is raced against the
    /// remaining budget on real time.
    @Test(.timeLimit(.minutes(1)))
    func aHungRequestCannotBreakTheBound() async throws {
        let transport = ScriptedTransport(["get_session": [.delayed(.seconds(30), .json(Fixture.session(id: Self.idA)))]])
        let started = ContinuousClock.now
        let readings = try await Self.kick(transport).wait([Self.idA], timeout: .milliseconds(300))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(readings.first?.outcome.label == "error")
        #expect(Reading.exitCode(readings) == 69)
    }

    @Test(arguments: [Duration.zero, .seconds(241)])
    func aWaitOutsideItsBoundIsAUsageError(_ timeout: Duration) async throws {
        await #expect(throws: KickError.self) { try await Self.kick(ScriptedTransport([:])).wait(["x"], timeout: timeout) }
    }

    @Test func pollingBacksOffFrom15To60Seconds() {
        let policy = PollingPolicy()
        #expect((1...6).map(policy.interval(before:)) == [.seconds(15), .seconds(22.5), .seconds(33.75), .seconds(50.625), .seconds(60), .seconds(60)])
    }
}

extension Reading.Outcome {
    /// The settlement's label, or `error`.
    var label: String {
        switch self {
        case .settled(let settlement): settlement.label
        case .unreadable: "error"
        }
    }
}
