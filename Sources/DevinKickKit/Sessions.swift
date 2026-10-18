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
    /// `GET …/sessions/{id}`.
    public func session(_ id: String) async throws(KickError) -> SessionSnapshot {
        let orgID = try configuration.requireOrgID()
        return SessionSnapshot(try await call(Operations.GetSession.id) {
            try await client.getSession(path: .init(orgId: orgID, devinId: id)).ok.body.json
        })
    }

    /// The session id `argument` (a session id, run id or run directory) names: a usage error
    /// for a run that has no session.
    public func sessionID(of argument: String) async throws(KickError) -> String {
        let run = await store.lookup(argument)
        guard let sessionID = run?.sessionID ?? (run == nil ? argument : nil) else {
            throw .usage("Run \(argument) has no session: \(run?.failure ?? "its create's answer was lost, and no session carries its run tag yet").")
        }
        return sessionID
    }

    /// Reads where `argument` (a session id, run id or run directory) stands.
    public func observe(_ argument: String) async -> Reading {
        let run = await store.lookup(argument)
        guard let sessionID = run?.sessionID ?? (run == nil ? argument : nil) else {
            return Self.reading(argument, unstartedRun: run)
        }
        do throws(KickError) {
            return observation(argument, run: run, session: try await session(sessionID))
        } catch {
            return Reading(argument: argument, run: run, session: nil, verdict: nil, outcome: .unreadable(error))
        }
    }

    /// The reading of `session`, with the verdict its run's record allows.
    func observation(_ argument: String, run: RunState?, session: SessionSnapshot) -> Reading {
        let verdict = OutputVerdict(output: session.structuredOutput, repliedByKick: run?.replied ?? false)
        let settlement = Settlement(status: session.status, detail: session.statusDetail, output: verdict)
        return Reading(argument: argument, run: run, session: session, verdict: verdict, outcome: .settled(settlement))
    }

    /// A run with no session: refused at create (failed), or an orphan not yet found (unknown).
    static func reading(_ argument: String, unstartedRun run: RunState?) -> Reading {
        let settlement: Settlement = if let failure = run?.failure {
            .failed(status: "not created", detail: failure)
        } else {
            .unknown(status: "requested", detail: "no session found under its run tag yet")
        }
        return Reading(argument: argument, run: run, session: nil, verdict: nil, outcome: .settled(settlement))
    }

    /// Every session carrying `tag` on the server, read from one listing.
    public func observe(tagged tag: String) async throws(KickError) -> [Reading] {
        var readings: [Reading] = []
        for session in try await sessions(tagged: tag) {
            readings.append(observation(session.id, run: await store.lookup(session.id), session: session))
        }
        return readings
    }

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
            // A cursor that doesn't move would loop forever: stop there.
            let next = page.hasNextPage == true ? page.endCursor : nil
            cursor = next == cursor ? nil : next
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

extension DevinKick {
    /// Archives the session `argument` names, which also puts a running one to sleep; with
    /// `terminate`, ends it first, in one `DELETE …?archive=true`. Records `archived`, and
    /// returns the session as read afterwards.
    ///
    /// Both answers carry the status from before the call, so the session is read again. That
    /// read is also the only proof of a terminate, which settles asynchronously: live
    /// (2026-10-18) a session passed through `running/finished` and read `exit` about 4 s
    /// later, while one terminate sent a second after create answered 200, archived the session
    /// and never ended it. So a terminate is read back until `exit`, for up to
    /// ``Timing/terminateSettle``. A sleeping session is not waited for: a terminate answers it
    /// 200 and leaves it `suspended` (live, the same day).
    public func archive(_ argument: String, terminate: Bool = false) async throws(KickError) -> SessionSnapshot {
        let sessionID = try await sessionID(of: argument)
        let orgID = try configuration.requireOrgID()
        func archiveOnly() async throws(KickError) {
            _ = try await call(Operations.ArchiveSession.id) {
                try await client.archiveSession(path: .init(orgId: orgID, devinId: sessionID)).ok.body.json
            }
        }
        if terminate {
            do throws(KickError) {
                _ = try await call(Operations.TerminateSession.id) {
                    try await client.terminateSession(path: .init(orgId: orgID, devinId: sessionID), query: .init(archive: true)).ok.body.json
                }
            } catch {
                // Live, a terminate of a session that has exited answers 400 ("already
                // exited"). So a repeat (a person's, or a retry after a lost answer) reads the
                // session before failing, and only archives one that has ended.
                guard case .server(400, _, _) = error, try await session(sessionID).status == "exit" else { throw error }
                try await archiveOnly()
            }
        } else {
            try await archiveOnly()
        }
        try await record(.archived, for: argument)
        var session = try await session(sessionID)
        let deadline = timing.now() + timing.terminateSettle
        while terminate, !["exit", "suspended"].contains(session.status), timing.now() < deadline {
            try? await timing.sleep(timing.terminatePoll)
            session = try await self.session(sessionID)
        }
        return session
    }

    /// Unarchives the session `argument` names. Records `unarchived`.
    public func unarchive(_ argument: String) async throws(KickError) -> SessionSnapshot {
        let sessionID = try await sessionID(of: argument)
        let orgID = try configuration.requireOrgID()
        let session = SessionSnapshot(try await call(Operations.UnarchiveSession.id) {
            try await client.unarchiveSession(path: .init(orgId: orgID, devinId: sessionID)).ok.body.json
        })
        try await record(.unarchived, for: argument)
        return session
    }

    /// Appends `kind` to the run of `argument`, if kick has one.
    func record(_ kind: IndexEvent.Kind, for argument: String) async throws(KickError) {
        if let run = await store.lookup(argument) {
            try await store.append(IndexEvent(kind, run: run))
        }
    }

    /// The server's sessions, newest first as it lists them, optionally only those tagged `tag`.
    public func observeRemote(tagged tag: String?, limit: Int) async throws(KickError) -> [Reading] {
        var readings: [Reading] = []
        for session in try await listSessions(tags: tag.map { [$0] }, limit: limit) {
            readings.append(observation(session.id, run: await store.lookup(session.id), session: session))
        }
        return readings
    }
}
