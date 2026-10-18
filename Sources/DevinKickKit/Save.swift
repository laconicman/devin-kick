public import Foundation

/// What `save` wrote for one session.
public struct SavedRun: Sendable, Equatable {
    public var run: RunState
    public var reading: Reading
    /// The files written, in the run directory.
    public var files: [URL]
}

extension DevinKick {
    /// Saves where `argument` stands into its run directory: `session.json`, `result.json` (the
    /// structured output), `messages.json` and `attachments/`, then a `settled` event. A session
    /// kick didn't record gets a run of its own. A deleted run directory is recreated.
    ///
    /// The files are derived, so one that can't be written or fetched only warns; the session's
    /// own read and the index event throw.
    public func save(_ argument: String) async throws(KickError) -> SavedRun {
        let sessionID = try await sessionID(of: argument)
        var run = await store.lookup(argument)
        let session = try await session(sessionID)
        if run == nil { run = try await adopt(session) }
        guard var run else { throw .store("Couldn't record session \(sessionID).") }
        try await store.makeDirectory(run.directory)

        var files: [URL] = []
        func write(_ data: Data, _ name: String) async {
            let url = run.directory.appending(path: name)
            if await store.writeDerived(data, to: url) { files.append(url) }
        }
        await write(session.json, "session.json")
        if let output = session.structuredOutput {
            let pretty = (try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: output), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? output
            await write(pretty, "result.json")
        } else {
            // No output now: an earlier save's result.json would read as this snapshot's result
            // (PR #11 review, r4308714874), so it goes.
            await store.removeDerived(run.directory.appending(path: "result.json"))
        }
        do throws(KickError) {
            let messages = try await messages(sessionID)
            await write((try? RunStore.prettyEncoder.encode(messages.map(\.record))) ?? Data(), "messages.json")
        } catch {
            warn("couldn't read the messages of \(sessionID) (\(error.localizedDescription)); `kick save` again to retry.")
        }
        var renamed: [String: String] = [:]
        do throws(KickError) {
            var taken = Set<String>()
            for attachment in try await attachments(sessionID) {
                let name = Self.safeName(attachment.name, taken: taken)
                taken.insert(name)
                if name != attachment.name { renamed[attachment.name] = name }
                do throws(KickError) {
                    files.append(try await download(attachment, to: run.directory.appending(path: "attachments/\(name)")).file)
                } catch {
                    warn("couldn't download attachment \(attachment.name) (\(error.localizedDescription)); `kick save` again to retry.")
                }
            }
        } catch {
            warn("couldn't list the attachments of \(sessionID) (\(error.localizedDescription)); `kick save` again to retry.")
        }

        let reading = observation(argument, run: run, session: session)
        var event = IndexEvent(.settled, run: run)
        if case .settled(let settlement) = reading.outcome { event.settlement = settlement.label }
        event.status = session.status
        event.statusDetail = session.statusDetail
        if !renamed.isEmpty { event.renamed = renamed }
        try await store.append(event)
        run.apply(event)
        return SavedRun(run: run, reading: reading, files: files)
    }

    /// Records a session kick didn't create as a run of its own, so it can be saved.
    func adopt(_ session: SessionSnapshot) async throws(KickError) -> RunState {
        let runID = await store.newRunID()
        let directory = try await store.makeRunDirectory(runID: runID, title: session.title)
        var run = RunState(runID: runID, directory: directory, mode: session.mode, title: session.title, tags: session.tags, resumable: nil)
        run.sessionID = session.id
        run.url = session.url
        let event = IndexEvent(.created, run: run)
        try await store.append(event)
        run.apply(event)
        return run
    }
}
