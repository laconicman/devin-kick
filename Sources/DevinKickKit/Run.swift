/// One session `run` saw through: where it ended, what was saved, whether it was archived.
public struct Completed: Sendable, Equatable {
    public var started: StartedRun
    public var reading: Reading
    /// `nil` when the save failed; ``error`` says why.
    public var saved: SavedRun?
    public var error: KickError?
    public var archived: Bool
}

extension DevinKick {
    /// `kick run`'s default budget, three hours (amendment A10).
    public static let defaultRunBudget: Duration = .seconds(3 * 60 * 60)

    /// A budget such as `90s`, `45m`, `3h`, `1h30m`, or plain seconds.
    public static func budget(_ text: String) throws(KickError) -> Duration {
        let units: [Character: Int64] = ["s": 1, "m": 60, "h": 3600]
        if let seconds = Int64(text), seconds > 0 { return .seconds(seconds) }
        var total: Int64 = 0
        var number = ""
        for character in text {
            if character.isNumber {
                number.append(character)
            } else if let unit = units[character], let value = Int64(number) {
                total += value * unit
                number = ""
            } else {
                throw .usage("A budget is a number of seconds, or like 90s, 45m, 3h, 1h30m; not \(text).")
            }
        }
        guard number.isEmpty, total > 0 else {
            throw .usage("A budget is a number of seconds, or like 90s, 45m, 3h, 1h30m; not \(text).")
        }
        return .seconds(total)
    }

    /// Polls `started` until every session settles or `budget` passes (15 s, backing off to
    /// 60 s), then saves each and archives those that are done. A shell has no idle limit, so
    /// this may block for hours; the MCP server never calls it (Design: "Short calls").
    public func run(_ started: [StartedRun], budget: Duration, progress: (@Sendable (Reading) -> Void)? = nil) async -> [Completed] {
        let readings = await poll(started.map(\.run.runID), until: .all, budget: budget, progress: progress)
        var completed: [Completed] = []
        for (run, reading) in zip(started, readings) {
            var result = Completed(started: run, reading: reading, saved: nil, error: nil, archived: false)
            do throws(KickError) {
                let saved = try await save(run.run.runID)
                result.saved = saved
                result.reading = saved.reading
                if case .settled(.done) = saved.reading.outcome {
                    _ = try await archive(run.run.runID)
                    result.archived = true
                }
            } catch {
                result.error = error
            }
            completed.append(result)
        }
        return completed
    }
}
