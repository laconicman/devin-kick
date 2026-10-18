/// Where a session stands, as far as a caller deciding "wait, answer, read or give up" is
/// concerned: the one place that reads Devin's `status` / `status_detail` pair.
///
/// This file is the seam deepwiki-mcp kept in `CompletionDetection.swift`. Devin gives an
/// explicit lifecycle, so no stabilization heuristic is needed. Rules from field use are
/// load-bearing:
/// - **Done is usually `waiting_for_user` with a final output**, not `finished`.
/// - **A finished session left idle goes `suspended`/`inactivity`, with its output intact.**
///   So a suspension with a final output is done, not a failure.
/// - **Output alone is not proof of completion** (<doc:TechDebt> TD-4): Devin must provide
///   output before every turn ends, asking turns included. So the status pair is read together
///   with an ``OutputVerdict``: kick's own `kick_final` field, which every schema kick sends
///   carries (``Schema``).
/// - **An approval wait beats any verdict**, and so does a person's pause
///   (`suspended`/`user_request`): a reply is needed either way.
/// - **`exit` with a final output is done**, unless kick replied since (``OutputVerdict/staleFinal``):
///   the session may then have ended mid-turn with the previous turn's declaration in place.
///
/// A session kick didn't create has no `kick_final` (``OutputVerdict/unmarked``) and reads as
/// M0 read any output: done where Devin stopped by itself, never after `exit`.
///
/// A status or detail outside the vocabulary of the spec vendored on 2026-10-15 is reported as
/// ``unknown(status:detail:)`` with its raw values, never guessed as working or done. The spec
/// populates `status_detail` only under `running` and `suspended`, so a detail on any other
/// status is outside it too.
public enum Settlement: Sendable, Hashable {
    /// Devin is working (or the session is starting or resuming). Poll again later.
    case working(detail: String?)
    /// Devin is waiting for a person: a question (`waiting_for_user`), an action approval
    /// (`waiting_for_approval`), or a suspension a reply would resume.
    case needsInput(detail: String)
    /// The task is complete and its structured output is the result.
    case done(detail: String?)
    /// The session ended without a result, or a billing/quota limit stopped it.
    case failed(status: String, detail: String?)
    /// A status or detail this version doesn't know, or an end whose outcome it can't tell
    /// (`exit` with output that may be partial or stale). Shown raw; read it before relying on it.
    case unknown(status: String, detail: String?)

    /// Suspension reasons that are a billing, quota or account limit.
    static let limitSuspensions: Set<String> = [
        "usage_limit_exceeded", "out_of_credits", "out_of_quota", "no_quota_allocation",
        "payment_declined", "org_usage_limit_exceeded", "user_usage_limit_exceeded",
        "total_session_limit_exceeded", "contract_expired", "error",
    ]

    public init(status: String, detail: String?, output: OutputVerdict) {
        switch status {
        case "new", "claimed", "resuming":
            // These carry no detail in the vocabulary; one that appears is surfaced, not assumed.
            self = detail == nil ? .working(detail: nil) : .unknown(status: status, detail: detail)
        case "running":
            switch detail {
            case "working", nil:
                self = .working(detail: detail)
            case "waiting_for_user":
                switch output {
                case .final, .staleFinal, .unmarked: self = .done(detail: detail)
                case .provisional, .none: self = .needsInput(detail: "waiting_for_user")
                }
            case "waiting_for_approval":
                // An action awaits approval even if output exists: nothing is final yet.
                self = .needsInput(detail: "waiting_for_approval")
            case "finished":
                switch output {
                case .final, .staleFinal, .unmarked: self = .done(detail: detail)
                case .provisional: self = .unknown(status: status, detail: "finished with output marked not final")
                case .none: self = .failed(status: status, detail: detail)
                }
            case let other?:
                self = .unknown(status: status, detail: other)
            }
        case "suspended":
            switch detail {
            case "inactivity":
                // Devin stopped by itself and then slept: a final output is the result.
                switch output {
                case .final, .staleFinal, .unmarked: self = .done(detail: "inactivity")
                case .provisional, .none: self = .needsInput(detail: "suspended: inactivity")
                }
            case "user_request":
                // A person paused it, possibly mid-work: a reply resumes it either way.
                self = .needsInput(detail: "suspended: user_request")
            case let reason? where Self.limitSuspensions.contains(reason):
                self = .failed(status: status, detail: reason)
            default:
                self = .unknown(status: status, detail: detail)
            }
        case "exit":
            switch (detail, output) {
            case (nil, .final):
                // kick's own field says the last completed turn was the result.
                self = .done(detail: "exit")
            case (nil, .staleFinal):
                self = .unknown(status: status, detail: "ended after a reply; the final output may predate it")
            case (nil, .unmarked):
                // Ended, possibly interrupted, and no field to tell: the output may be partial.
                self = .unknown(status: status, detail: "ended with output; final or partial cannot be told")
            case (nil, .provisional):
                self = .failed(status: status, detail: "ended with output marked not final")
            case (nil, .none):
                self = .failed(status: status, detail: "ended without output")
            case (let detail?, _):
                self = .unknown(status: status, detail: detail)
            }
        case "error":
            self = .failed(status: status, detail: detail)
        default:
            self = .unknown(status: status, detail: detail)
        }
    }

    /// The `kick status` / `kick wait` exit status, documented in `--help` and the README.
    public var exitCode: Int32 {
        switch self {
        case .done: 0
        case .needsInput: 10
        case .unknown: 11
        case .working: 75   // EX_TEMPFAIL: poll again
        case .failed: 1
        }
    }

    /// One word for a status line.
    public var label: String {
        switch self {
        case .working: "working"
        case .needsInput: "needs-input"
        case .done: "done"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }
}
