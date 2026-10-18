import DevinOpenAPI
public import Foundation
import Synchronization

/// A file attached to a session, by the user or by Devin.
public struct SessionAttachment: Sendable, Hashable {
    public var id: String
    /// The server's name for it; not safe as a path as is (`save` reduces it to a safe basename).
    public var name: String
    public var url: String
    public var source: String
    public var contentType: String?
}

/// What a download did, for the live suite's checks.
struct Download: Sendable {
    var file: URL
    /// Whether the API answered with a redirect.
    var redirected: Bool
    /// Whether URLSession would have carried `Authorization` onto the redirect's host, before
    /// kick removed it.
    var authorizationOffered: Bool
}

/// Removes `Authorization` from every redirect, so the API key never reaches the presigned
/// host (amendment A7, corrected). The generated client can't make this request: the spec's
/// 307 documents no `Location`, so its output is empty, and its 200 is typed as JSON.
final class StripAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    /// Per redirect: whether the request URLSession proposed still carried `Authorization`.
    let offered = Mutex<[Bool]>([])

    // `@concurrent`, as for every conformance to a dependency's protocol (Design: "Explicit
    // `@concurrent` at module boundaries"). Without it, swiftc 6.4 (swiftlang-6.4.0.34.1)
    // crashes in SILGen emitting this method's Objective-C thunk under
    // NonisolatedNonsendingByDefault, rather than diagnosing anything.
    @concurrent func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var request = request
        offered.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization") != nil) }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        guard let url = request.url, Self.mayFollow(url) else {
            refused.withLock { $0 = request.url }
            return nil
        }
        return request
    }

    /// A redirect the delegate declined to follow, if any.
    let refused = Mutex<URL?>(nil)

    /// Host names that never belong to a presigned download: local or internal.
    static let localSuffixes = [".local", ".localhost", ".internal", ".home.arpa"]

    /// Whether a redirect may be followed: `https`, to a host *name*. Live, the hop goes to S3
    /// (or an organization's IP-enforcing proxy); an IP literal, `localhost` or a local name
    /// would let a compromised endpoint point the client at internal services (PR #11 review,
    /// r4308715368).
    static func mayFollow(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        let isIPv4 = host.allSatisfy { $0.isNumber || $0 == "." }
        let isIPv6 = host.contains(":")
        return !isIPv4 && !isIPv6 && host != "localhost" && !localSuffixes.contains(where: host.hasSuffix)
    }
}

extension DevinKick {
    /// `GET …/sessions/{id}/attachments`.
    public func attachments(_ sessionID: String) async throws(KickError) -> [SessionAttachment] {
        let orgID = try configuration.requireOrgID()
        return try await call(Operations.GetSessionAttachments.id) {
            try await client.getSessionAttachments(path: .init(orgId: orgID, devinId: sessionID)).ok.body.json
        }.map {
            SessionAttachment(id: $0.attachmentId, name: $0.name, url: $0.url, source: $0.source, contentType: $0.contentType)
        }
    }

    /// The most UTF-8 bytes of a saved attachment's name.
    static let maximumNameBytes = 200
    /// The longest extension kept apart from the stem when a name is cut.
    static let maximumExtensionBytes = 16

