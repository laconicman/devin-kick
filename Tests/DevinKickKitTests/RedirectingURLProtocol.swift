import Foundation
import Synchronization

/// A `URLProtocol` for attachment downloads: the API host answers 307 to a "presigned" host,
/// which serves the bytes. Each test uses its own hosts, so parallel tests don't share routes.
final class RedirectingURLProtocol: URLProtocol {
    struct Route: Sendable {
        var status = 200
        var body = Data()
        /// Set for a redirect.
        var location: URL?
    }

    static let routes = Mutex<[String: Route]>([:])
    /// Every request the protocol saw, in order.
    static let seen = Mutex<[URLRequest]>([])

    static func requests(to host: String) -> [URLRequest] {
        seen.withLock { $0.filter { $0.url?.host() == host } }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        guard let url = request.url,
              let route = Self.routes.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let location = route.location {
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])
            var redirected = request
            redirected.url = location
            guard let response else { return }
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // Followed, the system starts a new load and drops this one. Declined (the delegate
            // returns nil), URLSession delivers the redirect response itself as the answer, so
            // the load finishes with it, as a real HTTP load does.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
