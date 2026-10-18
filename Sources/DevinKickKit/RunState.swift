public import Foundation

/// One line of the run store's `index.jsonl`: an event in a run's life.
///
/// Every event carries the whole record (run id, session id, mode, title, every tag, the
/// directory, `resumable`), so one line reads on its own and `list --tag` works from the index
/// alone. The fields after ``tags`` belong to particular events.
struct IndexEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// Written before the create POST: the run exists, its session may not yet.
        case requested
        /// The session exists: its id is known (from the create answer, or by run tag).
        case created
        /// kick posted a message to the session.
        case replied
        /// `save` stored the session's state; ``IndexEvent/settlement`` says where it stood.
        case settled
        /// The create was refused, so no session exists for the run.
        case failed
        /// Past the settle window, no session carried the run tag. Not a failure, which only the
        /// server can report: the session may still appear (TD-7), and a direct lookup checks.
        case unfound
        case archived
        case unarchived
    }

    var event: Kind
    var timestamp: Date
    var runID: String
    var sessionID: String?
    var mode: String?
    var title: String?
    var tags: [String]
    var directory: String
    /// As requested at create; `nil` for a session kick didn't create.
    var resumable: Bool?
    var url: String?
    /// `created`: other sessions carrying the same run tag; the run's session is the earliest.
    var duplicates: [String]?
    /// `settled`: the ``Settlement/label`` and the raw status pair.
    var settlement: String?
    var status: String?
    var statusDetail: String?
    /// `settled`: attachment names that were changed to be safe on disk, original → saved.
    var renamed: [String: String]?
    /// `failed`: the server's error code, if any, and the message.
    var errorCode: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case event, tags, mode, title, resumable, url, duplicates, settlement, status, renamed, message
        case timestamp = "ts"
        case runID = "run_id"
        case sessionID = "session_id"
        case directory = "dir"
        case statusDetail = "status_detail"
        case errorCode = "error_code"
    }

    /// The event `kind` for `run`, carrying the run's current record.
    init(_ kind: Kind, run: RunState, at timestamp: Date = Date()) {
        self.event = kind
        self.timestamp = timestamp
        self.runID = run.runID
        self.sessionID = run.sessionID
        self.mode = run.mode
        self.title = run.title
        self.tags = run.tags
        self.directory = run.directory.path
        self.resumable = run.resumable
        self.url = run.url
    }
}

/// What the run store knows about one run, folded from its index events (amendment A19's hub
/// type; deepwiki-mcp's `Answer` doesn't transfer).
public struct RunState: Sendable, Hashable {
    public var runID: String
    public var sessionID: String?
    public var directory: URL
    public var mode: String?
    public var title: String?
    public var tags: [String]
    /// As requested at create; `nil` for a session kick didn't create.
    public var resumable: Bool?
    public var url: String?
    public var requestedAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date
    /// Other sessions found under the run's tag (Design: duplicates are found, not prevented).
    public var duplicates: [String] = []
    /// Whether kick posted a message to the session; ``OutputVerdict/staleFinal`` reads it.
    public var replied = false
    public var archived = false
    /// The ``Settlement/label`` at the last `save`.
    public var lastSettlement: String?
    /// Why the create was refused, when it was.
    public var failure: String?
    /// When a lookup past the settle window last found no session under the run tag.
    public var unfoundAt: Date?

    public init(runID: String, directory: URL, mode: String?, title: String?, tags: [String], resumable: Bool?, at date: Date = Date()) {
        self.runID = runID
        self.directory = directory
        self.mode = mode
        self.title = title
        self.tags = tags
        self.resumable = resumable
        self.updatedAt = date
    }

    /// A run that was requested but has no session and no refusal: its create's answer was
    /// lost, so the session may exist. Every lookup reconciles it by run tag.
    public var isOrphan: Bool { awaitsSession && unfoundAt == nil }

    /// An orphan, or one a lookup past the settle window found no session for: a direct lookup
    /// of the run still checks its tag, a sweep of the store no longer does.
    public var awaitsSession: Bool { requestedAt != nil && sessionID == nil && failure == nil }

    /// The run's own tag, `kick-run-<id>`, sent with the session at create.
    public var runTag: String { RunStore.runTag(runID) }

    init(event: IndexEvent) {
        self.init(
            runID: event.runID, directory: URL(fileURLWithPath: event.directory), mode: event.mode,
            title: event.title, tags: event.tags, resumable: event.resumable, at: event.timestamp
        )
        apply(event)
    }

    mutating func apply(_ event: IndexEvent) {
        sessionID = event.sessionID ?? sessionID
        directory = URL(fileURLWithPath: event.directory)
        mode = event.mode ?? mode
        title = event.title ?? title
        tags = event.tags
        resumable = event.resumable ?? resumable
        url = event.url ?? url
        updatedAt = max(updatedAt, event.timestamp)
        switch event.event {
        case .requested:
            requestedAt = event.timestamp
        case .created:
            createdAt = event.timestamp
            duplicates = event.duplicates ?? duplicates
        case .replied:
            replied = true
        case .settled:
            lastSettlement = event.settlement
        case .failed:
            failure = [event.errorCode, event.message].compactMap(\.self).joined(separator: ": ")
        case .unfound:
            unfoundAt = event.timestamp
        case .archived:
            archived = true
        case .unarchived:
            archived = false
        }
    }
}
