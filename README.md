# devin-kick

[![CI](https://github.com/laconicman/devin-kick/actions/workflows/ci.yml/badge.svg)](https://github.com/laconicman/devin-kick/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE.txt)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/devin-kick)

Devin (Cognition) as a **side kick** or a **main kick**, from Swift. It is one binary, `kick`,
with a CLI and an MCP stdio server, `kick serve`. Both wrap the same library, `DevinKickKit`, over
Devin's official v3 REST API.

- **Side kick:** a capable model orchestrates and delegates bounded jobs, single or in batches,
  and verifies the results itself.
- **Main kick:** a smaller model hands Devin the whole task and only relays: delegate, check,
  answer, read the result.

The architecture, the decisions and what each one rejected are in the **Design** article of the
DocC catalog (`Sources/DevinKickKit/DevinKickKit.docc/Design.md`), which is authoritative. The
milestones are in `Roadmap.md` and the known compromises in `TechDebt.md`, beside it.

## Status

Milestone **M2** (the side profile): `kick serve --profile side`, an MCP stdio server with eight
tools for a model that delegates bounded jobs and checks the results itself. It stands beside
M1's CLI: upload, start from a prompt file or a manifest, status, wait, save, messages, reply,
archive and list, and `run` end to end, with retries and a local run store. The main profile
(M3) is next.

## Build and try

Needs Swift 6.4 (Xcode 27, or a swift.org 6.4 toolchain) on macOS 15 or later.

```bash
swift build
export DEVIN_API_KEY=cog_…   # better: in ~/.zshenv, so agents' shells see it too
export DEVIN_ORG_ID=org-…
swift run kick self          # principal_type: pat_user
swift run kick run --prompt task.md --title "A small job"
```

`kick` never prints the key.

### Commands

`ID` is a session id, a run id (`yyyyMMdd-HHmmss-xxxx`) or a run directory.

| Command | Does |
|---|---|
| `kick upload FILE…` | uploads files inside `KICK_UPLOAD_ROOTS`; a file uploaded before is reused, not sent again |
| `kick start --prompt FILE \| --manifest FILE` | starts sessions, recorded before the POST; prints run id, session id, URL, run directory |
| `kick status ID… [--tag T]` | one line per session: state, Devin's status, kick's reading of the output, age, mode |
| `kick wait ID… [--any\|--all] [--timeout S]` | waits at most 240 s for sessions to settle |
| `kick save ID…` | session, result, messages and attachments into the run directory |
| `kick messages ID [--last N] [--full]` | the transcript |
| `kick reply ID (--text T \| --file F) [--attach F…]` | posts a message; a session that has ended is refused |
| `kick archive ID… [--terminate]` / `kick unarchive ID…` | archives, optionally ending the session first |
| `kick list [--tag T] [--remote] [--limit N]` | the local run index, or the server's sessions |
| `kick run …start's options… [--budget 3h]` | start, wait, save, and archive what's done |
| `kick serve --profile side [--no-bypass-approval] [--max-wait S]` | the MCP server on stdio (below) |

`start` and `run` take `--title`, `--schema FILE` (a JSON Schema; kick adds its `kick_final`
field), `--attach FILE`, `--mode`, `--tag`, `--no-resumable`, `--no-bypass-approval`,
`--acu-limit` and `--out DIR`. A manifest is a JSON array of
`{prompt_file, title, schema_file?, attach?, mode?, tags?}`; every entry is checked before the
first one starts. `kick help <command>` has the details.

### The MCP server

`kick serve --profile side` speaks MCP over stdio to an agent such as Claude Code. Its tools start
sessions and return at once, wait in bounded calls, and write results to the run directory rather
than into the conversation: no tool result is over 4 KB.

| Tool | Does |
|---|---|
| `kick_upload` | uploads files inside `KICK_UPLOAD_ROOTS`; a file uploaded before is reused |
| `kick_start` | starts one session or a batch (up to 20 without the operator), from a prompt file or inline text |
| `kick_status` | one line per session, then the overall state and the next step |
| `kick_wait` | waits at most 240 s per call; call it again until the sessions settle |
| `kick_save` | writes session, result, messages and attachments into the run directory, and names them |
| `kick_messages` | the latest messages' first lines |
| `kick_reply` | posts a message, as text or a file's text, then shows the session's status |
| `kick_archive` | archives; ending a session stays the CLI's `kick archive --terminate` |

To register it with Claude Code, with `DEVIN_API_KEY` and `DEVIN_ORG_ID` in the environment
Claude Code starts from:

```bash
swift build -c release --product kick
claude mcp add devin-kick -- "$(swift build -c release --show-bin-path)/kick" serve --profile side
```

`--no-bypass-approval` and `--max-wait SECONDS` (at most 240, for a client that aborts a call
sooner than Claude Code's 300 s) go after `side`; no tool can change them. The server reads the
same environment as the CLI, and without a key it still starts, so every tool can answer the
configuration error (78).

### Environment

| Variable | Meaning |
|---|---|
| `DEVIN_API_KEY` | the `cog_` key; required, never printed |
| `DEVIN_ORG_ID` | the organization, for everything but `kick self` |
| `KICK_STORE` | the run store; default `~/Library/Application Support/devin-kick` |
| `KICK_UPLOAD_ROOTS` | colon-separated directories uploads may come from; unset, nothing is uploaded |
| `KICK_MODE` | the default Devin mode (after `--mode` and a manifest entry's); default `swe-2-max` |
| `KICK_LOG_TSV` | a file that gets one TSV line per run that settles |
| `KICK_SERVER_URL` | an `https` override of `https://api.devin.ai` (plain `http` only to loopback) |

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
| 73 | the run store couldn't record the run (`KICK_STORE`, `--out`) |
| 78 | configuration error |

With several sessions, `status`, `wait` and `run` exit with the worst: failed > unknown > needs
input > working > done.

## Tests

```bash
swift test                                                    # offline, over a scripted transport
KICK_LIVE=1 swift test --filter LiveSmoke                     # live, read-only contract checks
KICK_LIVE=1 swift test --filter "LiveSession|LiveSmoke"       # live sessions, tagged devin-kick-test and archived
KICK_LIVE=1 swift test --filter LiveServer                    # one live session through the MCP tools
```

## Maintainers: re-vendoring the spec

```bash
swift run devin-spec-tool        # fetch https://docs.devin.ai/v3-openapi.yaml, normalize, write
swift run devin-spec-tool --no-fetch   # re-normalize in place; a clean run reports 0 / 0 / 0 / 0 / 0
```

The tool's four transforms, and why the published document needs them, are described in the
Design article. `Upstream/` holds the drafts that would let them shrink.

## License

Apache 2.0; see [LICENSE.txt](LICENSE.txt).
