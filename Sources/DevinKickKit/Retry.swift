import Foundation
import HTTPTypes
import OpenAPIRuntime

/// How the Kit retries a call that may succeed unchanged: a transport error, a 429 or a 5xx
/// (amendment A2). v3 documents no `Retry-After` and publishes no rate limits, so the header is
/// honored when sent and the backoff applies otherwise.
struct RetryPolicy: Sendable {
    /// Retries after the first attempt: four, after about 1, 2, 4 and 8 s.
    var maxRetries = 4
    /// The first retry's delay; each later one doubles it.
    var baseDelay: Duration = .seconds(1)
    /// Each delay is spread by up to this fraction either way, so parallel callers don't retry
    /// in lockstep.
    var jitter = 0.2
    /// The longest `Retry-After` honored. A longer one is surfaced as the 429 it is: the caller
    /// retries later, rather than kick blocking for minutes.
    var maxRetryAfter: Duration = .seconds(60)

    /// The delay before retry number `retry` (1-based), jittered.
    func backoff(retry: Int) -> Duration {
        let base = baseDelay * (1 << (retry - 1))
        return base * Double.random(in: (1 - jitter)...(1 + jitter))
    }

    /// What a response's `Retry-After` asks for.
    enum RetryAfter: Equatable {
        /// Absent or unreadable: the backoff applies.
        case absent
        /// A delay within ``RetryPolicy/maxRetryAfter``.
        case wait(Duration)
        /// Longer than ``RetryPolicy/maxRetryAfter``: surface the response.
        case tooLong
    }

    /// The server's `Retry-After`, in delta-seconds or as an HTTP date (RFC 9110 §10.2.3).
    func retryAfter(_ response: HTTPResponse, now: Date = Date()) -> RetryAfter {
        retryAfter(value: response.headerFields[.retryAfter], now: now)
    }

    /// The same, from the header's raw value (the attachment download reads it from an
    /// `HTTPURLResponse`).
    func retryAfter(value: String?, now: Date = Date()) -> RetryAfter {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return .absent }
        let seconds: Double
        if let delta = Int(value) {
            seconds = Double(max(delta, 0))
        } else if let date = Self.httpDate.date(from: value) {
            seconds = max(date.timeIntervalSince(now), 0)
        } else {
            return .absent
        }
        let delay = Duration.seconds(seconds)
        return delay <= maxRetryAfter ? .wait(delay) : .tooLong
    }

    /// IMF-fixdate, the preferred HTTP date format (RFC 9110 §5.6.7).
    static var httpDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}

/// Which failures an operation may retry, by operation id (Design: "Retries by idempotency").
enum RetryClass: Sendable, Equatable {
    /// Every GET, archive, unarchive, the tag PUT and terminate (a DELETE): repeating one
    /// changes nothing, so transport errors, 429 and 5xx all retry. A repeated terminate is
    /// answered 400 once the session has exited; ``DevinKick/archive(_:terminate:)`` reads that
    /// as done.
    case idempotent
    /// Session create, message post, upload and the tag POST: a repeat could act twice. Only a
    /// 429 (the request wasn't processed) and an error where the request provably never left
    /// retry here. Create reconciles by run tag after anything else (``DevinKick/start(_:)``).
    case unsentOnly

    init(operationID: String) {
        switch operationID {
        case "create_session", "post_message", "upload_attachment", "append_session_tags":
            self = .unsentOnly
        default:
            self = .idempotent
        }
    }

    /// URL loading errors where no byte of the request reached the server.
    static let unsentCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
    ]

    func retries(status: Int) -> Bool {
        switch status {
        case 429: true
        case 500...599: self == .idempotent
        default: false
        }
    }

    /// `error` is what the runtime's `next` threw: a `ClientError` whose `underlyingError` is
    /// the transport's own error (swift-openapi-runtime 1.13.1, `UniversalClient.send`, where
    /// `makeError` unwraps `RuntimeError.transportFailed`).
    func retries(error: any Error) -> Bool {
        guard let urlError = (error as? ClientError)?.underlyingError as? URLError,
              urlError.code != .cancelled else { return false }
        switch self {
        case .idempotent: return true
        case .unsentOnly: return Self.unsentCodes.contains(urlError.code)
        }
    }
}

/// Retries per ``RetryClass`` with ``RetryPolicy``'s backoff. It never re-sends a body that can
/// be read only once (`HTTPBody.IterationBehavior.single`); the Kit builds every body from
/// in-memory data, which is re-iterable.
///
/// No dependency: `laconicman/swift-concurrency-retry` (a fork of ph1ps's) retries thrown
/// errors, while a 429 or 5xx reaches a middleware as a returned response, and the substance
/// here is the per-operation classification, not the loop.
struct RetryMiddleware: Sendable {
    let policy: RetryPolicy
    let sleep: @Sendable (Duration) async throws -> Void

    /// The most of a retried response's body read to release its connection.
    static let maximumDrainBytes = 64 * 1024
}

extension RetryMiddleware: ClientMiddleware {
    // `@concurrent` is spelled out, as in `HeaderMiddleware`: this module enables
    // NonisolatedNonsendingByDefault (SE-0461), and OpenAPIRuntime requires a concurrent `next`.
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let retryClass = RetryClass(operationID: operationID)
        let replayable = body?.iterationBehavior != .single
        var retry = 0
        while true {
            let delay: Duration
            do {
                let (response, responseBody) = try await next(request, body, baseURL)
                guard replayable, retry < policy.maxRetries, !Task.isCancelled, retryClass.retries(status: response.status.code) else {
                    return (response, responseBody)
                }
                switch policy.retryAfter(response) {
                case .absent: delay = policy.backoff(retry: retry + 1)
                case .wait(let requested): delay = requested
                case .tooLong: return (response, responseBody)
                }
                // URLSessionTransport streams by default on Darwin (swift-openapi-urlsession 1.3.2,
                // `Implementation.platformDefault`), and an unread body keeps its task, and its
                // connection, suspended until the body is released. An error body is small, so it
                // is read to the end before the retry.
                if let responseBody { _ = try? await Data(collecting: responseBody, upTo: Self.maximumDrainBytes) }
            } catch {
                guard replayable, retry < policy.maxRetries, !Task.isCancelled, retryClass.retries(error: error) else {
                    throw error
                }
                delay = policy.backoff(retry: retry + 1)
            }
            retry += 1
            try await sleep(delay)
        }
    }
}