    /// `name` as a safe basename in a directory already holding `taken`: no separators, no
    /// `.` or `..`, no leading dot or control characters, capped in length (keeping the
    /// extension), and numbered if taken.
    static func safeName(_ name: String, taken: Set<String>) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var base = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "attachment" }
        // An "extension" longer than any real one is part of the name: kept apart, it alone could
        // exceed the cap (PR #11 review, r4308715273).
        let found = (base as NSString).pathExtension
        let ext = found.utf8.count <= maximumExtensionBytes ? found : ""
        let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        /// The stem cut to fit the cap together with `tail` (a number, when the name is taken).
        func fitted(_ tail: String) -> String {
            var stem = stem
            while (stem + tail + suffix).utf8.count > maximumNameBytes, !stem.isEmpty { stem.removeLast() }
            return stem + tail + suffix
        }
        var candidate = fitted("")
        var number = 2
        while taken.contains(candidate) {
            candidate = fitted("-\(number)")
            number += 1
        }
        return candidate
    }

    /// Downloads `attachment` to `destination` through `GET …/attachments/{id}/{name}`, which
    /// answers 307 to a presigned URL. The listing's own `url` (`app.devin.ai/attachments/…`)
    /// answers 401 to an API key (the `devin` skill's trap, 2026-10-14), so it isn't used. The
    /// key goes only to the configured server's host; a dropped connection, a 429 or a 5xx is
    /// retried, as for any GET.
    func download(_ attachment: SessionAttachment, to destination: URL) async throws(KickError) -> Download {
        let orgID = try configuration.requireOrgID()
        // Each parameter is one percent-encoded path segment, `/` included: the name is the
        // server's, and `../x` must not become dot-segments that move the request elsewhere.
        let path = ["v3", "organizations", orgID, "attachments", attachment.id, attachment.name]
            .map(Self.pathSegment).joined(separator: "/")
        guard let url = URL(string: configuration.serverURL.absoluteString.trimmingCharacters(in: ["/"]) + "/" + path) else {
            throw .decoding("download_attachment: no URL for attachment \(attachment.id)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("devin-kick/\(Self.version)", forHTTPHeaderField: "User-Agent")
        let delegate = StripAuthorizationOnRedirect()
        let session = URLSession(configuration: downloadConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var retry = 0
        while true {
            let delay: Duration
            do {
                let (file, response) = try await session.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let refused = delegate.refused.withLock({ $0 }) {
                    throw KickError.server(status: status, code: nil, detail: "the download redirected to \(refused.host() ?? "an unnamed host") over \(refused.scheme ?? "no scheme"); only https host names are followed")
                }
                if (200..<300).contains(status) {
                    try Self.move(file, to: destination)
                    let offered = delegate.offered.withLock { $0 }
                    return Download(file: destination, redirected: !offered.isEmpty, authorizationOffered: offered.contains(true))
                }
                let body = (try? Data(contentsOf: file)) ?? Data()
                let problem = ProblemMiddleware.problem(status: status, body: body)
                let error = KickError.server(status: problem.status, code: problem.code, detail: problem.detail)
                guard RetryClass.idempotent.retries(status: status), retry < timing.retry.maxRetries else { throw error }
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                switch timing.retry.retryAfter(value: header) {
                case .absent: delay = timing.retry.backoff(retry: retry + 1)
                case .wait(let requested): delay = requested
                case .tooLong: throw error
                }
            } catch let error as KickError {
                throw error
            } catch let error as URLError where error.code != .cancelled && retry < timing.retry.maxRetries {
                delay = timing.retry.backoff(retry: retry + 1)
            } catch {
                throw .transport("download_attachment: \(error.localizedDescription)")
            }
            retry += 1
            try? await timing.sleep(delay)
        }
    }

    /// `text` percent-encoded as a single path segment.
    static func pathSegment(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        // A segment of dots alone (`.`, `..`) is a dot-segment whatever else is encoded, so its
        // dots are encoded too (RFC 3986 §3.3).
        if !text.isEmpty, text.allSatisfy({ $0 == "." }) { allowed.remove(charactersIn: ".") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Installs the downloaded `file` at `destination`. It is first moved beside the destination
    /// (which may cross volumes), then swapped in atomically, so a failure never costs a copy
    /// saved earlier (PR #11 review, r4308714933).
    static func move(_ file: URL, to destination: URL) throws(KickError) {
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).part")
        do {
            try RunStore.createPrivateDirectory(destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: file, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw .store("Couldn't save \(destination.path) (\(error.localizedDescription)); a copy saved earlier is untouched.")
        }
    }
}
