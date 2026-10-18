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
    /// The run store's root (`KICK_STORE`): see ``RunStore``.
    public var storeURL: URL
    /// The directories uploads may come from (`KICK_UPLOAD_ROOTS`, colon-separated). `nil`
    /// when unset: then kick uploads nothing, because uploads are permanent.
    public var uploadRoots: [String]?

    public static let defaultServerURL = URL(string: "https://api.devin.ai")!

    /// `~/Library/Application Support/devin-kick`.
    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "devin-kick", directoryHint: .isDirectory)
    }

    public init(
        apiKey: String, orgID: String?, serverURL: URL = defaultServerURL, storeURL: URL = defaultStoreURL,
        uploadRoots: [String]? = nil
    ) {
        self.apiKey = apiKey
        self.orgID = orgID
        self.serverURL = serverURL
        self.storeURL = storeURL
        self.uploadRoots = uploadRoots
    }

    /// Reads `DEVIN_API_KEY`, and optionally `DEVIN_ORG_ID`, `KICK_SERVER_URL`, `KICK_STORE` and
    /// `KICK_UPLOAD_ROOTS`.
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
        var storeURL = defaultStoreURL
        if let store = environment["KICK_STORE"], !store.isEmpty {
            storeURL = URL(fileURLWithPath: NSString(string: store).expandingTildeInPath, isDirectory: true)
        }
        let uploadRoots = environment["KICK_UPLOAD_ROOTS"]
            .map { $0.split(separator: ":").map { NSString(string: String($0)).expandingTildeInPath } }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Configuration(apiKey: apiKey, orgID: orgID, serverURL: serverURL, storeURL: storeURL, uploadRoots: uploadRoots)
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
