# devin-kick — Devin as a side kick or a main kick

One binary, `kick`: CLI subcommands, and from M2 `kick serve`, an MCP stdio server. Both wrap
`DevinKickKit` over Devin's **official** v3 REST API. **Side kick:** a capable model delegates
bounded jobs and verifies the results itself. **Main kick:** a smaller model hands Devin the
whole task and only relays.

The DocC catalog (`Sources/DevinKickKit/DevinKickKit.docc/`) is authoritative for direction:
`Design` (decisions + rejected alternatives) · `Roadmap` (M0–M6, one GitHub milestone each) ·
`TechDebt` (numbered `TD-n` register, each linked to its issue). The planning brief and the
consult log live **beside** the repo, not in it: `../TASK-code-devin-kick.md` (amendments
A1–A22) and `../devin-kick-consults/`. They are context; when they disagree with Design, Design
wins.

## Architecture

`DevinOpenAPI` (generated from the vendored, normalized spec; nothing generated committed) →
`DevinKickKit` (façade) → `kick` (argument parsing, and from M2 the MCP server). Maintainer tool:
`devin-spec-tool`. Swift 6.4 tools version, Swift 6 language mode, macOS 15 floor, with the Swift 7
upcoming features on every handwritten target. Each choice is reasoned in `Design`.

## Rules specific to this repository

1. **Generated types stop at the Kit boundary.** The Kit's public API uses its own types
   (`Principal`, `Settlement`, `KickError`). `InternalImportsByDefault` enforces it; never add
   `public import DevinOpenAPI`.
2. **Errors are typed, and exit statuses are a contract.** Kit functions throw `KickError`
   (`throws(KickError)`). Changing an exit status changes, in the same PR, `Settlement`/`KickError`,
   the README's table and `kick --help`'s text. Messages quote `code: detail` and name the next
   step; never `String(describing:)` a payload.
3. **Settlement is the only reader of `status`/`status_detail`.** Unknown vocabulary is
   `.unknown`, shown raw, never guessed. Output is not proof of completion (TD-4, #2).
4. **The spec changes only through `devin-spec-tool`.** Never hand-edit `openapi.yaml`. Re-vendor
   with `swift run devin-spec-tool`, then confirm `--no-fetch` reports `0 / 0 / 0 / 0`, and put
   both counts in the PR body.
5. **Zero warnings in handwritten targets.** The generated target's ~30 `UnusedImportAccess`
   warnings are TD-1 (#5), upstream, and can't be silenced. Under `NonisolatedNonsendingByDefault`,
   spell `@concurrent` on async closures in conformances to a dependency's protocol.
6. **MCP calls are short; results go to disk.** Starting returns ids at once and records the run
   at submit. Waits are bounded per call: ≤ 240 s for `kick_wait`, ≤ 120 s for `kick_check`, under
   Claude Code's 300 s idle abort. No tool result inlines `structured_output` or a transcript.
   Tool names are `kick_*`, disjoint across the two profiles.
7. **The key and the data.**
   - `DEVIN_API_KEY` comes from the environment only, and is never printed or logged.
   - Overrides are `https` (plain `http` only to loopback).
   - Uploads are permanent, so they are limited to `KICK_UPLOAD_ROOTS`.
   - Fixtures are sanitized field records.
   - Live tests are opt-in (`KICK_LIVE=1`). A live test that creates a session tags it
     `devin-kick-test` and archives it.
8. **Free pass before the paid one.** Before opening a PR:
   - ask DeepWiki prospectively, since a feature branch isn't indexed: describe the diff against
     the indexed upstream repos and `laconicman/deepwiki-mcp`;
   - from M1, also run one free `swe-2-max` review session through `kick` itself.

   A disagreement with a decision recorded in Design is reported to the owner, not applied
   silently.
9. **Everything lands via PR, with review rounds.**
   - Atomic commits that each build. Merges are **merge commits only** (squash and rebase are
     off), so reviewed SHAs and review-fix commits land as they are.
   - Triage Devin Review with `contrib in laconicman/devin-kick --pr N`: reply in every thread,
     and fix by pushes that make the finding false (Devin resolves its threads on HEAD).
   - A round is done at `owed 0 / to re-read 0`, read **after** the reviewer's re-run on the head.
   - The owner approves each merge; then `gh pr merge N --merge --auto`. Never poll CI.
   - A ruleset blocks force-push and deletion of `main`. Requiring checks is the owner's call.
10. **GitHub bookkeeping.**
    - Every PR is labelled for `.github/release.yml` and placed in its milestone.
    - The PR that completes milestone M_n bumps `DevinKick.version` to `0.(n+1).0`. After it
      merges: an annotated tag of that version (no `v`), its message the milestone's done-when
      sentence; then `gh release create <tag> --generate-notes`, and the milestone closed in the
      same step.
    - The recipes are in `docs/GitHubWorkflow.md`.
11. **One public identity, no AI attribution.** Commits only as
    `laconicman <laconicman@icloud.com>`; check `git log --format='%ae %ce' @{u}..` before a push.
    No `Co-Authored-By` trailer, generated-with footer or sign-off in commits, PR bodies, comments
    or tracked files.

## Author's standing preferences

Clarity over brevity. Prefer a vetted SPM when the dependency is smaller than the problem, and say
so when it is not. Cite sources in prose and code comments. DRY, separation of concerns, low
coupling / high cohesion first. Error types conform to `LocalizedError` with a filled
`errorDescription`. Prefer implicit returns wherever the compiler allows. No magic numbers or
strings: give shared values one named home. Claims are verified, not recalled: look vendor
behavior up (DeepWiki, the spec, the docs) before ruling on it.

## Related skills

`devin` · `deepwiki` · `mcp-builder` · `apple-swift-openapi-generator` · `swift-package-manager` ·
`swift-concurrency` · `swift-testing-expert` · `software-development-principles` ·
`swift-file-organization` · `devin-review-rules` · `contributions` · `atomic-commits` ·
`git-branching` · `repo-init`
