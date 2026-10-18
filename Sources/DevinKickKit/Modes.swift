import DevinOpenAPI
import Foundation

/// A Devin agent mode for a new session (amendment A3).
///
/// The one hard check is the request's own enum, the 8 values of the spec's
/// `SessionCreateRequest.devin_mode`. The organization's `available_devin_modes`
/// (`GET …/automations/schemas`) is documented for automations, evaluated as the organization's
/// automation identity, and optional in the response, so a mode missing from it only warns and
/// the server's answer decides (``ModeCatalog``).
public struct DevinMode: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    /// `swe-2-max`, unless the flag, a manifest entry or `KICK_MODE` says otherwise.
    public static let standard = DevinMode(payload: .swe2Max)

    /// Every mode the request accepts.
    public static var known: [String] {
        Components.Schemas.SessionCreateRequest.DevinModePayload.allCases.map(\.rawValue)
    }

    let payload: Components.Schemas.SessionCreateRequest.DevinModePayload

    init(payload: Components.Schemas.SessionCreateRequest.DevinModePayload) {
        self.payload = payload
        self.rawValue = payload.rawValue
    }

    /// A usage error listing the modes when `rawValue` isn't one of them.
    public init(_ rawValue: String) throws(KickError) {
        guard let payload = Components.Schemas.SessionCreateRequest.DevinModePayload(rawValue: rawValue) else {
            throw .usage("Unknown mode \"\(rawValue)\". Modes: \(Self.known.joined(separator: ", ")).")
        }
        self.init(payload: payload)
    }

    public var description: String { rawValue }

    /// The order (owner, 2026-10-18): the `--mode` flag, an explicit override for a whole batch;
    /// then a manifest entry's `mode`; then `KICK_MODE`, only a default; then ``standard``.
    public static func resolve(flag: DevinMode?, entry: DevinMode?, environment: DevinMode?) -> DevinMode {
        flag ?? entry ?? environment ?? standard
    }

    /// The label for a session's reported `devin_mode`: `nil` is an agent preview with no mode
    /// equivalent (the spec's `SessionResponse.devin_mode`).
    public static func label(_ reported: String?) -> String { reported ?? "preview/other" }
}

/// `available_devin_modes`, fetched once per process and used only to warn.
actor ModeCatalog {
    private enum State {
        case unread
        case listed(Set<String>)
        case unavailable
    }

    private var state = State.unread
    private var warned: Set<String> = []

    /// Warns (once per mode) when `mode` isn't in the organization's list, and once when the
    /// list can't be read; never fails, because the list is documented for automations.
    func check(_ mode: DevinMode, fetch: () async throws(KickError) -> [String]?, warn: RunStore.Warn) async {
        if case .unread = state {
            do {
                if let modes = try await fetch() {
                    state = .listed(Set(modes))
                } else {
                    state = .unavailable
                    warn("the organization's automation schemas list no available_devin_modes; the server checks the mode.")
                }
            } catch .decoding {
                // Live (2026-10-18) the answer carries fields the published spec doesn't list
                // under `additionalProperties: false`, which the generated decoder enforces.
                state = .unavailable
                warn("available_devin_modes can't be read: Devin's answer has fields its own spec closes out (TechDebt TD-8). The server checks the mode.")
            } catch {
                state = .unavailable
                warn("couldn't read available_devin_modes (\(error.localizedDescription)); the server checks the mode.")
            }
        }
        guard case .listed(let modes) = state, !modes.contains(mode.rawValue), warned.insert(mode.rawValue).inserted else {
            return
        }
        warn("\(mode) isn't in the organization's available_devin_modes (\(modes.sorted().joined(separator: ", "))), which is documented for automations; the server decides.")
    }
}

extension DevinKick {
    /// `GET …/automations/schemas` → `available_devin_modes`, if the response has it.
    func availableModes() async throws(KickError) -> [String]? {
        let orgID = try configuration.requireOrgID()
        return try await call(Operations.GetAutomationSchemas.id) {
            try await client.getAutomationSchemas(path: .init(orgId: orgID)).ok.body.json.availableDevinModes
        }
    }

    func checkMode(_ mode: DevinMode) async {
        await modes.check(mode, fetch: { () async throws(KickError) in try await availableModes() }, warn: warn)
    }
}
