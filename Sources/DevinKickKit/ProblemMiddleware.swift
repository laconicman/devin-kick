import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Reads every error status (400 and up) once, as the server's `ProblemDetail`, and throws it
/// as a ``ProblemResponse``, so every call site in the Kit reads only `.ok`.
///
/// Each of the 16 operations documents the same six error statuses (401, 403, 404, 409, 422,
/// 429), and anything else arrives as `.undocumented`. Switching over them per operation would
/// repeat one mapping a dozen times; here it is written once, and the message quotes
/// `code: detail` as Design requires. It sits outside ``RetryMiddleware``, so retries see the
/// raw status first.
struct ProblemMiddleware: Sendable {
    /// The most of an error body read: a problem document is small, an HTML error page isn't.
    static let maximumBodyBytes = 64 * 1024
}

/// An error status with what its body said, thrown by ``ProblemMiddleware``. The runtime wraps
/// it in a `ClientError`; ``KickError/init(clientError:)`` unwraps it.
struct ProblemResponse: Error, Sendable, Equatable {
    var status: Int
    var code: String?
    var detail: String
}

extension ProblemMiddleware: ClientMiddleware {
    // `@concurrent`: see `HeaderMiddleware`.
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code >= 400 else { return (response, responseBody) }
        var data = Data()
        if let responseBody {
            data = (try? await Data(collecting: responseBody, upTo: Self.maximumBodyBytes)) ?? Data()
        }
        throw Self.problem(status: response.status.code, body: data)
    }

    /// The fields of a problem document kick shows. Every field is optional, so FastAPI's bare
    /// `{"detail": "…"}` and a proxy's non-JSON page read too; `detail` may be a string or, for a
    /// validation error, a list.
    private struct Fields: Decodable {
        var title: String?
        var detail: Detail?
        var errorCode: String?
        var errors: [Issue]?

        enum CodingKeys: String, CodingKey {
            case title, detail, errors
            case errorCode = "error_code"
        }

        enum Detail: Decodable {
            case text(String)
            case issues([Issue])

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .issues(try container.decode([Issue].self))
                }
            }
        }

        /// One validation error: where (`loc`) and what (`msg`).
        struct Issue: Decodable {
            var loc: [Location]?
            var msg: String?

            var rendered: String? {
                guard let msg else { return nil }
                let path = loc?.map(\.text).joined(separator: ".") ?? ""
                return path.isEmpty ? msg : "\(path): \(msg)"
            }
        }

        /// A `loc` element: a field name or a list index.
        struct Location: Decodable {
            var text: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let index = try? container.decode(Int.self) {
                    text = String(index)
                } else {
                    text = try container.decode(String.self)
                }
            }
        }
    }

    /// The most validation issues quoted in one message.
    static let maximumIssues = 3

    static func problem(status: Int, body: Data) -> ProblemResponse {
        guard let fields = try? JSONDecoder().decode(Fields.self, from: body) else {
            return ProblemResponse(status: status, code: nil, detail: "no detail")
        }
        var issues = fields.errors ?? []
        var detail: String?
        switch fields.detail {
        case .text(let text): detail = text
        case .issues(let list): issues += list
        case nil: break
        }
        let rendered = issues.compactMap(\.rendered).prefix(maximumIssues)
        let parts = [detail].compactMap(\.self) + rendered
        return ProblemResponse(
            status: status,
            code: fields.errorCode,
            detail: parts.isEmpty ? (fields.title ?? "no detail") : parts.joined(separator: "; ")
        )
    }
}
