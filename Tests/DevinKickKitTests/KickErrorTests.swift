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
        #expect(throws: KickError.self) {
            try Configuration.fromEnvironment(["DEVIN_API_KEY": "cog_x"])
        }
    }

    @Test func environmentIsRead() throws {
        let configuration = try Configuration.fromEnvironment([
            "DEVIN_API_KEY": "cog_x", "DEVIN_ORG_ID": "org-1", "KICK_SERVER_URL": "https://example.test",
        ])
        #expect(configuration.orgID == "org-1")
        #expect(configuration.serverURL.absoluteString == "https://example.test")
    }
}
