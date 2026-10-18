# devin-kick

[![CI](https://github.com/laconicman/devin-kick/actions/workflows/ci.yml/badge.svg)](https://github.com/laconicman/devin-kick/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE.txt)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/devin-kick)

Devin (Cognition) as a **side kick** or a **main kick**, from Swift. It is one binary, `kick`,
with a CLI and (from milestone M2) an MCP stdio server, `kick serve`. Both wrap the same library,
`DevinKickKit`, over Devin's official v3 REST API.

- **Side kick:** a capable model orchestrates and delegates bounded jobs, single or in batches,
  and verifies the results itself.
- **Main kick:** a smaller model hands Devin the whole task and only relays: delegate, check,
  answer, read the result.

The architecture, the decisions and what each one rejected are in the **Design** article of the
DocC catalog (`Sources/DevinKickKit/DevinKickKit.docc/Design.md`), which is authoritative. The
milestones are in `Roadmap.md` and the known compromises in `TechDebt.md`, beside it.

## Status

Milestone **M0** (contract spike): the generated client, the façade, `kick self`, and the
session-lifecycle seam with its exit statuses. The CLI core (M1) and the MCP server (M2, M3) are
next.

## Build and try

Needs Swift 6.4 (Xcode 27, or a swift.org 6.4 toolchain) on macOS 15 or later.

```bash
swift build
export DEVIN_API_KEY=cog_…   # better: in ~/.zshenv, so agents' shells see it too
export DEVIN_ORG_ID=org-…
swift run kick self          # principal_type: pat_user
```

`kick` never prints the key.

### Exit status

Stable, so scripts may rely on it:

| Status | Meaning |
|---|---|
| 0 | done |
| 10 | needs input: Devin asks, or awaits an approval |
| 11 | unknown state, printed raw |
| 75 | still working: poll again |
| 69 | no answer, or 429 / 5xx: retry |
| 1 | failed |
| 64 | usage error |
| 78 | configuration error |

## Tests

```bash
swift test                                       # offline: settlement, errors, field fixtures
KICK_LIVE=1 swift test --filter LiveSmoke        # live, read-only contract checks
```

## Maintainers: re-vendoring the spec

```bash
swift run devin-spec-tool        # fetch https://docs.devin.ai/v3-openapi.yaml, normalize, write
swift run devin-spec-tool --no-fetch   # re-normalize in place; a clean run reports 0 / 0 / 0 / 0
```

The tool's three transforms, and why the published document needs them, are described in the
Design article. `Upstream/` holds the drafts that would let them shrink.

## License

Apache 2.0; see [LICENSE.txt](LICENSE.txt).
