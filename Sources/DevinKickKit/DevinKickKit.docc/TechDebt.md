# TechDebt

Numbered register of known compromises. Code references an item as `TODO(TD-n)`.

## Overview

Each item states its **Cost** (what it hurts today) and **Discharge** (the change that retires
it). Status: **open** or **discharged**; ids are never reused. Ready-to-file drafts for the
upstream ones are in the repository's `Upstream/` folder.

### TD-1 — warnings in the generated sources — *open*

swift-openapi-generator 1.14.1 under Swift 6.4 writes `public import Foundation` and
`public import OpenAPIRuntime` into generated files that don't use them publicly. That gives
about 30 `UnusedImportAccess` warnings per clean build. SwiftPM 6.4 can't silence them:
`WarningLevel` has only `.warning` and `.error`.

**Cost:** the no-warnings gate covers the handwritten targets only, so a real warning in the
generated target would hide among these.

**Discharge:** raise the generator floor to the release that ships apple/swift-openapi-generator
PR #947 (fixing #946; #968 was its duplicate), then hold the generated target to zero too.

### TD-2 — generator emits code for a parameter it skipped — *open (upstream)*

A path parameter whose schema the generator skips as unsupported (a nullable `anyOf`) still
appears as `input.path.<name>` in `Client.swift`, a compile error in generated code instead of a
generation-time diagnostic. Reproduced with a one-operation document on 1.14.1.

**Cost:** the build depends on `devin-spec-tool`'s nullable transform; drop it, and the build
fails with a message pointing at generated code.

**Discharge:** file `Upstream/generator-skipped-path-parameter.md`. Once fixed upstream, the
transform stays (TD-3), but a regression would fail clearly.

### TD-3 — Devin's document types path parameters as nullable — *open (upstream)*

Every path parameter is `anyOf: [{type: string}, {type: null}]` with `required: true`, FastAPI's
rendering of `Optional[str]`. Transform 1 of `devin-spec-tool` rewrites it.

**Cost:** one more transform to maintain on every re-vendor.

**Discharge:** send `Upstream/devin-nullable-path-parameters.md`. When the document is fixed,
the transform reports 0 for parameters and can be narrowed to response fields.

### TD-4 — output is not proof of completion — *open*

`structured_output` can be set while a session still works. Field use on 2026-10-14 saw partial
output inlined for sessions in `working`. Settlement therefore trusts output only where Devin
stopped by itself, and reports `exit` with output as `unknown` and a person's pause as input
needed (PR #1 review, r4306484713). Two cases remain:
- a session that reports output and then asks a question reads as done;
- whether Devin, with `structured_output_required: true`, provides output before asking is
  unobserved.

**Cost:** with a custom schema, "waiting with output" can be a question rather than a result. And
`kick` can't tell an interrupted session's partial output from a final one.

**Discharge (M1):**
- kick adds its own completion field to every schema it sends, and Settlement reads it. With the
  default schema, a non-empty `questions_for_user` also means input needed.
- A live check records what an asking session's output looks like, and what a terminated one's
  does.

## See Also

- <doc:Design>
- <doc:Roadmap>
