# GitHub workflow — devin-kick

*Set up 2026-10-18.* It follows the owner's other repositories: SimKDSKit's model (issues,
milestones as the release plan, tags as versions) and the habits of YDelivery's
`docs/GitHubWorkflowProposal.md`. Every row was applied and checked live with `gh`.

## Applied — 2026-10-18

| What | State | How |
|---|---|---|
| Merge method | **Merge commits only**: squash and rebase off; title `MERGE_MESSAGE`, body `PR_TITLE` (as SimKDSKit). Atomic, reviewed commits land as they are | repo API |
| Branch hygiene | `delete_branch_on_merge`, `allow_update_branch`, `allow_auto_merge` on; Projects and Wiki off (the Roadmap, milestones and issues are the board) | repo API |
| Protection | Ruleset `protect main` (id 25338380): `non_fast_forward`, `deletion`, no bypass. Requiring a PR or the CI check is the owner's later call | `gh api repos/laconicman/devin-kick/rulesets` |
| Topics | swift, swift-package, devin, mcp, model-context-protocol, cli, openapi, swift-openapi-generator, ai-agents | repo API |
| Vulnerability reporting | Private reporting on; `SECURITY.md` points at it | repo API, `SECURITY.md` |
| Labels | GitHub's `enhancement`, `bug`, `documentation`, plus `breaking`, `upstream`, `tech-debt`, `hygiene`, `tests` (SimKDSKit's vocabulary) | `gh label list` |
| Release notes | `.github/release.yml` maps the labels to sections | `.github/release.yml` |
| Milestones | #1–#7 = Roadmap M0–M6, each titled with the tag it closes into, and described by its done-when | `gh api …/milestones` |
| Issues | #2 TD-4 (M1), #3 TD-2 upstream filing (M1), #4 TD-3 upstream feedback (M1), #5 TD-1 generator floor (M5). Each TD links its issue; the DocC register stays authoritative | `gh issue list` |
| PR template | Local gate, live smoke, docs touched, spec-tool counts, labels and milestone, free pass, ledger at 0 | `.github/pull_request_template.md` |
| Reviewer steering | `REVIEW.md` (Devin Review), checked with the `devin-review-rules` validator | `REVIEW.md` |
| Dependabot | SwiftPM + Actions, monthly | `.github/dependabot.yml` |
| CI | `swift build` + `swift test` on a swift.org 6.4 toolchain (`swift-actions/setup-swift`), since no hosted image has Xcode 27 yet. Lands with M0 (PR #1), where the package is | `.github/workflows/ci.yml` |
| DeepWiki | README badge (weekly auto-refresh, once the repo is indexed) | `README.md` |

## Habits

**Per PR:**
- Branch `feat/…`, `fix/…` or `chore/…`, from `main`.
- Atomic commits that each build.
- `gh pr create --label <one> --milestone "M<n> · …"`.
- The free pass first: DeepWiki, prospectively.
- Triage: `contrib in laconicman/devin-kick --pr N`; reply in each thread, and push fixes that
  make the finding false.
- When the reviewer's re-run on the head reads `owed 0 / to re-read 0`, and the owner approves:
  `gh pr merge N --merge --auto`.

**Closing milestone M_n**, done in the PR that completes it and right after it merges:

```bash
# in the completing PR: DevinKick.version = "0.(n+1).0" (Sources/DevinKickKit/DevinKick.swift)
git switch main && git pull --ff-only
git tag -a 0.2.0 -m "<the milestone's done-when sentence>"        # no v prefix (SwiftPM)
git push origin 0.2.0
gh release create 0.2.0 --verify-tag --generate-notes --title "0.2.0 — M1 · CLI core"
gh api repos/laconicman/devin-kick/milestones/<number> -X PATCH -f state=closed
```

**Never:**
- poll CI;
- force-push `main`, which the ruleset refuses anyway;
- leave a milestone open after its tag. DiceLab's survey found two left open forever.

## Not adopted, and why

| Feature | Why not |
|---|---|
| Squash merges | They would collapse the atomic, reviewed commits that each build |
| Required checks / required PR | Owner's call (as in YDelivery); CI's first green run comes first |
| Issues for every TD item | Only actionable ones; the DocC register is the record |
| Projects board | Roadmap + milestones + issues already are the board |
| CODEOWNERS / required reviews | One maintainer; Devin Review runs on every push |
