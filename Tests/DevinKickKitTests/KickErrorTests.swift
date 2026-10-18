@testable import DevinKickKit
import Foundation
import Testing

@Suite("KickError and Configuration")
struct KickErrorTests {
    @Test func exitCodesFollowSysexits() {
        #expect(KickError.config("x").exitCode == 78)
        #expect(KickError.usage("x").exitCode == 64)
        #expect(KickError.transport("x").exitCode == 69)
        #expect(KickError.server(status: 429, code: nil, detail: "x").exitCode == 69)
        #expect(KickError.server(status: 503, code: nil, detail: "x").exitCode == 69)
        #expect(KickError.server(status: 404, code: nil, detail: "x").exitCode == 1)
        #expect(KickError.decoding("x").exitCode == 1)
    }

    @Test func serverErrorsQuoteTheDetailAndAHint() {
        let message = KickError.server(status: 401, code: "invalid_token", detail: "Token expired").localizedDescription
        #expect(message.contains("401: invalid_token: Token expired"))
        #expect(message.contains("DEVIN_API_KEY"))
    }

    @Test func anEmptyKeyIsAConfigError() {
        #expect(throws: KickError.self) {
            try Configuration.fromEnvironment(["DEVIN_API_KEY": "", "DEVIN_ORG_ID": "org-1"])
        }
    }

    /// `GET /v3/self` takes no organization, so a key alone is a valid configuration; the
    /// organization is demanded only where it is used (PR #1 review, r4306484532).
    @Test func aKeyAloneIsEnoughUntilAnOrganizationIsNeeded() throws {
        let configuration = try Configuration.fromEnvironment(["DEVIN_API_KEY": "cog_x"])
        #expect(configuration.orgID == nil)
        #expect(throws: KickError.self) { try configuration.requireOrgID() }
    }

    @Test func environmentIsRead() throws {
        let configuration = try Configuration.fromEnvironment([
            "DEVIN_API_KEY": "cog_x", "DEVIN_ORG_ID": "org-1", "KICK_SERVER_URL": "https://example.test",
        ])
        #expect(try configuration.requireOrgID() == "org-1")
        #expect(configuration.serverURL.absoluteString == "https://example.test")
    }

    /// A relative or clear-text override is a configuration error, not a transport error later,
    /// and the key never goes out over plain http except to loopback (PR #1 review, r4306484578,
    /// r4306484751).
    @Test(arguments: ["devin", "/v3", "http://api.devin.ai", "ftp://api.devin.ai", "https://"])
    func unsafeOrRelativeServerURLsAreRejected(_ override: String) {
        #expect(throws: KickError.self) {
            try Configuration.fromEnvironment(["DEVIN_API_KEY": "cog_x", "KICK_SERVER_URL": override])
        }
    }

    @Test(arguments: ["https://api.devin.ai", "http://localhost:8080", "http://127.0.0.1:9000"])
    func secureOrLoopbackServerURLsAreAccepted(_ override: String) throws {
        let configuration = try Configuration.fromEnvironment(["DEVIN_API_KEY": "cog_x", "KICK_SERVER_URL": override])
        #expect(configuration.serverURL.absoluteString == override)
    }
}
