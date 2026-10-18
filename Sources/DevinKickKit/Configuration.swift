public import Foundation

/// Credentials and endpoints, read from the environment. The key comes from `DEVIN_API_KEY`
/// (a `cog_` personal access token or service-user key) and is never read from a file.
public struct Configuration: Sendable {
    public var apiKey: String
    /// The organization for organization-scoped calls. `GET /v3/self` needs none, so the
    /// identity check works with a key alone; every other call asks for it via ``requireOrgID()``.
    public var orgID: String?
    /// The spec declares no `servers`, so the base URL is ours to supply.
    public var serverURL: URL

    public static let defaultServerURL = URL(string: "https://api.devin.ai")!

    public init(apiKey: String, orgID: String?, serverURL: URL = defaultServerURL) {
        self.apiKey = apiKey
        self.orgID = orgID
        self.serverURL = serverURL
    }

    /// Reads `DEVIN_API_KEY`, and optionally `DEVIN_ORG_ID` and `KICK_SERVER_URL`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(KickError) -> Configuration {
        // An empty key is the classic failure: `export` in one terminal never reaches an agent's
        // shell, and the API then answers a misleading 403 (Devin-API recipe, §2.3).
        guard let apiKey = environment["DEVIN_API_KEY"], !apiKey.isEmpty else {
            throw .config("DEVIN_API_KEY is empty in this environment. Export it from ~/.zshenv, which every zsh reads.")
        }
        let orgID = environment["DEVIN_ORG_ID"].flatMap { $0.isEmpty ? nil : $0 }
        var serverURL = defaultServerURL
        if let override = environment["KICK_SERVER_URL"], !override.isEmpty {
            serverURL = try validatedServerURL(override)
        }
        return Configuration(apiKey: apiKey, orgID: orgID, serverURL: serverURL)
    }

    /// The organization id, or a configuration error naming the variable to set.
    public func requireOrgID() throws(KickError) -> String {
        guard let orgID else {
            throw .config("DEVIN_ORG_ID is empty in this environment. Organization-scoped calls need it: the org-… id at the top of Settings > Devin API.")
        }
        return orgID
    }

    /// An override must be an absolute `https` URL, so the Bearer key never travels in clear
    /// text. Plain `http` is accepted only on loopback, for a local mock server.
    static func validatedServerURL(_ string: String) throws(KickError) -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty else {
            throw .config("KICK_SERVER_URL must be an absolute URL such as https://api.devin.ai, not \(string)")
        }
        switch scheme {
        case "https":
            return url
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()):
            return url
        default:
            throw .config("KICK_SERVER_URL must use https (plain http only on localhost), so the key is never sent in clear text: \(string)")
        }
    }
}
