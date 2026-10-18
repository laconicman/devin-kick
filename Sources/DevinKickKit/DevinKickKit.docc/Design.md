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

1. `anyOf: [X, {type: null}]` → `X` with `type: [T, "null"]`, 3.1's own spelling of nullable,
   which the generator reads as `T?`. `required` stays as the spec says. A nullable `$ref` has no
   such spelling, so only those (6 fields) become the bare `$ref` and leave `required`. As
   published, the generator skips every path parameter and the client doesn't compile
   (<doc:TechDebt> TD-2, TD-3).
2. `enum` is dropped from every schema reachable from a response, so a status, detail or mode
   Devin adds later can't fail decoding. The generator's string enums are closed, with no catch-all
   case. Request-side enums stay.
3. `handle_create_session_v3_…_post` → `create_session`, so the façade reads `createSession`.

The tool stamps the source URL, the raw document's sha256 and the date under `info.x-devin-kick`.
A field made optional encodes with `encodeIfPresent`, so it is omitted, never sent as `null`.

*Rejected:*
- **A handwritten client:** no pinned contract, so drift hides.
- **The raw document plus `typeOverrides`:** 733 nullable `anyOf`s are too many to override one by
  one.
- **Making every nullable field non-required:** the generated Swift is the same `T?` (verified),
  but it misstates the contract for any other reader. The first cut did this; a DeepWiki review
  before the first PR showed the better spelling.
- **The generator's "open enum" pattern** (`anyOf: [{enum}, {type: string}]`): it keeps
  known-case checking, but turns every such field into a `value1`/`value2` wrapper, and
  ``Settlement`` owns that vocabulary anyway.
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

``Settlement`` is the only code that interprets `status` / `status_detail`. It reads them with an
``OutputVerdict``, because output alone is not proof of completion (<doc:TechDebt> TD-4): with
`structured_output_required: true` the agent must provide output before *every* turn ends, and
live (2026-10-18) an asking turn did, with `kick_final: false`. The verdict comes from kick's own
field (next section) and the run store's `replied` events:
- `final`: `kick_final` is true and `questions_for_user` is empty;
- `stale-final`: final, but kick posted a reply since, so the session may have stopped mid-turn
  with the previous turn's declaration in place (owner, 2026-10-18);
