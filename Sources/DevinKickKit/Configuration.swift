public import Foundation

/// Credentials and endpoints, read from the environment. The key comes from `DEVIN_API_KEY`
/// (a `cog_` personal access token or service-user key) and is never read from a file.
public struct Configuration: Sendable {
    public var apiKey: String
    public var orgID: String
    /// The spec declares no `servers`, so the base URL is ours to supply.
    public var serverURL: URL

    public static let defaultServerURL = URL(string: "https://api.devin.ai")!

    public init(apiKey: String, orgID: String, serverURL: URL = defaultServerURL) {
        self.apiKey = apiKey
        self.orgID = orgID
        self.serverURL = serverURL
    }

    /// Reads `DEVIN_API_KEY` and `DEVIN_ORG_ID`, and optionally `KICK_SERVER_URL`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(KickError) -> Configuration {
        // An empty key is the classic failure: `export` in one terminal never reaches an agent's
        // shell, and the API then answers a misleading 403 (Devin-API recipe, §2.3).
        guard let apiKey = environment["DEVIN_API_KEY"], !apiKey.isEmpty else {
            throw .config("DEVIN_API_KEY is empty in this environment. Export it from ~/.zshenv, which every zsh reads.")
        }
        guard let orgID = environment["DEVIN_ORG_ID"], !orgID.isEmpty else {
            throw .config("DEVIN_ORG_ID is empty in this environment. It is the org-… id at the top of Settings > Devin API.")
        }
        var serverURL = defaultServerURL
        if let override = environment["KICK_SERVER_URL"], !override.isEmpty {
            guard let url = URL(string: override) else { throw .config("KICK_SERVER_URL is not a URL: \(override)") }
            serverURL = url
        }
        return Configuration(apiKey: apiKey, orgID: orgID, serverURL: serverURL)
    }
}
