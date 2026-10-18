/// Where a session stands, as far as a caller deciding "wait, answer, read or give up" is
/// concerned: the one place that reads Devin's `status` / `status_detail` pair.
///
/// This file is the seam deepwiki-mcp kept in `CompletionDetection.swift`. Devin gives an
/// explicit lifecycle, so no stabilization heuristic is needed. Three rules from field use are
/// load-bearing:
/// - **Done is usually `waiting_for_user` with output set**, not `finished`.
/// - **A finished session left idle goes `suspended`/`inactivity`, with its output intact.**
///   So a suspension with output is done, not a failure.
/// - **Every session carries a schema** (Design: "Every session carries a schema"). So waiting
///   *without* output always means Devin is asking.
///
/// A status or detail outside the vocabulary of the spec vendored on 2026-10-15 is reported as
/// ``unknown(status:detail:)`` with its raw values, never guessed as working or done. The spec
/// populates `status_detail` only under `running` and `suspended`, so a detail on any other
/// status is outside it too.
///
/// **Output is not proof of completion** (<doc:TechDebt> TD-4): a session can report output
/// while still working. So output reads as done only where Devin stopped by itself
/// (`waiting_for_user`, `finished`, an idle sleep). A session that was ended (`exit`) or paused
/// by a person (`suspended`/`user_request`) can hold partial output, and is never called done.
public enum Settlement: Sendable, Hashable {
    /// Devin is working (or the session is starting or resuming). Poll again later.
    case working(detail: String?)
    /// Devin is waiting for a person: a question (`waiting_for_user`), an action approval
    /// (`waiting_for_approval`), or a suspension a reply would resume.
    case needsInput(detail: String)
    /// The task is complete and its structured output is set.
    case done(detail: String?)
    /// The session ended without a result, or a billing/quota limit stopped it.
    case failed(status: String, detail: String?)
    /// A status or detail this version doesn't know, or an end whose outcome it can't tell
    /// (`exit` with output that may be partial). Shown raw; read it before relying on it.
    case unknown(status: String, detail: String?)

    /// Suspension reasons that are a billing, quota or account limit.
    static let limitSuspensions: Set<String> = [
        "usage_limit_exceeded", "out_of_credits", "out_of_quota", "no_quota_allocation",
        "payment_declined", "org_usage_limit_exceeded", "user_usage_limit_exceeded",
        "total_session_limit_exceeded", "contract_expired", "error",
    ]

    public init(status: String, detail: String?, hasOutput: Bool) {
        switch status {
        case "new", "claimed", "resuming":
            // These carry no detail in the vocabulary; one that appears is surfaced, not assumed.
            self = detail == nil ? .working(detail: nil) : .unknown(status: status, detail: detail)
        case "running":
            switch detail {
            case "working", nil:
                self = .working(detail: detail)
            case "waiting_for_user":
                self = hasOutput ? .done(detail: detail) : .needsInput(detail: "waiting_for_user")
            case "waiting_for_approval":
                // An action awaits approval even if output exists: nothing is final yet.
                self = .needsInput(detail: "waiting_for_approval")
            case "finished":
                self = hasOutput ? .done(detail: detail) : .failed(status: status, detail: detail)
            case let other?:
                self = .unknown(status: status, detail: other)
            }
        case "suspended":
            switch detail {
            case "inactivity":
                // Devin stopped by itself and then slept: its output is the result.
                self = hasOutput ? .done(detail: "inactivity") : .needsInput(detail: "suspended: inactivity")
            case "user_request":
                // A person paused it, possibly mid-work: a reply resumes it either way.
                self = .needsInput(detail: "suspended: user_request")
            case let reason? where Self.limitSuspensions.contains(reason):
                self = .failed(status: status, detail: reason)
            default:
                self = .unknown(status: status, detail: detail)
            }
        case "exit":
            switch (detail, hasOutput) {
            case (nil, false):
                self = .failed(status: status, detail: "ended without output")
            case (nil, true):
                // Ended, possibly interrupted: the output may be partial (TD-4).
                self = .unknown(status: status, detail: "ended with output; final or partial cannot be told")
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
