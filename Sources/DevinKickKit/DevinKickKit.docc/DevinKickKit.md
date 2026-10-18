# ``DevinKickKit``

Devin (Cognition) as a side kick or a main kick, over Devin's official v3 REST API.

## Overview

`DevinKickKit` is the façade that the `kick` binary's two faces share: its CLI subcommands, and
(from milestone M2) `kick serve`, an MCP stdio server. It turns Devin's session lifecycle into
what a caller needs: start work, know where it stands, answer, collect the result.

- **Side kick:** a capable model orchestrates and delegates bounded jobs, single or in batches,
  and verifies the results itself.
- **Main kick:** a smaller model hands Devin the whole task and only relays.

Credentials come from the environment: `DEVIN_API_KEY` (a `cog_` key) and `DEVIN_ORG_ID`.

## Topics

### Project Direction

- <doc:Design>
- <doc:Roadmap>
- <doc:TechDebt>

### Essentials

- ``DevinKick``
- ``Configuration``
- ``KickError``
- ``ExitStatus``

### Reading a session

- ``Settlement``
- ``OutputVerdict``
- ``Schema``
- ``Reading``
- ``SessionSnapshot``
- ``WaitCondition``

### Starting sessions

- ``SessionRequest``
- ``StartOptions``
- ``StartedRun``
- ``Manifest``
- ``DevinMode``
- ``Upload``

### Results and the run store

- ``RunStore``
- ``RunState``
- ``SavedRun``
- ``Completed``
- ``SessionMessage``
- ``SessionAttachment``
