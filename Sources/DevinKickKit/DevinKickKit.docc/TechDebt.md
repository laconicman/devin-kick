# TechDebt

Numbered register of known compromises. Code references an item as `TODO(TD-n)`.

## Overview

Each item states its **Cost** (what it hurts today) and **Discharge** (the change that retires
it). Status: **open** or **discharged**; ids are never reused. Ready-to-file drafts for the
upstream ones are in the repository's `Upstream/` folder.

### TD-1 — warnings in the generated sources — *open*

Tracked in [#5](https://github.com/laconicman/devin-kick/issues/5).

swift-openapi-generator 1.14.1 under Swift 6.4 writes `public import Foundation` and
`public import OpenAPIRuntime` into generated files that don't use them publicly. That gives
about 30 `UnusedImportAccess` warnings per clean build. SwiftPM 6.4 can't silence them:
`WarningLevel` has only `.warning` and `.error`.

**Cost:** the no-warnings gate covers the handwritten targets only, so a real warning in the
generated target would hide among these.

**Discharge:** raise the generator floor to the release that ships apple/swift-openapi-generator
PR #947 (fixing #946; #968 was its duplicate), then hold the generated target to zero too.

### TD-2 — generator emits code for a parameter it skipped — *open (upstream)*

Tracked in [#3](https://github.com/laconicman/devin-kick/issues/3).

A path parameter whose schema the generator skips as unsupported (a nullable `anyOf`) still
appears as `input.path.<name>` in `Client.swift`, a compile error in generated code instead of a
generation-time diagnostic. Reproduced with a one-operation document on 1.14.1.

**Cost:** the build depends on `devin-spec-tool`'s nullable transform; drop it, and the build
fails with a message pointing at generated code.

**Discharge:** file `Upstream/generator-skipped-path-parameter.md`. Once fixed upstream, the
transform stays (TD-3), but a regression would fail clearly.

### TD-3 — Devin's document types path parameters as nullable — *open (upstream)*

Tracked in [#4](https://github.com/laconicman/devin-kick/issues/4).

Every path parameter is `anyOf: [{type: string}, {type: null}]` with `required: true`, FastAPI's
rendering of `Optional[str]`. Transform 1 of `devin-spec-tool` rewrites it.

**Cost:** one more transform to maintain on every re-vendor.

**Discharge:** send `Upstream/devin-nullable-path-parameters.md`. When the document is fixed,
the transform reports 0 for parameters and can be narrowed to response fields.

### TD-4 — output is not proof of completion — *discharged*

Tracked in [#2](https://github.com/laconicman/devin-kick/issues/2).

`structured_output` can be set while a session still works, and the API never shows whether an
output was meant as final: with `structured_output_required: true` the agent must provide output
before *every* turn ends. M0 therefore trusted output only where Devin stopped by itself, and
read `exit` with output as `unknown` (PR #1 review, r4306484713).

**Cost (until M1):** with a custom schema, "waiting with output" could be a question; `kick`
couldn't tell an interrupted session's partial output from a final one.

**Discharge:** done in M1.
- Every schema kick sends gains a required boolean `kick_final`, and ``Settlement`` reads an
  ``OutputVerdict``: `final`, `stale-final` (kick replied since), `provisional` (false, or a
  non-empty `questions_for_user`), `none`, `unmarked` (a session kick didn't create, read as M0
  read any output). `exit` or a pause (`suspended`/`user_request`) with a final output is done.
- The live check (2026-10-18): an asking turn *does* provide output, `kick_final: false` with the
  question in `questions_for_user` and `answer_md` empty; after a reply the answer came back
  final, and terminated, it read `exit` + `stale-final`, so unknown.
- The residual, accepted by the owner: `kick_final` is the last completed turn's declaration. A
  reply posted outside kick (in the web app), then an end or a pause mid-turn, leaves the old
  final in place and reads as done.

### TD-5 — CI's swift.org toolchain trial — *discharged*

Tracked in [#7](https://github.com/laconicman/devin-kick/issues/7).

CI first ran on `macos-26` with a swift.org 6.4 toolchain from `swift-actions/setup-swift@v2`,
because `macos-26` tops out at Xcode 26.6. The first run failed at setup with
`Version "6.4" is not available`. The action installs from a version table in its own bundle,
its latest release (2.4.0) predates Swift 6.4, and its fix (swift-actions/setup-swift#806) is
unreviewed.

**Cost:** PR #1's CI was red before it built anything.

**Discharge:** done in PR #1. GitHub ships Xcode 27 as a separate image, `xcode-27`, generally
available since 2026-10-15, whose default Xcode 27.0 (27A266a) is the local build. CI runs there
on the image's own toolchain, with no setup step.

### TD-6 — the create shield is an unstructured task — *open*

Tracked in [#8](https://github.com/laconicman/devin-kick/issues/8).

A start's POST and its recording must finish even when the caller is cancelled. SE-0504's
`withTaskCancellationShield` is `@available(anyAppleOS 27.0, *)` (the Xcode 27 SDK's
`_Concurrency.swiftinterface`), and the floor is macOS 15, so `start` runs that stretch in an
unstructured `Task` whose value is awaited: cancelling the awaiting task doesn't propagate into it.

**Cost:** an unstructured task where a structured shield would say what it means; `TODO(TD-6)` in
`Start.swift`.

**Discharge:** once the floor reaches macOS 27, use `withTaskCancellationShield`, keeping the test
that cancels a caller mid-POST and finds the run recorded.

### TD-7 — a lost create answer can still duplicate — *open (upstream)*

Tracked in [#9](https://github.com/laconicman/devin-kick/issues/9).

Create has no idempotency key. The spec lists an optional `devin_id` query parameter on create
without describing it, and the server ignores it (probed live 2026-10-18: a fresh id came back
server-minted in both formats, and a replay created a second session). After a lost answer kick lists by run tag twice, 15 s apart, before creating again
(<doc:Design>, "Never lost; duplicates found, not prevented").

**Cost:** a session that appears in the listing more than 15 s after its lost answer is duplicated.
Nothing documents how soon a new session is listed. Duplicates are found and shown, not prevented.

**Discharge:** Devin ships an idempotency key or a client-chosen session id on create, and kick
sends it.

### TD-8 — automation schemas never decode — *discharged*

Tracked in [#10](https://github.com/laconicman/devin-kick/issues/10).

Live (2026-10-18), `GET …/automations/schemas` answers with `oncall` and `preflight_available`,
which the published spec doesn't list, while it declares `AutomationSchemasResponse` and eight
schemas it reaches `additionalProperties: false`. The generated decoder enforces that
(`ensureNoAdditionalProperties`), so the answer can't be read. The published document is
byte-identical to the vendored one, so re-vendoring changes nothing. Sessions, messages,
attachments and pages are open and unaffected.

**Cost (until the fix):** the warn-only `available_devin_modes` check could never read the list;
every process that started a session warned once.

**Discharge:** done in M1's second pull request (owner, 2026-10-18). `devin-spec-tool`'s fourth
transform drops `additionalProperties: false` from every response-reachable schema, in transform
2's walk: 50 schemas, and a second run reports `0 / 0 / 0 / 0 / 0`. Live, the answer decodes and
lists the modes (`LiveSmoke`). The feedback for Cognition is still drafted in
`Upstream/devin-closed-automation-schemas.md`, unsent: a schema they close later would be opened
on the next re-vendor anyway.

## See Also

- <doc:Design>
- <doc:Roadmap>
