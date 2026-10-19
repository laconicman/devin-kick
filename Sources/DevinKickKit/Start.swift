import DevinOpenAPI
public import Foundation

/// What applies to every session one `start` creates: the flags of `kick start`.
public struct StartOptions: Sendable, Hashable {
    /// `--mode`: overrides every manifest entry's mode.
    public var mode: DevinMode?
    /// `--tag`: added to every session's tags.
    public var tags: [String]
    public var resumable: Bool
    /// `true` unless a person passes `--no-bypass-approval` (Design: "Approvals").
    public var bypassApproval: Bool
    public var acuLimit: Int?
    /// `--out`: the directory the run directories go in, instead of the store's `runs/`.
    public var outDirectory: URL?

    public init(
        mode: DevinMode? = nil, tags: [String] = [], resumable: Bool = true, bypassApproval: Bool = true,
        acuLimit: Int? = nil, outDirectory: URL? = nil
    ) {
        self.mode = mode
        self.tags = tags
        self.resumable = resumable
        self.bypassApproval = bypassApproval
        self.acuLimit = acuLimit
        self.outDirectory = outDirectory
    }
}

/// Where a session's first message comes from.
public enum PromptSource: Sendable, Hashable {
    /// A file whose text is sent byte for byte: `kick start --prompt`, a manifest entry,
    /// `kick_start`'s `prompt_file`.
    case file(String)
    /// The text itself: `kick_start`'s `prompt`. ``DevinKick/start(_:)`` writes it into the run
    /// directory as `prompt.md` before `request.json`, which names it, so the run is recorded as
    /// one from a file is, and the file is byte-identical to the first message.
    case text(String)
}

/// One session to start, validated: its prompt read, its schema augmented, its attachments
/// resolved inside `KICK_UPLOAD_ROOTS`, its mode resolved.
public struct SessionRequest: Sendable, Hashable {
    /// The prompt's text, sent as is: the session's first message is byte-identical.
    public var prompt: String
    /// The file the prompt came from; `nil` for inline text, which ``DevinKick/start(_:)``
    /// writes into the run directory as `prompt.md`.
    public var promptFile: URL?
    public var title: String?
    /// The schema as sent, with `kick_final` (``Schema/augmented(_:)``).
    public var schema: Data
    public var schemaFile: URL?
    public var attachments: [URL]
    public var mode: DevinMode
    public var tags: [String]
    public var resumable: Bool
    public var bypassApproval: Bool
    public var acuLimit: Int?
    public var outDirectory: URL?
}

extension SessionRequest {
    /// How a failure names the request: its title, or its prompt file.
    public var name: String { title ?? promptFile?.lastPathComponent ?? "an inline prompt" }
}

/// A session kick started and recorded.
public struct StartedRun: Sendable, Hashable {
    public var run: RunState
    public var sessionID: String
    public var url: String

    /// `run id  session id  URL  directory`, and any duplicate found under the run's tag.
    public var line: String {
        var line = "\(run.runID)  \(sessionID)  \(url)  \(run.directory.path)"
        if !run.duplicates.isEmpty {
            line += "\n  also under this run's tag: \(run.duplicates.joined(separator: ", "))"
        }
        return line
    }
}

extension DevinKick {
    /// The tag every session kick starts carries, so `list --remote --tag kick` finds them.
    public static let kickTag = "kick"

    /// Validates one session from a prompt file (`kick start --prompt`).
    public func prepare(
        promptFile: String, title: String?, schemaFile: String?, attach: [String], options: StartOptions
    ) throws(KickError) -> SessionRequest {
        try prepare(.file(promptFile), title: title, schemaFile: schemaFile, attach: attach, mode: nil, tags: [], options: options)
    }

