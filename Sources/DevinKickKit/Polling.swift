/// How `wait` and `run` pace their polls: 15 s, growing by half each time, to at most 60 s
/// (amendment A10). The mechanics are deepwiki-mcp's `PollingPolicy`
/// (`Sources/DeepWikiKit/DeepWiki.swift`); its constants are not.
struct PollingPolicy: Sendable {
    var initialInterval: Duration = .seconds(15)
    var backoffFactor = 1.5
    var maxInterval: Duration = .seconds(60)

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
    /// inside a wait is transient: the session is polled again.
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
        for argument in arguments {
            let reading = await observe(argument, within: deadline - timing.now())
            progress?(reading)
            readings.append(reading)
        }
        var poll = 1
        while !Self.satisfied(condition, readings) {
            let remaining = deadline - timing.now()
            guard remaining > .zero else { break }
            try? await timing.sleep(min(timing.polling.interval(before: poll), remaining))
            poll += 1
            for index in readings.indices where !readings[index].isSettled {
                let budget = deadline - timing.now()
                guard budget > .zero else { break }
                let reading = await observe(arguments[index], within: budget)
                if reading.outcome.label != readings[index].outcome.label { progress?(reading) }
                readings[index] = reading
            }
        }
        return readings
    }

    static func satisfied(_ condition: WaitCondition, _ readings: [Reading]) -> Bool {
        switch condition {
        case .any: readings.contains(where: \.isSettled)
        case .all: readings.allSatisfy(\.isSettled)
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
                outcome: .unreadable(.transport("no answer within the wait's remaining \(budget.components.seconds) s"))
            )
        }
    }
}
