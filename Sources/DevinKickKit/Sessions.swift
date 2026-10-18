import DevinOpenAPI
public import Foundation

/// A session as the API last reported it, in the Kit's own terms.
public struct SessionSnapshot: Sendable, Hashable {
    public var id: String
    public var url: String
    public var status: String
    public var statusDetail: String?
    public var title: String?
    public var tags: [String]
    /// The reported `devin_mode`; `nil` for an agent preview (``DevinMode/label(_:)``).
    public var mode: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var acusConsumed: Double
    public var isArchived: Bool?
    /// `structured_output` as JSON, if set. The spec populates it only on get and list.
    public var structuredOutput: Data?

    /// The server's record, for `session.json`.
    let response: Components.Schemas.SessionResponse

    init(_ response: Components.Schemas.SessionResponse) {
        self.response = response
        id = response.sessionId
        url = response.url
        status = response.status
        statusDetail = response.statusDetail
        title = response.title
        tags = response.tags
        mode = response.devinMode
        createdAt = Date(timeIntervalSince1970: TimeInterval(response.createdAt))
        updatedAt = Date(timeIntervalSince1970: TimeInterval(response.updatedAt))
        acusConsumed = response.acusConsumed
        isArchived = response.isArchived
        structuredOutput = response.structuredOutput.flatMap { try? JSONEncoder().encode($0) }
    }

    /// The server's record as pretty-printed JSON.
    var json: Data {
        (try? RunStore.prettyEncoder.encode(response)) ?? Data()
    }
}

extension DevinKick {
    /// The most sessions one listing page asks for (the spec's `SessionsQueryParams.first`).
    static let listPageSize = 200

    /// Every session carrying `tag`, through the `qs` filter object (M0's live test checks the
    /// server honors it), across pages, earliest first.
    func sessions(tagged tag: String) async throws(KickError) -> [SessionSnapshot] {
        try await listSessions(tags: [tag], limit: nil).sorted(by: Self.earliestFirst)
    }

    /// Up to `limit` sessions (all when `nil`), optionally only those with every tag in `tags`.
    func listSessions(tags: [String]?, limit: Int?) async throws(KickError) -> [SessionSnapshot] {
        let orgID = try configuration.requireOrgID()
        var sessions: [SessionSnapshot] = []
        var cursor: String?
        repeat {
            let pageSize = min(Self.listPageSize, limit.map { $0 - sessions.count } ?? Self.listPageSize)
            let page = try await call(Operations.GetSessions.id) {
                try await client.getSessions(
                    path: .init(orgId: orgID),
                    query: .init(qs: .init(after: cursor, first: pageSize, tags: tags))
                ).ok.body.json
            }
            sessions += page.items.map(SessionSnapshot.init)
            cursor = page.hasNextPage == true ? page.endCursor : nil
        } while cursor != nil && limit.map { sessions.count < $0 } ?? true
        return sessions
    }

    /// Two sessions under one run tag: the earliest `created_at` is the run's session, and the
    /// session id breaks a tie, so every reader picks the same one.
    static func earliestFirst(_ a: SessionSnapshot, _ b: SessionSnapshot) -> Bool {
        (a.createdAt, a.id) < (b.createdAt, b.id)
    }

    /// Records `found` (earliest first, non-empty) as run's session: `session.json`, then the
    /// `created` event naming any duplicates.
    func recordCreated(_ run: RunState, sessions found: [SessionSnapshot]) async throws(KickError) -> RunState {
        let ordered = found.sorted(by: Self.earliestFirst)
        guard let session = ordered.first else { return run }
        var run = run
        run.sessionID = session.id
        run.url = session.url
        var event = IndexEvent(.created, run: run)
        let duplicates = ordered.dropFirst().map(\.id)
        if !duplicates.isEmpty { event.duplicates = duplicates }
        await store.writeDerived(session.json, to: run.directory.appending(path: "session.json"))
        do {
            try await store.append(event)
        } catch {
            throw .store("\(error.localizedDescription) Its session exists: \(session.url)")
        }
        run.apply(event)
        return run
    }

    /// Looks for the session of an orphan run (requested, no answer recorded) by its run tag,
    /// and records it if found. An orphan older than the settle window that still has none was
    /// never created: that is recorded as its failure, so it isn't listed again.
    func reconcile(_ run: RunState, now: Date = Date()) async throws(KickError) -> RunState {
        guard run.isOrphan else { return run }
        let found = try await sessions(tagged: run.runTag)
        if !found.isEmpty { return try await recordCreated(run, sessions: found) }
        let settle = TimeInterval(timing.createSettle.components.seconds)
        guard let requestedAt = run.requestedAt, now.timeIntervalSince(requestedAt) > settle else { return run }
        var event = IndexEvent(.failed, run: run)
        event.message = "no session carries its run tag \(run.runTag)"
        try await store.append(event)
        var concluded = run
        concluded.apply(event)
        return concluded
    }

    /// Reconciles every orphan run in the store; called by `status` and `list` (Design). A
    /// listing that fails only warns: the lookup goes on with what the index knows.
    public func reconcileOrphans() async {
        for run in await store.runs(tagged: nil) where run.isOrphan {
            do {
                _ = try await reconcile(run)
            } catch {
                warn("couldn't reconcile run \(run.runID) by its tag (\(error.localizedDescription)); it stays listed as requested.")
            }
        }
    }
}