    /// Validates one session of a batch, from a file or inline text, with its own mode and tags
    /// as a manifest entry has them (the MCP server's `kick_start`). Relative paths resolve
    /// against the working directory.
    public func prepare(
        _ prompt: PromptSource, title: String?, schemaFile: String?, attach: [String], mode: DevinMode?, tags: [String],
        options: StartOptions
    ) throws(KickError) -> SessionRequest {
        try prepare(
            prompt, title: title, schemaFile: schemaFile, attach: attach, entryMode: mode, entryTags: tags,
            options: options, relativeTo: nil
        )
    }

    /// Validates every entry of `manifest` before anything is sent: a usage error names the
    /// entry and aborts the batch with nothing started.
    public func prepare(manifest: Manifest, options: StartOptions) throws(KickError) -> [SessionRequest] {
        var requests: [SessionRequest] = []
        for (number, entry) in manifest.entries.enumerated() {
            do {
                let mode = try entry.mode.map { mode throws(KickError) in try DevinMode(mode) }
                requests.append(try prepare(
                    .file(entry.promptFile), title: entry.title, schemaFile: entry.schemaFile,
                    attach: entry.attach ?? [], entryMode: mode, entryTags: entry.tags ?? [],
                    options: options, relativeTo: manifest.directory
                ))
            } catch {
                throw .usage("Manifest entry \(number + 1) (\(entry.title)): \(error.localizedDescription) Nothing was started.")
            }
        }
        return requests
    }

    func prepare(
        _ source: PromptSource, title: String?, schemaFile: String?, attach: [String], entryMode: DevinMode?,
        entryTags: [String], options: StartOptions, relativeTo base: URL?
    ) throws(KickError) -> SessionRequest {
        let prompt: String
        let promptURL: URL?
        switch source {
        case .file(let path):
            let url = Self.resolve(path, relativeTo: base)
            prompt = try Self.readText(url, what: "prompt")
            guard !prompt.isEmpty else { throw .usage("The prompt file \(url.path) is empty.") }
            promptURL = url
        case .text(let text):
            guard !text.isEmpty else { throw .usage("The prompt is empty.") }
            prompt = text
            promptURL = nil
        }
        let schemaURL = schemaFile.map { Self.resolve($0, relativeTo: base) }
        let schema = try Schema.augmented(try schemaURL.map { url throws(KickError) in try Self.readData(url, what: "schema") })
        return SessionRequest(
            prompt: prompt,
            promptFile: promptURL,
            title: title,
            schema: schema,
            schemaFile: schemaURL,
            attachments: try checkUploadable(attach, relativeTo: base),
            mode: DevinMode.resolve(flag: options.mode, entry: entryMode, environment: configuration.defaultMode),
            tags: entryTags + options.tags,
            resumable: options.resumable,
            bypassApproval: options.bypassApproval,
            acuLimit: options.acuLimit,
            outDirectory: options.outDirectory
        )
    }

