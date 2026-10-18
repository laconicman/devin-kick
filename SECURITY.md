# Security

## Scope

`kick` acts with a Devin API key (`DEVIN_API_KEY`, a `cog_` token). It holds no secret of its
own, and the key is read from the environment only, never from a file in this repository. The
security-relevant surfaces, each tested:

- **The key is never printed.** `kick self` shows the principal, not the credential, and errors
  quote the server's `detail`, never the request.
- **Transport.** The key travels as a Bearer header to `https://api.devin.ai`. An override
  (`KICK_SERVER_URL`) must be `https`; clear-text `http` is accepted only to loopback, for a local
  mock server (`Configuration.validatedServerURL`).
- **Uploads are permanent** (from milestone M1): Devin's API cannot delete an attachment. Uploads
  are limited to the directories in `KICK_UPLOAD_ROOTS`, and the main profile refuses to upload
  when it is unset.
- **Test fixtures** are real session records with every identifier zeroed.

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security → Report a
vulnerability). Please do not open a public issue for something that could expose a key. Defects
in Devin's API or its published OpenAPI document belong to Cognition; `Upstream/README.md` says
how those are drafted.
