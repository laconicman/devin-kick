# Review Guidelines

devin-kick wraps Devin's v3 REST API for the `kick` CLI and, from milestone M2, an MCP server.
`Sources/DevinKickKit/DevinKickKit.docc/Design.md` is authoritative; check changes against it.

## Critical Areas

- Flag a change to `Sources/DevinKickKit/Settlement.swift` that maps an unlisted `status`, or a
  `status_detail` on a status that carries none, to anything but `.unknown` with its raw value.
- Flag a change to `Sources/DevinKickKit/Settlement.swift` that returns `.done` after
  `suspended`/`user_request` or `waiting_for_approval` under any verdict, or after `exit` under
  any verdict but `.final`: output may be partial or stale there (TD-4).
- Flag a change to `Sources/DevinKickKit/Schema.swift` that reads `kick_final` as final while
  `questions_for_user` is non-empty, or that lets a schema without `kick_final` in `required`
  reach the API.
- Require a matching change to the README's exit-status table whenever an `exitCode` in
  `Sources/DevinKickKit/Settlement.swift` or `Sources/DevinKickKit/KickError.swift` changes.
- Require a matching change to the `discussion` text in `Sources/kick/KickCommand.swift`
  whenever an `exitCode` changes.
- Flag `Sources/DevinKickKit/Configuration.swift` accepting a `KICK_SERVER_URL` that is not
  `https`, except plain `http` to `localhost`, `127.0.0.1` or `::1`.
- Require the regenerated `Sources/DevinOpenAPI/openapi.yaml` in the same PR as any change to
  `Sources/devin-spec-tool/DevinSpecTool.swift`.
- Require the spec tool's second-run counts (`0 / 0 / 0 / 0`) in the PR body when
  `Sources/devin-spec-tool/DevinSpecTool.swift` changes: every transform must stay idempotent.
- Flag a FastAPI-style `handle_…` operation id in
  `Sources/DevinOpenAPI/openapi-generator-config.yaml`; use the spec tool's short ids.

## Conventions

- Flag a `public import DevinOpenAPI` anywhere in `Sources/DevinKickKit/`.
- Flag a public signature in `Sources/DevinKickKit/` that names a generated `Components.` or
  `Operations.` type; the Kit's API uses Kit types.
- Flag an untyped `throws` on a public function in `Sources/DevinKickKit/`; it must be
  `throws(KickError)`.
- Require `@concurrent` on async closure parameters in conformances to a dependency's protocol,
  such as `ClientMiddleware`: this module enables `NonisolatedNonsendingByDefault`.
- Flag an MCP tool handler (from M2) that returns `structuredOutput` or a message transcript in
  its result; return paths and compact status instead.
- Flag a wait inside an MCP tool longer than 240 s per call for `kick_wait`, or 120 s for
  `kick_check`.
- Flag an MCP tool name without the `kick_` prefix, or one shared by the side and main profiles.

## Anti-patterns to Flag

- Flag `String(describing:)` of a decoded payload inside a `KickError` message; render
  `code: detail` from `ProblemDetail`.
- Flag a `catch` in `Sources/DevinKickKit/` that drops the error or turns it into success.
- Reject `try!` and force unwraps outside `Tests/`, except `URL(string:)!` on a literal constant.

## Security

- Flag code that prints, logs or interpolates `Configuration.apiKey` or the `Authorization`
  header, including `KickError` messages and test output.
- Flag a real session, organization or user id in `Tests/DevinKickKitTests/Fixtures/`: fixtures
  are sanitized field records with zeroed ids.
- Flag, from M1, an upload path that skips the `KICK_UPLOAD_ROOTS` allowlist: uploads are
  permanent.

## Ignore

- Skip `Sources/DevinOpenAPI/openapi.yaml` unless `Sources/devin-spec-tool/DevinSpecTool.swift`
  changed or the PR says it re-vendors the spec.
- Skip `Package.resolved` unless a floor in `Package.swift` changed.
- Skip style in `Upstream/*.md`; review its facts only.
