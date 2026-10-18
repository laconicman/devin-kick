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
        guard contains(resolved) else {
            throw .usage("\(path) resolves to \(resolved), outside KICK_UPLOAD_ROOTS (\(roots.joined(separator: ":"))). Uploads are permanent; move the file or extend the roots.")
        }
        return URL(fileURLWithPath: resolved)
    }

    /// Whether the canonical path `resolved` lies inside a root.
    func contains(_ resolved: String) -> Bool {
        roots.contains { resolved.hasPrefix($0 == "/" ? "/" : $0 + "/") }
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
    /// The bytes of the file at `url`, if the file actually opened is that path and inside
    /// `roots`. The open takes no symlink at the last component (`O_NOFOLLOW`), and the opened
    /// descriptor's own path (`fcntl(F_GETPATH)`) is checked before a byte is read, so a swap of
    /// the file or of any parent directory after `prepare` can't upload what lies outside.
    static func readOpened(_ url: URL, within roots: UploadRoots) throws(KickError) -> Data {
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(FilePath(url.path), .readOnly, options: [.noFollow])
        } catch {
            throw .usage("Couldn't open \(url.path) (\(error.localizedDescription)); nothing was uploaded.")
        }
        let handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: true)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBytes { bytes in
            bytes.baseAddress.map { fcntl(descriptor.rawValue, F_GETPATH, $0) } ?? -1
        }
        let opened = status == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        guard opened == url.path, roots.contains(opened) else {
            throw .usage("\(url.path) opened as \(opened.isEmpty ? "an unknown path" : opened), not the file that was checked inside KICK_UPLOAD_ROOTS; nothing was uploaded.")
        }
        do {
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
        // Uploads are permanent, and a path checked at `prepare` can be swapped since, at the
        // file or at any parent directory. So what is read is the file actually opened, checked
        // by its own path (PR #11 review, r4308715320).
        let data = try Self.readOpened(file, within: try UploadRoots(configuration.uploadRoots))
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
