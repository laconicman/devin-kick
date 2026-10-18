# Roadmap

Priority-ordered milestones; each lands through one pull request with review rounds, unless the
owner splits one. The why is in <doc:Design>.

## Overview

### Done

- **M0 — contract spike (0.1.0).** The package and its three layers, the official spec vendored
  and normalized (733 nullables, 77 response enums, 197 ids) and filtered to 16 operations,
  `kick self` live, ``Settlement`` with its exit statuses, and the live `qs` contract test.
- **M1 — CLI core (0.2.0).** Two pull requests (owner, 2026-10-18): the CLI core, then
  `devin-spec-tool`'s fourth transform, which discharges TD-8 before the tag.
  - `upload` within `KICK_UPLOAD_ROOTS`, cached by sha256 + name.
  - `start` from a prompt file or a manifest, a mode per session, recorded at submit and found
    again by its run tag; `status` / `wait` with the exit statuses; `save` into the run store;
    `messages`, `reply`, `archive`, `unarchive`, `list`, and `run`.
  - Retries by idempotency on transport errors, 429 and 5xx.
  - TD-4 discharged: kick's `kick_final` field and the output verdict.
  - A live suite that answers the plan's open questions (<doc:Design>, "Reply, archive,
    terminate: what the server does").

### Now

- **M2 — the side profile:** `kick serve --profile side` with 8 tools, compact replies, and no
  result ever inlined. The Kit's readings, status line and exit rank are reused as they are. The
  server is long-lived, so the run store re-reads the index's tail before minting and at lookup
  (<doc:Design>, "The run store").

### Next

- **M3 — the main profile:** 5 coarse tools for Haiku or Sonnet, a bundled prompt template, and a
  plan-first path.
- **M4 — evaluations:** delegation tasks run headless by Haiku and Sonnet, on `swe-2-max` vs
  `swe-2-high`; pass rates and a mode-routing table land here.
- **M5 — ship (1.0.0):** Claude Code plugin, `.mcpb`, install and registration, beside the
  official Devin MCP.
- **M6 — field comparison:** real jobs through `kick`, measured against the 2026-10-14 REST and
  official-MCP records. Then the owner decides whether to deny the official server's session
  tools.

### Later

- Knowledge, playbooks, automations: the official server keeps them.

## See Also

- <doc:Design>
- <doc:TechDebt>