- `provisional`: `kick_final` is false, or `questions_for_user` is not empty;
- `none`: no output;
- `unmarked`: output without `kick_final` (a session kick didn't create), read as M0 read any
  output.

| Status / detail | final | stale-final | provisional | none | unmarked |
|---|---|---|---|---|---|
| running / waiting_for_user | done | done | needs input | needs input | done |
| running / waiting_for_approval | needs input | needs input | needs input | needs input | needs input |
| running / working, or no detail | working | working | working | working | working |
| running / finished | done | done | unknown | failed | done |
| suspended / inactivity | done | done | needs input | needs input | done |
| suspended / user_request | done | unknown | needs input | needs input | needs input |
| suspended / a limit | failed | failed | failed | failed | failed |
| exit | done | unknown | failed | failed | unknown |
| error | failed | failed | failed | failed | failed |
| new, claimed, resuming | working | working | working | working | working |

The rules behind it come from the field:
- **Done is usually `waiting_for_user` with a final output,** not `finished`.
- **A finished session left idle sleeps (`suspended`/`inactivity`) with its output intact,** so
  that counts as done.
- **An approval wait beats any verdict.**
- **An end (`exit`) or a pause (`suspended`/`user_request`) is done only with a final output.**
  kick's own archive puts a done session to sleep as `suspended`/`user_request` (verified live),
  so a pause reads as an end does (owner, 2026-10-18). Without kick's field the output may be
  partial, so `unmarked` stays unknown or needs input there. The residual: a reply posted outside
  kick, then a stop mid-turn, leaves the old final in place.
- **A billing or quota suspension is a failure.**
- **Anything outside the vocabulary of the vendored spec is `unknown`, shown raw,** never guessed
  as working. That includes a detail on a status the vocabulary gives none (`new`, `claimed`,
  `resuming`, `exit`).

Each case has an exit status that `kick --help` documents: 0 done, 10 needs input, 11 unknown,
75 working, 1 failed. ``ExitStatus`` holds the table once; `--help` prints it, and a test holds
the README to it.

*Rejected:*
- deepwiki-mcp's stabilization fingerprint. It existed because that API had no lifecycle; Devin's
  has one.
- `structured_output_required: false`: then "waiting with output" stops meaning anything.

### Every session carries a schema, and kick's completion field

A session started without a `schema_file` gets a default one:
`{answer_md, doubts, questions_for_user}` (owner's decision, 2026-10-18). Whichever schema is
sent gains a required boolean `kick_final`: "true only when this output is your final result;
false while you are asking, blocked, or stopping early" (``Schema``). The schema's root must be a
plain `type: object`, since a composed root can't take a merged property; a root of any other kind,
one that already defines `kick_final`, or one over the API's 64 KB once augmented is a usage error.

`schema_file` is kick's own input: a path to a JSON Schema file, on the CLI and on the side
profile's `kick_start`. The Kit reads it and sends its content as the API's
`structured_output_schema`. It leaves `structured_output_required` at the server's default,
`true`.

*Rejected:* `structured_output_required: false`. A session that is really asking would look
finished, unless its last message were parsed.

### Several sessions, one exit status

`status`, `wait` and `run` exit with the worst session's status, by an explicit rank: failed >
unknown > needs input > working > done. It is not numeric order, since 75 outranks nothing. A
session whose status can't be read prints its error; alone it exits with that error's status, in a
batch it ranks as unknown. Reading, the status line and the rank live in the Kit, where tests
reach them and M2's server reuses them; the executable keeps only the ArgumentParser glue
(deepwiki-mcp's untested-executable lesson).

### Typed errors that name the next step

Every Kit API throws ``KickError`` (`throws(KickError)`), so the CLI maps each case to an exit
status exhaustively: 78 config, 64 usage, 69 transport, 429 or 5xx (retry), 73 the run store
couldn't record a run (EX_CANTCREAT, not retryable), 1 otherwise, including a reply to a session
that has ended. Messages quote the server's `ProblemDetail` as `code: detail` and add the next
step. They never print `String(describing:)` of a payload; deepwiki-mcp TD-9 shipped
`[Optional(3000), …]` that way.

Every operation documents the same six error statuses, so `ProblemMiddleware` reads the problem
document once (FastAPI's bare `detail` and validation lists included) and throws it; call sites
read only `.ok`, and the generated per-status cases go unused.

*Rejected:* untyped `throws` with a catch-all exit 1. A shell loop then can't tell "retry" from
"stop", which is deepwiki-mcp TD-10.

### Explicit `@concurrent` at module boundaries

The handwritten targets enable the Swift 7 upcoming features that Swift 6.4 offers. Under
`NonisolatedNonsendingByDefault` (SE-0461), a bare async closure type means
`nonisolated(nonsending)` in this module but concurrent in a dependency compiled without the
flag. So conformances to a dependency's protocols spell `@concurrent` explicitly; see
`HeaderMiddleware`. The rule also covers Foundation's: without the spelling on
`URLSessionTaskDelegate`'s async redirect method, swiftc 6.4 (swiftlang-6.4.0.34.1) crashes in
SILGen on its Objective-C thunk instead of diagnosing anything.

*Rejected:* leaving the flag off. The first conformance would have compiled, and the semantics
of every later async API would have diverged silently.

### Short calls and handles, never long blocking calls

Devin sessions run for minutes to hours, and Claude Code aborts an MCP call that is silent for
300 s. So starting a session returns its id at once, the run is recorded at submit, and every
wait is bounded per call (≤ 240 s) and simply called again. deepwiki-mcp TD-7 found this beats a
progress heartbeat, which needs the client's `progressToken` and wasn't reliable; there is none
here.

`wait` polls 15 s, backing off by half to 60 s (deepwiki-mcp's `PollingPolicy` mechanics, not its
constants), and races each GET against the remaining budget, so one hung request can't break the
bound; deepwiki-mcp checked its deadline only between polls. A 429, a 5xx or no answer inside a
wait is transient, never terminal.

*Rejected:* a blocking "run and wait" MCP tool. The CLI's `kick run` may loop, because a shell
has no idle limit: it polls the same way within `--budget` (default 3 h), saves, and archives the
sessions that are done.

### Approvals: bypassed by default, by a human's choice only

`bypass_approval` is `true` by default. Only a person changes it, with the CLI flag or the
environment at `serve` launch; no MCP tool exposes it. An approval wait that happens anyway is
reported as input needed (owner's decision, 2026-10-18).

### Retries by idempotency

Transport errors, 429 and 5xx retry (amendment A2): four retries, after about 1, 2, 4 and 8 s,
each spread ±20 % so parallel callers don't retry in lockstep, and `Retry-After` honored up to
60 s when sent; a longer one surfaces the 429. v3 documents no `Retry-After` and publishes no
limits. `RetryMiddleware` decides by operation id:
- **Idempotent** (every GET, archive, unarchive, the tag PUT, terminate): transport errors, 429 and
  5xx. A repeated terminate of a session that has exited answers 400 (live), so `archive` reads
  the session before calling that a failure.
- **Session create, message post, upload, the tag POST:** a repeat could act twice, so only a 429
  (the request wasn't processed) and an error where the request provably never left
  (`cannotConnectToHost`, `cannotFindHost`, `dnsLookupFailed`, `notConnectedToInternet`). Create
  reconciles by run tag after anything else (next section).

Inside a middleware a transport failure is a `ClientError` whose `underlyingError` is the raw
`URLError`: the runtime's `makeError` unwraps `transportFailed` (swift-openapi-runtime 1.13.1,
`UniversalClient.send`; DeepWiki read it otherwise, and the source won). The Kit builds every body
from in-memory data, which is re-iterable, and the middleware never re-sends a body that reads
once.

*Rejected:* `laconicman/swift-concurrency-retry` (a fork of ph1ps's). It retries thrown errors,
while a 429 or a 5xx reaches a middleware as a returned response, and the substance here is the
per-operation classification, not the loop.

### Never lost; duplicates found, not prevented

Create has no idempotency key, and the undocumented `devin_id` query parameter is ignored: a live
probe (2026-10-18) got server-minted ids back in both formats, and a replay created a second
session. So a start is recorded before its POST, in a pinned order: upload the attachments, mint
the run id (`yyyyMMdd-HHmmss-xxxx`, re-minted if the index holds it, since four hex digits collide
within a second at batch sizes), write `request.json`, append `requested`, POST, write
`session.json`, append `created`. Every session carries the tags `kick` and `kick-run-<id>`.
- A run with `requested` and no `created` is an orphan, found again by its run tag at lookup
  (`status`, `list`) and before a create is retried. An orphan still unlisted past the settle
  window is concluded as never created, so it isn't listed forever.
- After a transport error, a 5xx or an unreadable 2xx, kick lists by run tag, again 15 s later if
  that is empty, and creates again only if both are empty; if it can't list, it creates nothing
  more. The residual race is TD-7.
- Two or more sessions under one run tag: the earliest `created_at` is the run's session (the id
  breaks a tie); the others are recorded and shown, never hidden. Tags are user-editable, so a
  foreign session can collide too.
- A 429 or a refusal is recorded as the run's failure, so the run is no orphan.
- Ctrl-C kills the process, so the record written before the POST is what makes "never lost"
  hold. The POST and its recording also run in an unstructured `Task` whose value is awaited, so a
  cancelled caller (M2's server) can't interrupt them; `withTaskCancellationShield` needs macOS 27
  (TD-6).

*Rejected:* retrying a create blindly; and a client-minted `devin_id`, which the server ignores.

### The run store

`KICK_STORE` (default `~/Library/Application Support/devin-kick`) holds a directory per run,
`runs/<date>-<slug>-<run id>/` with `request.json`, `session.json`, `result.json`,
`messages.json` and `attachments/`, and an append-only `index.jsonl` of events: `requested`,
`created`, `replied`, `settled`, `failed`, `archived`, `unarchived`. Every event carries the whole
record (run id, session id, mode, title, every tag, directory, `resumable`), so `list --tag` works
from the index alone; it is read once into a map by run id and session id (``RunState``). `--out`
places run directories elsewhere; the index stays central and records absolute paths.
- `request.json` and the index throw ``KickError/store(_:)``, because an unrecorded run can be
  lost; derived files only warn, because `save` rewrites them, and recreates a deleted run
  directory (not `request.json`, the submit record).
- The store and its run directories are `0700`: they hold prompts and attachments.
- An actor serializes writes in one process. Across processes each index line is one `write(2)`
  on an `O_APPEND` descriptor, with no locking: POSIX.1-2024 `write()` makes each write to a
  regular file atomic and allows no other modification between the seek to the end and the write.
  (`PIPE_BUF`, 512 here, bounds pipes and FIFOs, not files; the plan's reason was corrected.) That
  holds on a local file system, not on NFS. A test appends ~1 KB lines from two stores at once.
- `status` flags a sleeping session past the 14-day resume window, from `updated_at` (the window
  runs from when a session goes to sleep, per Devin's release note of 2026-10-09; the docs page
  still says 30 days), and a sleeping non-resumable one at any age: live, a post to one answered
  400 "Cannot revive devin". `resumable` isn't in `SessionResponse`, so a session kick didn't
  create shows it as unknown.
- `KICK_LOG_TSV`, when set, gets fstec's 9 columns for every run that settles (`run`, `save`); it
  lives in the executable and swallows its own failures, as deepwiki-mcp's `UsageLog` does.

*Rejected:* locking the index (single short appends don't need it), a directory scan to find runs
(deepwiki-mcp's `ConsultStore`), and swallowing the index write.

### Uploads only from allowed roots, never twice

Uploads are permanent, so `KICK_UPLOAD_ROOTS` (colon-separated) names the directories files may
come from. A path is resolved with `realpath` (symlinks, `.`, `..`) and must lie inside a resolved
root; unset means no uploads at all (78, naming the variable). `uploads.jsonl` maps sha256 + name
to the URL Devin returned, so a second upload of the same file sends nothing. If Devin ever
expires attachments, a cached URL fails at create with the server's own error; that is accepted.

### Modes: one hard check, the rest warns

The mode is `--mode` (an explicit override for a whole batch), then a manifest entry's `mode`,
then `KICK_MODE` (only a default), then `swe-2-max` (owner, 2026-10-18). The one hard check is the
request enum's 8 values (64, listing them). `available_devin_modes` is documented for
automations, evaluated as the organization's automation identity, and optional, so a mode missing
from it, an absent list or a refused GET warns once per process and the server decides. Live, the
list can't be decoded at all (TD-8). A session that reports no `devin_mode` runs an agent preview
and reads as "preview/other". A manifest mixing `swe-2-max` and `swe-2-high` created both, each
reported with its own mode (live).

The manifest is JSON, `[{prompt_file, title, schema_file?, attach?, mode?, tags?}]`, decoded by
Foundation; relative paths resolve against its own directory. Every entry is validated before the
first POST, so a usage error aborts with nothing started; then entries start one at a time, and a
server failure on one doesn't stop the rest.

### Attachments through the download endpoint

Amendment A7 said to fetch each listed `url` verbatim; that is wrong. The listing's `url`
(`app.devin.ai/attachments/…`) answers 401 to an API key (the `devin` skill's trap, 2026-10-14;
again live 2026-10-18). Each attachment downloads through `GET …/attachments/{attachment_id}/{name}`
instead, which answers 307 to a presigned S3 URL. Live, the listed `attachment_id` is the URL's
uuid, and a user's upload is listed with `source: user`.
- The generated client can't make this call: the spec's 307 documents no `Location`, and its 200
  is typed JSON. So the Kit makes it on its own URLSession, with the configured server's URL and
  headers; the key goes to no other host.
- A redirect delegate removes `Authorization` before the hop. That is required, not hygiene: the
  presigned URL answers 400 to a request carrying it (live). URLSession on macOS 26 already drops
  it on this cross-host redirect (measured); the delegate keeps it so whatever the OS does.
- The server's name is sent as one percent-encoded segment, so `../x` can't become dot-segments,
  and saved as a safe basename (no separators, no `..`, no leading dot, capped, numbered if
  taken); a changed name is recorded in the index.
- A dropped connection, a 429 or a 5xx is retried, as for any GET.

### Reply, archive, terminate: what the server does

- **Reply** reads the status first: an `exit` or `error` session gets "start a new session"
  (exit 1) and nothing is posted (amendment A11). The check is a convenience, not a guarantee; the
  server's answer is authoritative, and live it refuses too (400 "Session already exited"). A post
  resumes a sleeping session, archived or not (live), unless it is non-resumable; one posted about
  a second after an archive was recorded and didn't wake it. Results are
  never read from a post's answer, which live carries `structured_output: null`.
- **Archive** puts a running session to sleep as `suspended`/`user_request` (live). Both archive's
  and terminate's answers carry the status from before the call, so kick reads the session back.
- **Terminate** (`DELETE …?archive=true`) settles asynchronously: live, a session read
  `running`/`finished`, then `exit` about 4 s later. kick reads it back for up to 15 s and says so
  when it didn't end: one terminate sent a second after create answered 200 and never ended the
  session. A terminate of a sleeping session answers 200 and leaves it asleep; of an ended one,
  400.
- **No prompt cap** was found up to 16 MiB; the first message held every byte (live).

### Operations ahead of the CLI

The filter keeps 16 operations. The session-tag operations (get, append, replace) have no
command in M1: create-time `--tag` covers the need, and the operations are there for M2's server.

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
