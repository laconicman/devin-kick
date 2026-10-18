/// How `wait` and `run` pace their polls: 15 s, growing by half each time, to at most 60 s
/// (amendment A10). The mechanics are deepwiki-mcp's `PollingPolicy`
/// (`Sources/DeepWikiKit/DeepWiki.swift`); its constants are not.
struct PollingPolicy: Sendable {
    var initialInterval: Duration = .seconds(15)
    var backoffFactor = 1.5
    var maxInterval: Duration = .seconds(60)
    /// Polls in a row that may fail transiently before a session's error stands: one flaky GET
    /// mustn't end a wait, and a failing endpoint mustn't keep a 3 h `run` polling it
    /// (deepwiki-mcp's `maxConsecutivePollFailures`).
    var maxConsecutiveFailures = 3

    /// The interval before poll number `poll` (1-based).
    func interval(before poll: Int) -> Duration {
        var interval = initialInterval
        for _ in 1..<max(poll, 1) {
            interval = min(interval * backoffFactor, maxInterval)
        }
        return interval
    }
}

/// When `wait` returns.
public enum WaitCondition: Sendable {
    /// At the first settled session.
    case any
    /// When every session has settled (the default).
    case all
}

extension DevinKick {
    /// The longest one `wait` call may block: under Claude Code's 300 s idle abort for an MCP
    /// call (Design: "Short calls and handles"), and the same bound on the CLI.
    public static let maximumWait: Duration = .seconds(240)

    /// Polls `arguments` until `condition` holds or `timeout` (at most ``maximumWait``) passes,
    /// and returns the last reading of each, in order.
    ///
    /// Each GET is raced against the remaining budget, so one hung request can't break the
    /// bound; deepwiki-mcp checked its deadline only between polls. A 429, a 5xx or no answer
    /// inside a wait is transient: the session is polled again, up to three polls in a row,
    /// after which its error stands.
    public func wait(_ arguments: [String], until condition: WaitCondition = .all, timeout: Duration = maximumWait) async throws(KickError) -> [Reading] {
        guard timeout > .zero, timeout <= Self.maximumWait else {
            throw .usage("A wait lasts between 1 and \(Self.maximumWait.components.seconds) seconds; call it again to wait longer.")
        }
        return await poll(arguments, until: condition, budget: timeout)
    }

    /// ``wait(_:until:timeout:)`` without its cap, for `run`, which a shell may let block for
    /// hours. `progress` hears each reading whose label changed.
    func poll(
        _ arguments: [String], until condition: WaitCondition, budget: Duration,
        progress: (@Sendable (Reading) -> Void)? = nil
    ) async -> [Reading] {
        let deadline = timing.now() + budget
        var readings: [Reading] = []
        var failures = Array(repeating: 0, count: arguments.count)
        /// Settled, or failed transiently too many polls in a row.
        func done(_ index: Int) -> Bool {
            readings[index].isSettled || failures[index] >= timing.polling.maxConsecutiveFailures
        }
        func record(_ reading: Reading, at index: Int) {
            failures[index] = reading.isSettled || !reading.isUnreadable ? 0 : failures[index] + 1
            readings[index] = reading
        }
        // Each round reads its sessions at once, so one hung GET can't use up the budget of the
        // ones after it (from the 2026-10-18 diff review through kick).
        for (index, reading) in await observe(arguments, at: Array(arguments.indices), until: deadline) {
            progress?(reading)
            readings.append(reading)
            record(reading, at: index)
        }
        var poll = 1
        while !Self.satisfied(condition, readings.indices.map(done)) {
            let remaining = deadline - timing.now()
            guard remaining > .zero else { break }
            try? await timing.sleep(min(timing.polling.interval(before: poll), remaining))
            poll += 1
            guard deadline - timing.now() > .zero else { break }
            let pending = readings.indices.filter { !done($0) }
            for (index, reading) in await observe(arguments, at: pending, until: deadline) {
                if reading.outcome.label != readings[index].outcome.label { progress?(reading) }
                record(reading, at: index)
            }
        }
        return readings
    }

    /// Reads `arguments[indices]` at once, each raced against what is left until `deadline`,
    /// and returns them in `indices`' order.
    func observe(_ arguments: [String], at indices: [Int], until deadline: ContinuousClock.Instant) async -> [(Int, Reading)] {
        let budget = deadline - timing.now()
        let results = await withTaskGroup(of: (Int, Reading).self) { group in
            for index in indices {
                group.addTask { (index, await observe(arguments[index], within: budget)) }
            }
            var results: [Int: Reading] = [:]
            for await (index, reading) in group { results[index] = reading }
            return results
        }
        return indices.compactMap { index in results[index].map { (index, $0) } }
    }

    static func satisfied(_ condition: WaitCondition, _ done: [Bool]) -> Bool {
        switch condition {
        case .any: done.contains(true)
        case .all: done.allSatisfy(\.self)
        }
    }

    /// ``observe(_:)``, unless `budget` runs out first. The race is on real time even where tests
    /// make ``Timing`` virtual, so the bound holds against a request that never answers.
    func observe(_ argument: String, within budget: Duration) async -> Reading {
        await withTaskGroup(of: Reading?.self) { group in
            group.addTask { await observe(argument) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            defer { group.cancelAll() }
            if let first = await group.next() ?? nil { return first }
            return Reading(
                argument: argument, run: await store.lookup(argument), session: nil, verdict: nil,
                outcome: .unreadable(.transport("no answer before the wait ran out"))
            )
        }
    }
}
