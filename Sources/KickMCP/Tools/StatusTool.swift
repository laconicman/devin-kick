import DevinKickKit
import MCP

extension ToolSpec {
    struct StatusInput: Decodable, Sendable {
        var ids: StringList?
        var tag: String?
    }

    /// `kick_status`: one read of each session, returned at once.
    static let status = ToolSpec(
        name: "kick_status",
        title: "Check Devin sessions",
        description: """
        Show where sessions stand, one line each: id, state (done, working, needs-input, unknown, \
        failed), Devin's status/detail, kick's reading of the output (final, stale-final, \
        provisional, none, unmarked), age, mode and title; a working session adds its latest \
        message's first line. Then the overall state and the next step. It reads once and returns \
        at once: to wait for sessions to settle, call kick_wait. Name sessions by run id, session \
        id or run directory, or give a tag.
        """,
        schema: InputSchema.object([
            "ids": InputSchema.list("Run ids, session ids or run directories."),
            "tag": InputSchema.string("Also every session on the server carrying this tag."),
        ]),
        annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    ) { (input: StatusInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        let ids = input.ids?.items ?? []
        guard !ids.isEmpty || input.tag != nil else {
            throw .usage("Name sessions in ids (run ids, session ids or run directories), or give a tag.")
        }
        return await .readings(try await kick.status(ids, tag: input.tag), kick: kick)
    }
}

extension ToolReply {
    /// The most a status reply waits for its working sessions' latest messages: a nicety, which
    /// must never bring a call near the client's time limit.
    static let latestMessageBudget: Duration = .seconds(10)

    /// `readings` as kick_status and kick_wait show them (plan decision 6): the Kit's status line
    /// for each, a working one with its latest message's first line, never the transcript; then
    /// the batch's overall state and the next step, which the cap never cuts.
    static func readings(_ readings: [Reading], kick: DevinKick) async -> ToolReply {
        let latest = await latestMessages(of: readings, kick: kick)
        let lines = readings.map { reading in
            guard let id = reading.session?.id, let message = latest[id] else { return reading.line() }
            return reading.line() + "  [latest: \(message)]"
        }
        let (label, code) = Reading.overall(readings)
        var overall = "overall: \(label) (status \(code))"
        if readings.count > 1 { overall += " — " + counts(readings) }
        return ToolReply(
            lines: lines, next: overall + "\n" + nextStep(readings),
            rest: "`kick status` with the same ids, in a shell, prints every line"
        )
    }

    /// `done 2, working 1`, in the order the states first appear.
    static func counts(_ readings: [Reading]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for label in readings.map(\.outcome.label) {
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { "\($0) \(counts[$0, default: 0])" }.joined(separator: ", ")
    }

    /// What to do about each state present, the ones that need the model first.
    static func nextStep(_ readings: [Reading]) -> String {
        var asking = false, other = false, unreadable = false, working = false, done = false
        for reading in readings {
            switch reading.outcome {
            case .settled(.needsInput): asking = true
            case .settled(.failed), .settled(.unknown): other = true
            case .unreadable: unreadable = true
            case .settled(.working): working = true
            case .settled(.done): done = true
            }
        }
        var steps: [String] = []
        if asking { steps.append("needs-input asks or awaits an approval: read kick_messages, then answer with kick_reply") }
        if other { steps.append("for failed or unknown, kick_messages shows what Devin said last") }
        if unreadable { steps.append("an error line says what went wrong") }
        if working { steps.append("not settled: call kick_wait again with the working ones") }
        if done { steps.append("kick_save the done ones, then read result.json in each run directory") }
        return "next: " + steps.joined(separator: "; ") + "."
    }

    /// The first line of each working session's latest message, by session id, for as long as
    /// ``latestMessageBudget`` allows; one that can't be read is left out.
    static func latestMessages(of readings: [Reading], kick: DevinKick) async -> [String: String] {
        let ids = readings.compactMap { reading -> String? in
            guard case .settled(.working) = reading.outcome else { return nil }
            return reading.session?.id
        }
        guard !ids.isEmpty else { return [:] }
        enum Arrival: Sendable {
            case message(id: String, line: String)
            case unread
            case timeUp
        }
        return await withTaskGroup(of: Arrival.self) { group in
            for id in ids {
                group.addTask {
                    guard let message = try? await kick.messages(id, last: 1).last else { return .unread }
                    return .message(id: id, line: compact(message))
                }
            }
            group.addTask {
                try? await Task.sleep(for: latestMessageBudget)
                return .timeUp
            }
            var latest: [String: String] = [:]
            var pending = ids.count
            while pending > 0, let arrival = await group.next() {
                switch arrival {
                case .message(let id, let line):
                    latest[id] = line
                    pending -= 1
                case .unread:
                    pending -= 1
                case .timeUp:
                    pending = 0
                }
            }
            group.cancelAll()
            return latest
        }
    }
}
