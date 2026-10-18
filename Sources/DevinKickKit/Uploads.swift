import CryptoKit
import DevinOpenAPI
public import Foundation
import OpenAPIRuntime
import System

/// Uploads are permanent (CLAUDE.md rule 7), so kick uploads only from the directories named in
/// `KICK_UPLOAD_ROOTS`, and never the same content twice: `uploads.jsonl` in the run store maps
/// sha256 + file name to the URL Devin returned.
///
/// If Devin ever expires attachments, a cached URL fails at create with the server's own error;
/// that is accepted, and noted in Design.
public struct Upload: Sendable, Hashable {
    /// The file, as resolved (symlinks followed).
    public var file: URL
    /// The URL to pass as an attachment.
    public var url: String
    /// Whether the URL came from the cache, with nothing uploaded.
    public var cached: Bool
}

/// The allowed upload directories, resolved once.
struct UploadRoots: Sendable {
    let roots: [String]

    /// `nil` roots (the variable unset) allow nothing.
    init(_ configured: [String]?) throws(KickError) {
        guard let configured else {
            throw .config("KICK_UPLOAD_ROOTS is unset, so kick uploads nothing: uploads are permanent. Set it to the colon-separated directories files may come from.")
        }
        // A root that doesn't exist can contain nothing, so it simply never matches.
        roots = configured.compactMap(Self.realPath)
    }

    /// `path` resolved (symlinks, `.` and `..`) against `base`, if it is a regular file inside a
    /// root; a usage error otherwise.
    func resolve(_ path: String, relativeTo base: URL? = nil) throws(KickError) -> URL {
        // The same resolution as a manifest's prompt and schema paths: `~` expanded first.
        let absolute = DevinKick.resolve(path, relativeTo: base)
        guard let resolved = Self.realPath(absolute.path) else {
            throw .usage("No such file: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw .usage("Not a file: \(path). Upload files, not directories.")
        }
        guard roots.contains(where: { resolved.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
            throw .usage("\(path) resolves to \(resolved), outside KICK_UPLOAD_ROOTS (\(roots.joined(separator: ":"))). Uploads are permanent; move the file or extend the roots.")
        }
        return URL(fileURLWithPath: resolved)
    }

    /// `realpath(3)`: the canonical path, symlinks resolved; `nil` if it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The upload cache, `uploads.jsonl` in the run store: one line per upload.
actor UploadCache {
    /// One upload. The URL is the organization's, on that server: the scope is part of the key,
    /// so changing `DEVIN_ORG_ID` or `KICK_SERVER_URL` over one store uploads again rather than
    /// handing out another organization's URL (PR #11 review, r4308715119). An entry recorded
    /// without a scope never matches.
    struct Entry: Codable, Sendable {
        var sha256: String
        var name: String
        var url: String
        var attachmentID: String
        var org: String?
        var server: String?
        var timestamp: Date

        enum CodingKeys: String, CodingKey {
            case sha256, name, url, org, server
            case attachmentID = "attachment_id"
            case timestamp = "ts"
        }

        var key: String? {
            guard let org, let server else { return nil }
            return Self.key(sha256: sha256, name: name, org: org, server: server)
        }

        static func key(sha256: String, name: String, org: String, server: String) -> String {
            [server, org, sha256, name].joined(separator: "\n")
        }
    }

    let url: URL
    private let warn: RunStore.Warn
    private var entries: [String: Entry]?

    init(url: URL, warn: @escaping RunStore.Warn) {
        self.url = url
        self.warn = warn
    }

    func lookup(sha256: String, name: String, org: String, server: String) -> Entry? {
        if entries == nil {
            entries = [:]
            let lines = (try? Data(contentsOf: url))?.split(separator: UInt8(ascii: "\n")) ?? []
            for line in lines {
                if let entry = try? RunStore.decoder.decode(Entry.self, from: line), let key = entry.key {
                    entries?[key] = entry
                }
            }
        }
        return entries?[Entry.key(sha256: sha256, name: name, org: org, server: server)]
    }

    /// Records an upload. A failure only warns: the file is uploaded either way, and a lost
    /// entry costs a second upload of the same content later.
    func record(_ entry: Entry) {
        if let key = entry.key { entries?[key] = entry }
        do {
            try RunStore.createPrivateDirectory(url.deletingLastPathComponent())
            try RunStore.appendLine(try RunStore.encoder.encode(entry), to: url)
        } catch {
            warn("couldn't record the upload of \(entry.name) in \(url.path) (\(error.localizedDescription)); it may be uploaded again.")
        }
    }
}

extension DevinKick {
    /// The bytes of `url`, opened with `O_NOFOLLOW`, so a symlink put in its place fails.
    static func readWithoutFollowing(_ url: URL) throws(KickError) -> Data {
        do {
            let descriptor = try FileDescriptor.open(FilePath(url.path), .readOnly, options: [.noFollow])
            let handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: true)
            return try handle.readToEnd() ?? Data()
        } catch {
            throw .usage("Couldn't read \(url.path) (\(error.localizedDescription)); nothing was uploaded.")
        }
    }

    /// Uploads `paths` (relative ones against `base`), each only if its content and name aren't
    /// in the cache. Every path is checked against `KICK_UPLOAD_ROOTS` before anything is sent.
    public func upload(_ paths: [String], relativeTo base: URL? = nil) async throws(KickError) -> [Upload] {
        var uploads: [Upload] = []
        for file in try checkUploadable(paths, relativeTo: base) {
            uploads.append(try await upload(resolved: file))
        }
        return uploads
    }

    /// Checks `paths` against the roots without uploading: a manifest validates every entry
    /// before its first POST.
    func checkUploadable(_ paths: [String], relativeTo base: URL?) throws(KickError) -> [URL] {
        guard !paths.isEmpty else { return [] }
        let roots = try UploadRoots(configuration.uploadRoots)
        return try paths.map { path throws(KickError) in try roots.resolve(path, relativeTo: base) }
    }

    func upload(resolved file: URL) async throws(KickError) -> Upload {
        // Checked again as it is read: a file that became a symlink since `prepare` could point
        // anywhere, and uploads are permanent (PR #11 review, r4308715320). The read doesn't
        // follow a symlink either, so a swap between this check and the read fails too.
        let checked = try UploadRoots(configuration.uploadRoots).resolve(file.path)
        guard checked.path == file.path else {
            throw .usage("\(file.path) now resolves to \(checked.path), not the file that was checked; nothing was uploaded.")
        }
        let data = try Self.readWithoutFollowing(checked)
        let name = file.lastPathComponent
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let orgID = try configuration.requireOrgID()
        let server = configuration.serverURL.absoluteString
        if let entry = await uploads.lookup(sha256: sha256, name: name, org: orgID, server: server) {
            return Upload(file: file, url: entry.url, cached: true)
        }
        // A part over in-memory `Data`, in an array: both re-iterable (`.multiple`), so a 429 can
        // be retried by `RetryMiddleware`.
        let response = try await call(Operations.UploadAttachment.id) {
            try await client.uploadAttachment(
                path: .init(orgId: orgID),
                body: .multipartForm([.file(.init(payload: .init(body: HTTPBody(data)), filename: name))])
            ).ok.body.json
        }
        await uploads.record(.init(
            sha256: sha256, name: name, url: response.url, attachmentID: response.attachmentId,
            org: orgID, server: server, timestamp: Date()
        ))
        return Upload(file: file, url: response.url, cached: false)
    }
}
