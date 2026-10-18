public import Foundation
import OpenAPIRuntime

/// Every failure the Kit reports. Typed (`throws(KickError)`), so the CLI maps each case to an
/// exit status exhaustively and the MCP server to one `isError` text, with no catch-all.
///
/// Messages quote the server's own `detail` and name the next step (deepwiki-mcp's TD-8
/// lesson); they never print `String(describing:)` of a payload (its TD-9).
public enum KickError: Error, Sendable, Equatable {
    /// A missing or invalid setting: `DEVIN_API_KEY`, `DEVIN_ORG_ID`, a `KICK_*` variable.
    case config(String)
    /// The caller asked for something malformed.
    case usage(String)
    /// The request never got an HTTP answer (DNS, TLS, timeout, connection reset). Retryable.
    case transport(String)
    /// Devin answered with an error status. `code` is the ProblemDetail `error_code`, if any.
    case server(status: Int, code: String?, detail: String)
    /// Devin answered 2xx with a body this version can't read.
    case decoding(String)
    /// The run store couldn't record a run: `request.json` or the index. Not retryable as is;
    /// fix the store (`KICK_STORE`, `--out`) first.
    case store(String)
    /// The session has ended (`exit` or `error`), so a message can't reach it.
    case ended(sessionID: String, status: String)
    /// A terminate was answered, but the session still read `status` after the settle window.
    case notTerminated(sessionID: String, status: String)

    /// The CLI exit status: sysexits-style where one fits.
    public var exitCode: Int32 {
        switch self {
        case .config: 78                     // EX_CONFIG
        case .usage: 64                      // EX_USAGE
        case .transport: 69                  // EX_UNAVAILABLE: retry
        case .server(let status, _, _) where status == 429 || status >= 500: 69
        case .server, .decoding, .ended, .notTerminated: 1
        case .store: 73                      // EX_CANTCREAT
        }
    }

    /// Whether a retry may succeed without anything changing on the caller's side.
    public var isRetryable: Bool { exitCode == 69 }
}

extension KickError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .config(let message), .usage(let message), .store(let message):
            return message
        case .transport(let message):
            return "No answer from Devin (\(message)). Retry; sessions already created are unaffected."
        case .server(let status, let code, let detail):
            let code = code.map { "\($0): " } ?? ""
            return "Devin answered \(status): \(code)\(detail)\(Self.hint(for: status))"
        case .decoding(let message):
            return "Devin's answer could not be read (\(message)). The vendored spec may be stale: re-vendor it with `swift run devin-spec-tool`."
        case .ended(let sessionID, let status):
            return "Session \(sessionID) has ended (\(status)): a reply can't reach it. Start a new session."
        case .notTerminated(let sessionID, let status):
            return "The terminate of session \(sessionID) was answered, but the session still reads \(status) (it is archived). Terminate it again to stop it."
        }
    }

    static func hint(for status: Int) -> String {
        switch status {
        case 401: " — check DEVIN_API_KEY (a cog_ key, exported in ~/.zshenv)."
        case 403: " — the key lacks permission here, or DEVIN_ORG_ID names the wrong organization."
        case 404: " — check the session id and DEVIN_ORG_ID."
        case 429: " — rate limited; retry after a pause."
        case 500...: " — Devin's side; retry later."
        default: ""
        }
    }
}

extension KickError {
    /// Classifies an error thrown by the generated client: an error status (read by
    /// `ProblemMiddleware`), a transport failure or an undecodable body.
    init(clientError error: any Error) {
        guard let clientError = error as? ClientError else {
            self = .transport(error.localizedDescription)
            return
        }
        switch clientError.underlyingError {
        case let problem as ProblemResponse:
            self = .server(status: problem.status, code: problem.code, detail: problem.detail)
        case is URLError:
            self = .transport(clientError.underlyingError.localizedDescription)
        case is DecodingError:
            self = .decoding("\(clientError.operationID): \(clientError.underlyingError.localizedDescription)")
        default:
            self = .transport("\(clientError.operationID): \(clientError.underlyingError.localizedDescription)")
        }
    }
}
