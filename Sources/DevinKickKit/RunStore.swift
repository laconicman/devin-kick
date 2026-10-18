public import Foundation
import System

/// The local record of every run: a directory per run and an append-only index (amendments
/// A9, A19; Design: "The run store").
///
/// Layout, under `KICK_STORE` (default `~/Library/Application Support/devin-kick`):
/// - `runs/<date>-<slug>-<run id>/`: `request.json`, `session.json`, `result.json`,
///   `messages.json` and `attachments/`. `--out` places a run directory elsewhere; the index
///   stays here and records absolute paths.
/// - `index.jsonl`: one event per line, read once into a map by run id and session id.
/// - `uploads.jsonl`: the upload cache (`Upload`).
///
/// Two write paths: `request.json` and the index throw ``KickError/store(_:)``, because a run
/// that isn't recorded can be lost; derived files (session, result, messages, attachments) only
/// warn, because a later `save` rewrites them. The store and its run directories are created
/// `0700`: they hold prompts and attachments.
///
/// An actor serializes writes within one process. Across processes, each index line is one
/// `write(2)` on an `O_APPEND` descriptor, with no locking. POSIX makes each write to a regular
/// file atomic and allows no other modification between the seek to the end and the write
/// (POSIX.1-2024, `write()`); `PIPE_BUF` bounds pipes, not files. That holds on a local file
/// system, not on NFS.
///
/// Adapted from deepwiki-mcp's `ConsultStore` (actor, append shape), without its swallowed
/// writes or its directory scan.
public actor RunStore {
    public let root: URL
    private let warn: Warn
    private var cache: [String: RunState]?

    public typealias Warn = @Sendable (String) -> Void

    /// Writes `kick: warning: …` to stderr, which stays free in an MCP stdio server.
    public static let standardError: Warn = { message in
        FileHandle.standardError.write(Data("kick: warning: \(message)\n".utf8))
    }

    public init(root: URL, warn: @escaping Warn = RunStore.standardError) {
        self.root = root
        self.warn = warn
    }

    nonisolated var indexURL: URL { root.appending(path: "index.jsonl") }
    nonisolated var runsURL: URL { root.appending(path: "runs", directoryHint: .isDirectory) }

    static let directoryPermissions: FilePermissions = .ownerReadWriteExecute
    static let filePermissions: FilePermissions = .ownerReadWrite
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    /// For the files people read: `request.json`, `session.json`, `result.json`.
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Runs

    /// The tag every session of run `runID` carries: how a session whose create answer was lost
    /// is found again.
    public static func runTag(_ runID: String) -> String { "kick-run-\(runID)" }

    /// A new run id, `yyyyMMdd-HHmmss-xxxx` in local time: sortable, and unique enough for one
    /// person's runs with four random hex digits.
    static func mintRunID(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"
    }

    /// A run id the index doesn't hold yet. Four hex digits give 65,536 ids a second, so a batch
    /// minted within one second could collide (about 2 % for 50 runs); a collision would merge
    /// two runs' records and their run tags, so it is re-minted.
    func newRunID(at date: Date = Date()) -> String {
        let known = runs()
        var runID = Self.mintRunID(at: date)
        while known[runID] != nil { runID = Self.mintRunID(at: date) }
        return runID
    }

    /// The most characters of a title kept in a run directory's name.
    static let maximumSlugLength = 40

    /// A title reduced to letters, digits and dashes, for a directory name.
    static func slug(_ title: String?) -> String {
        let words = (title ?? "").lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = String(words.joined(separator: "-").prefix(maximumSlugLength))
        return slug.isEmpty ? "run" : slug
    }

    /// Creates the directory for a new run: under `runs/`, or under `parent` (`--out`).
    func makeRunDirectory(runID: String, title: String?, parent: URL? = nil, at date: Date = Date()) throws(KickError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "\(formatter.string(from: date))-\(Self.slug(title))-\(runID)"
        let directory = (parent ?? runsURL).appending(path: name, directoryHint: .isDirectory)
        try makeDirectory(directory)
        return directory
    }

    func makeDirectory(_ directory: URL) throws(KickError) {
        do {
            try Self.createPrivateDirectory(directory)
        } catch {
            throw .store("Couldn't create \(directory.path) (\(error.localizedDescription)). Check KICK_STORE or --out.")
        }
    }

    /// Writes `request.json`. It throws: without it a run can't be retried faithfully.
    func writeRequest(_ data: Data, in directory: URL) throws(KickError) {
        let url = directory.appending(path: "request.json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .store("Couldn't write \(url.path) (\(error.localizedDescription)). Nothing was sent to Devin.")
        }
    }

    /// Writes a derived file (session, result, messages, an attachment), warning on failure: a
    /// later `save` rewrites it. Returns whether it was written.
    @discardableResult
    func writeDerived(_ data: Data, to url: URL) -> Bool {
        do {
            try Self.createPrivateDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            warn("couldn't write \(url.path) (\(error.localizedDescription)); `kick save` rewrites it.")
            return false
        }
    }

    /// Removes a derived file that no longer describes the session, warning on failure.
    func removeDerived(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            warn("couldn't remove the stale \(url.path) (\(error.localizedDescription)); it describes an earlier save.")
        }
    }

    // MARK: - Index

    /// Appends `event` to the index as one line, in one `write(2)`, and folds it into the map.
    func append(_ event: IndexEvent) throws(KickError) {
        let line: Data
        do {
            line = try Self.encoder.encode(event)
        } catch {
            throw .store("Couldn't encode an index event (\(error.localizedDescription)).")
        }
        try makeDirectory(root)
        do {
            try Self.appendLine(line, to: indexURL)
        } catch {
            throw .store("Couldn't append to \(indexURL.path) (\(error.localizedDescription)). The run is not recorded; check KICK_STORE.")
        }
        fold(event)
    }

    /// Creates `directory` and any missing parents, owner-only (`0700`); an existing one is
    /// left as it is.
    static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryPermissions.rawValue)]
        )
    }

    /// Appends `line` and a newline to `url` in one `write(2)` on an `O_APPEND` descriptor,
    /// creating the file `0600`. See the type's comment for why that needs no lock.
    static func appendLine(_ line: Data, to url: URL) throws {
        var line = line
        line.append(UInt8(ascii: "\n"))
        let descriptor = try FileDescriptor.open(
            FilePath(url.path), .writeOnly, options: [.append, .create], permissions: filePermissions
        )
        try descriptor.closeAfter { _ = try descriptor.writeAll(line) }
    }

    /// Every run the index knows, by run id. Read once; appends keep it current.
    func runs() -> [String: RunState] {
        if let cache { return cache }
        cache = [:]
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        for (number, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard let event = try? Self.decoder.decode(IndexEvent.self, from: line) else {
                warn("\(indexURL.path) line \(number + 1) is unreadable; skipped.")
                continue
            }
            fold(event)
        }
        return cache ?? [:]
    }

    private func fold(_ event: IndexEvent) {
        guard cache != nil else { return }
        if var run = cache?[event.runID] {
            run.apply(event)
            cache?[event.runID] = run
        } else {
            cache?[event.runID] = RunState(event: event)
        }
    }

    /// The run of `argument`: a run directory's path, a run id, or a session id the index knows.
    /// `nil` for a session kick didn't record.
    public func lookup(_ argument: String) -> RunState? {
        let runs = runs()
        if let run = runs[argument] { return run }
        // Symlinks resolved on both sides, so `/tmp/…` finds a run recorded as `/private/tmp/…`.
        let path = URL(fileURLWithPath: argument).resolvingSymlinksInPath().path
        return runs.values.first { $0.sessionID == argument || $0.directory.resolvingSymlinksInPath().path == path }
    }

    /// Every run whose tags include `tag`, newest first.
    public func runs(tagged tag: String? = nil) -> [RunState] {
        runs().values
            .filter { run in tag.map(run.tags.contains) ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
