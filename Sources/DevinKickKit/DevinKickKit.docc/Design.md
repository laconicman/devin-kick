# Design

The load-bearing decisions, why they were made, and what was rejected.

## Overview

One decision per subsection. This article is authoritative: when a code comment and this
document disagree, this document wins. Milestones live in <doc:Roadmap>, known compromises in
<doc:TechDebt>.

The decisions draw on field use of Devin from Claude Code on 2026-10-14: nine `swe-2-max`
sessions run over the REST API and over Devin's own MCP server. They also draw on the sibling
connector laconicman/deepwiki-mcp, whose lessons are cited by its TechDebt ids.

### The official spec, vendored and normalized

The client is generated at build time from Devin's **official** OpenAPI 3.1 document, vendored in
`Sources/DevinOpenAPI/openapi.yaml` and filtered to the 16 operations the connector uses. Nothing
generated is committed. The document is FastAPI's output and does not generate as published, so
`swift run devin-spec-tool` normalizes it with three idempotent transforms:

1. `anyOf: [X, {type: null}]` → `X`, and the field leaves `required`. As published, the generator
   skips every path parameter and the client doesn't compile (<doc:TechDebt> TD-2, TD-3).
2. `enum` is dropped from every schema reachable from a response, so a status, detail or mode
   Devin adds later can't fail decoding. Request-side enums stay.
3. `handle_create_session_v3_…_post` → `create_session`, so the façade reads `createSession`.

The tool stamps the source URL, the raw document's sha256 and the date under `info.x-devin-kick`.

*Rejected:*
- **A handwritten client:** no pinned contract, so drift hides.
- **The raw document plus `typeOverrides`:** 733 nullable `anyOf`s are too many to override one by
  one.
- **A Python normalizer:** a second toolchain in a Swift repository.

### One binary, two faces, three layers

`DevinOpenAPI` (generated) → `DevinKickKit` (façade) → `kick` (argument parsing, and from M2 the
MCP server). The façade never imports `ArgumentParser` or `MCP`, and the executable never talks
HTTP. `InternalImportsByDefault` makes the layering a compiler rule: the Kit's public API uses its
own types (``Principal``, ``Settlement``, ``KickError``), and a generated type can only leak
through an explicit `public import`.

*Rejected:*
- **Separate CLI and server binaries:** two artifacts to version and register, and drift between
  them (deepwiki-mcp's "beads lesson").
- **Re-exporting the generated types:** it couples every caller to FastAPI's names.

### Settlement: one file reads the lifecycle

``Settlement`` is the only code that interprets `status` / `status_detail`. Its rules come from
the field:
- **Done is usually `waiting_for_user` with output set,** not `finished`.
- **A finished session left idle sleeps (`suspended`/`inactivity`) with its output intact,** so
  that counts as done.
- **`waiting_for_approval` is input needed,** even when output exists.
- **A billing or quota suspension is a failure.**
- **Anything outside the vocabulary of the vendored spec is `unknown`, shown raw,** never guessed
  as working.

Each case has an exit status that `kick --help` documents: 0 done, 10 needs input, 11 unknown,
75 working, 1 failed.

*Rejected:* deepwiki-mcp's stabilization fingerprint. It existed because that API had no
lifecycle; Devin's has one.

### Every session carries a schema

A session started without a `schema_file` gets a default one:
`{answer_md, doubts, questions_for_user}`. Then "waiting with output" always means done, and
"waiting without output" always means Devin is asking (owner's decision, 2026-10-18).

*Rejected:* `structured_output_required: false`. A session that is really asking would look
finished, unless its last message were parsed.

### Typed errors that name the next step

Every Kit API throws ``KickError`` (`throws(KickError)`), so the CLI maps each case to an exit
status exhaustively: 78 config, 64 usage, 69 transport, 429 or 5xx (retry), 1 otherwise. Messages
quote the server's `ProblemDetail` as `code: detail` and add the next step. They never print
`String(describing:)` of a payload; deepwiki-mcp TD-9 shipped `[Optional(3000), …]` that way.

*Rejected:* untyped `throws` with a catch-all exit 1. A shell loop then can't tell "retry" from
"stop", which is deepwiki-mcp TD-10.

### Explicit `@concurrent` at module boundaries

The handwritten targets enable the Swift 7 upcoming features that Swift 6.4 offers. Under
`NonisolatedNonsendingByDefault` (SE-0461), a bare async closure type means
`nonisolated(nonsending)` in this module but concurrent in a dependency compiled without the
flag. So conformances to a dependency's protocols spell `@concurrent` explicitly; see
`HeaderMiddleware`.

*Rejected:* leaving the flag off. The first conformance would have compiled, and the semantics
of every later async API would have diverged silently.

### Short calls and handles, never long blocking calls

Devin sessions run for minutes to hours, and Claude Code aborts an MCP call that is silent for
300 s. So starting a session returns its id at once, the run is recorded at submit, and every
wait is bounded per call (≤ 240 s) and simply called again. deepwiki-mcp TD-7 found this beats a
progress heartbeat, which needs the client's `progressToken` and wasn't reliable; there is none
here.

*Rejected:* a blocking "run and wait" MCP tool. The CLI's `kick run` may loop, because a shell
has no idle limit.

### Approvals: bypassed by default, by a human's choice only

`bypass_approval` is `true` by default. Only a person changes it, with the CLI flag or the
environment at `serve` launch; no MCP tool exposes it. An approval wait that happens anyway is
reported as input needed (owner's decision, 2026-10-18).

### A name distinct from the service

The package is `devin-kick`, the binary `kick`, and the MCP tools `kick_*`, deliberately not
"Devin". The official Devin MCP server is registered beside it, and Claude Desktop merges
connectors that share a display name (deepwiki-mcp TD-6). The two profiles' tool names are
disjoint too, so mounting both by mistake cannot collide.

*Rejected:* `devin` as the binary or tool prefix. It collides with the official server, and
perhaps with a CLI Cognition ships.

## See Also

- <doc:Roadmap>
- <doc:TechDebt>
