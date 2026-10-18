## Summary

-

Milestone: M… · Closes #… — or "no tracked issue".

## Checklist

- [ ] Local gate: `swift build` with no warnings in handwritten targets, `swift test` green (CI repeats it)
- [ ] `KICK_LIVE=1 swift test --filter LiveSmoke` green, if the change touches the API
- [ ] Atomic commits that each build; no AI attribution in commits, this body or replies
- [ ] `Design.md` / `TechDebt.md` / `Roadmap.md` updated if a recorded decision, debt item or milestone changed
- [ ] No generated code committed; spec changes went through `devin-spec-tool`, with its counts below
- [ ] Changed library API or CLI/MCP contract (exit statuses, tool names) → `breaking` label, minor bump noted here
- [ ] Labelled for the release notes (`.github/release.yml`) and placed in its milestone
- [ ] Free pass first: DeepWiki asked prospectively (and, from M1, a `kick` review session) — link it here
- [ ] Before merge: Devin Review round complete, and `contrib in laconicman/devin-kick --pr N` at `owed 0 / to re-read 0`
