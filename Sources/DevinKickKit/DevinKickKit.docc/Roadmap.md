# Roadmap

Priority-ordered milestones; each lands through one pull request with review rounds. The why is
in <doc:Design>.

## Overview

### Now — M0, contract spike

- The package: generated target, façade, `kick`, `devin-spec-tool`; Swift 6.4 with the Swift 7
  upcoming features on the handwritten targets.
- The official spec vendored, normalized (733 nullables, 77 response enums, 197 ids) and filtered
  to 16 operations; generates and builds with no generator warnings.
- `kick self` live (`GET /v3/self`).
- ``Settlement`` with its exit statuses, tested on 22 cases and on two sanitized field records.
- Live contract test: the `qs` filter object is honored as the generator sends it (form, explode).

### Next

- **M1 — CLI core.**
  - The upload cache (sha256 → URL, since uploads are permanent) and the allowed upload roots.
  - `start` from a prompt file or a manifest, with a mode per session (default `swe-2-max`,
    checked against `available_devin_modes`).
  - `status` / `wait` with the exit statuses; `save` into the run store, recorded at submit and
    shielded from cancellation (SE-0504).
  - `messages`, `reply`, `archive`, `list`, and `run`.
  - Retries on transport errors, 429 and 5xx.
- **M2 — the side profile:** `kick serve --profile side` with 8 tools, compact replies, and no
  result ever inlined.
- **M3 — the main profile:** 5 coarse tools for Haiku or Sonnet, a bundled prompt template, and a
  plan-first path.
- **M4 — evaluations:** delegation tasks run headless by Haiku and Sonnet, on `swe-2-max` vs
  `swe-2-high`; pass rates and a mode-routing table land here.
- **M5 — ship:** Claude Code plugin, `.mcpb`, install and registration, beside the official
  Devin MCP.
- **M6 — field comparison:** real jobs through `kick`, measured against the 2026-10-14 REST and
  official-MCP records. Then the owner decides whether to deny the official server's session
  tools.

### Later

- Knowledge, playbooks, automations: the official server keeps them.

## See Also

- <doc:Design>
- <doc:TechDebt>