    static func resolve(_ path: String, relativeTo base: URL?) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let base, !expanded.hasPrefix("/") else { return URL(fileURLWithPath: expanded) }
        return URL(fileURLWithPath: expanded, relativeTo: base).absoluteURL
    }

    static func readData(_ url: URL, what: String) throws(KickError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .usage("Couldn't read the \(what) file \(url.path) (\(error.localizedDescription)).")
        }
    }

    static func readText(_ url: URL, what: String) throws(KickError) -> String {
        guard let text = String(data: try readData(url, what: what), encoding: .utf8) else {
            throw .usage("The \(what) file \(url.path) is not UTF-8.")
        }
        return text
    }

    /// The tags a run's session carries: the caller's, then `kick` and the run tag, each once.
    static func tags(_ tags: [String], runID: String) -> [String] {
        var seen = Set<String>()
        return (tags + [kickTag, RunStore.runTag(runID)]).filter { seen.insert($0).inserted }
    }

    /// Starts one session, recorded at submit (Design: "Never lost; duplicates found, not
    /// prevented"). The order is pinned: upload the attachments, mint the run id, write an
    /// inline prompt as `prompt.md`, write `request.json`, append `requested`, POST, write
    /// `session.json`, append `created`.
    ///
    /// A run with `requested` and no `created` is an orphan, found again by its run tag. Ctrl-C
    /// kills the process, so the record written before the POST is what makes "never lost"
    /// hold; the shield around the POST and its recording covers a cancelled caller (the MCP
    /// server, from M2).
    public func start(_ request: SessionRequest) async throws(KickError) -> StartedRun {
        let orgID = try configuration.requireOrgID()
        await checkMode(request.mode)
        var attachmentURLs: [String] = []
        for file in request.attachments {
            attachmentURLs.append(try await upload(resolved: file).url)
        }
        let runID = await store.newRunID()
        // Untitled, a run directory is named after its prompt file, or an inline prompt's first line.
        let name = request.title ?? request.promptFile?.deletingPathExtension().lastPathComponent
            ?? request.prompt.split(whereSeparator: \.isNewline).first.map(String.init)
        let directory = try await store.makeRunDirectory(runID: runID, title: name, parent: request.outDirectory)
        let promptFile: URL
        if let file = request.promptFile {
            promptFile = file
        } else {
            promptFile = try await store.writePrompt(request.prompt, in: directory)
        }
        let tags = Self.tags(request.tags, runID: runID)
        let body = try Self.createBody(request, attachmentURLs: attachmentURLs, tags: tags)
        try await store.writeRequest(try Self.requestRecord(body, request, promptFile: promptFile), in: directory)
        let run = RunState(
            runID: runID, directory: directory, mode: request.mode.rawValue, title: request.title, tags: tags,
            resumable: request.resumable
        )
        try await store.append(IndexEvent(.requested, run: run))

        // TODO(TD-6): `withTaskCancellationShield` (SE-0504) once the floor reaches macOS 27.
        // Until then an unstructured task: cancelling the task awaiting its value doesn't
        // propagate into it, so the POST and its recording finish either way.
        let shielded = Task { () async -> Result<StartedRun, KickError> in
            do throws(KickError) {
                return .success(try await create(body, orgID: orgID, run: run))
            } catch {
                return .failure(error)
            }
        }
        return try await shielded.value.get()
    }

    /// POSTs the create and records the answer. A create isn't idempotent (the spec has no
    /// key, and its `devin_id` query parameter, listed without a description, is ignored: probed
    /// 2026-10-18), so after an error
    /// where the session may exist, kick looks for it by run tag, twice with a settle delay
    /// between, before it creates again; a 429 or a refusal is recorded as the run's failure.
    func create(_ body: Components.Schemas.SessionCreateRequest, orgID: String, run: RunState) async throws(KickError) -> StartedRun {
        var retries = 0
        while true {
            let session: Components.Schemas.SessionResponse
            // Only the POST is classified here. Once a session exists, a failure to record it is
            // that failure (the store's message names the session), never a refusal: recorded as
            // `failed`, the run would leave every reconcile, and its session would go untracked.
            do throws(KickError) {
                session = try await call(Operations.CreateSession.id) {
                    try await client.createSession(path: .init(orgId: orgID), body: .json(body)).ok.body.json
                }
            } catch {
                guard Self.mayHaveCreated(error) else {
                    var event = IndexEvent(.failed, run: run)
                    if case .server(_, let code, _) = error { event.errorCode = code }
                    event.message = error.localizedDescription
                    do throws(KickError) {
                        try await store.append(event)
                    } catch let storeError {
                        // Unrecorded, the refused run would read as an orphan whose session
                        // lookups chase forever (PR #11 review, r4308714989).
                        throw .store("\(storeError.localizedDescription) The server had refused the create: \(error.localizedDescription)")
                    }
                    throw error
                }
                // If the listing fails, kick can't look, and creating again could duplicate: the
                // error surfaces, and the orphan is reconciled at the next lookup.
                let found = try await settledListing(run.runTag)
                if !found.isEmpty { return try started(try await recordCreated(run, sessions: found, retried: retries > 0)) }
                retries += 1
                guard retries <= timing.retry.maxRetries else { throw error }
                try? await timing.sleep(timing.retry.backoff(retry: retries))
                continue
            }
            var found = [SessionSnapshot(session)]
            if retries > 0 {
                // An earlier attempt whose answer was lost may have created one after all.
                do throws(KickError) {
                    found += try await sessions(tagged: run.runTag).filter { $0.id != session.sessionId }
                } catch {
                    warn("couldn't check run tag \(run.runTag) for a duplicate after a retried create (\(error.localizedDescription)); `kick status \(run.runID)` checks again.")
                }
            }
            return try started(try await recordCreated(run, sessions: found, retried: retries > 0))
        }
    }

    /// The sessions under `tag`. The listing may not yet show a session still being created
    /// when its answer was lost, so an empty result counts only after a second listing
    /// ``Timing/createSettle`` later. That leaves a residual race (TD-7).
    func settledListing(_ tag: String) async throws(KickError) -> [SessionSnapshot] {
        let first = try await sessions(tagged: tag)
        guard first.isEmpty else { return first }
        try? await timing.sleep(timing.createSettle)
        return try await sessions(tagged: tag)
    }

    /// An error after which the session may exist: no answer, a 5xx, or a 2xx kick couldn't
    /// read. A 429 means the request wasn't processed, and any other status refused it.
    static func mayHaveCreated(_ error: KickError) -> Bool {
        switch error {
        case .transport, .decoding: true
        case .server(let status, _, _): status >= 500
        case .config, .usage, .store, .ended, .notTerminated: false
        }
    }

    func started(_ run: RunState) throws(KickError) -> StartedRun {
        guard let sessionID = run.sessionID, let url = run.url else {
            throw .decoding("create_session: the session was recorded without an id")
        }
        return StartedRun(run: run, sessionID: sessionID, url: url)
    }

    static func createBody(
        _ request: SessionRequest, attachmentURLs: [String], tags: [String]
    ) throws(KickError) -> Components.Schemas.SessionCreateRequest {
        let schema: Components.Schemas.SessionCreateRequest.StructuredOutputSchemaPayload
        do {
            schema = try JSONDecoder().decode(
                Components.Schemas.SessionCreateRequest.StructuredOutputSchemaPayload.self, from: request.schema
            )
        } catch {
            throw .usage("The schema could not be read as a JSON object (\(error.localizedDescription)).")
        }
        return Components.Schemas.SessionCreateRequest(
            attachmentUrls: attachmentURLs.isEmpty ? nil : attachmentURLs,
            bypassApproval: request.bypassApproval,
            devinMode: request.mode.payload,
            maxAcuLimit: request.acuLimit,
            prompt: request.prompt,
            resumable: request.resumable,
            structuredOutputSchema: schema,
            tags: tags,
            title: request.title
        )
    }

    /// `request.json`: the body as sent, and the files it came from; an inline prompt's file is
    /// its `prompt.md`.
    struct RequestRecord: Encodable {
        var body: Components.Schemas.SessionCreateRequest
        var promptFile: String
        var schemaFile: String?
        var attach: [String]

        enum CodingKeys: String, CodingKey {
            case body, attach
            case promptFile = "prompt_file"
            case schemaFile = "schema_file"
        }
    }

    static func requestRecord(
        _ body: Components.Schemas.SessionCreateRequest, _ request: SessionRequest, promptFile: URL
    ) throws(KickError) -> Data {
        let record = RequestRecord(
            body: body, promptFile: promptFile.path, schemaFile: request.schemaFile?.path,
            attach: request.attachments.map(\.path)
        )
        do {
            return try RunStore.prettyEncoder.encode(record)
        } catch {
            throw .store("Couldn't encode request.json (\(error.localizedDescription)). Nothing was sent to Devin.")
        }
    }
}
