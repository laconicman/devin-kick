public import Foundation

/// Where one session (or a run without one) stands: what `status` and `wait` print, one line
/// each, and what their exit status is computed from.
public struct Reading: Sendable, Equatable {
    /// What the caller named: a session id, a run id or a run directory.
    public var argument: String
    /// The run, if the store knows it.
    public var run: RunState?
    /// The session as last read, if it could be.
    public var session: SessionSnapshot?
    public var verdict: OutputVerdict?
    public var outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case settled(Settlement)
        /// The status couldn't be read.
        case unreadable(KickError)
    }

    /// Whether `wait` stops waiting for this one: anything but working, or an error a retry
    /// wouldn't fix. A 429, a 5xx or no answer inside a wait is transient, never terminal.
    public var isSettled: Bool {
        switch outcome {
        case .settled(.working): false
        case .settled: true
        case .unreadable(let error): !error.isRetryable
        }
    }
}

extension Reading {
    /// Sessions sleep and can be resumed for 14 days, counted from when they went to sleep
    /// (Devin's release note of 2026-10-09; its docs page still says 30), so from `updated_at`.
    public static let resumeWindow: TimeInterval = 14 * 24 * 60 * 60

    /// `id  label  status/detail  verdict  age  mode  title  [flags]`, tab-free and on one line.
    public func line(now: Date = Date()) -> String {
        let id = session?.id ?? run?.sessionID ?? argument
        switch outcome {
        case .unreadable(let error):
            return "\(id)  error  \(Self.oneLine(error.localizedDescription))"
        case .settled(let settlement):
            guard let session else {
                return "\(id)  \(settlement.label)  \(Self.describe(settlement))  \(Self.oneLine(run?.title ?? ""))"
            }
            var fields = [
                id, settlement.label, session.status + (session.statusDetail.map { "/\($0)" } ?? ""),
                verdict?.rawValue ?? "-", Self.age(of: session.createdAt, now: now), DevinMode.label(session.mode),
                Self.oneLine(session.title ?? run?.title ?? ""),
            ]
            if case .unknown(_, let detail?) = settlement, detail != session.statusDetail { fields.append("(\(detail))") }
            fields += flags(now: now)
            return fields.joined(separator: "  ")
        }
    }

    /// Notes for the line: past the resume window, duplicates under the run tag, archived.
    func flags(now: Date) -> [String] {
        var flags: [String] = []
        if let session, session.status == "suspended", now.timeIntervalSince(session.updatedAt) > Self.resumeWindow {
            switch run?.resumable {
            case true?: flags.append("[past the 14-day resume window]")
            case false?: flags.append("[not resumable]")
            case nil: flags.append("[resumable: unknown, past 14 days]")
            }
        }
        if let duplicates = run?.duplicates, !duplicates.isEmpty {
            flags.append("[also under its run tag: \(duplicates.joined(separator: ", "))]")
        }
        if session?.isArchived == true { flags.append("[archived]") }
        return flags
    }

    static func describe(_ settlement: Settlement) -> String {
        switch settlement {
        case .working(let detail), .done(let detail): detail ?? "-"
        case .needsInput(let detail): detail
        case .failed(let status, let detail), .unknown(let status, let detail): status + (detail.map { ": \($0)" } ?? "")
        }
    }

    /// `45s`, `12m`, `3h05m`, `4d`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return String(format: "%dh%02dm", seconds / 3600, seconds % 3600 / 60)
        default: return "\(seconds / 86400)d"
        }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// One exit status for several sessions (Design: "Several sessions, one exit status"): the
    /// most severe reading, ranked failed > unknown > needs input > working > done. The rank is
    /// explicit, because the codes' numeric order (75 above 11) isn't it. A reading that
    /// couldn't be read exits with its error's status when alone, and ranks as unknown in a batch.
    public static func exitCode(_ readings: [Reading]) -> Int32 {
        if readings.count == 1, case .unreadable(let error) = readings[0].outcome { return error.exitCode }
        let worst = readings.map { reading -> Settlement in
            switch reading.outcome {
            case .settled(let settlement): settlement
            case .unreadable: .unknown(status: "unreadable", detail: nil)
            }
        }.max { $0.severity < $1.severity }
        return worst?.exitCode ?? Settlement.done(detail: nil).exitCode
    }
}

extension Settlement {
    /// The rank in an aggregate: higher is worse.
    var severity: Int {
        switch self {
        case .done: 0
        case .working: 1
        case .needsInput: 2
        case .unknown: 3
        case .failed: 4
        }
    }
}
