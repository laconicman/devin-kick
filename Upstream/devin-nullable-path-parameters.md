# Feedback draft — Cognition (Devin API v3 OpenAPI document)

> Not sent yet. Cognition has no public tracker for the API document; this is for its feedback or
> support channel.

**Subject:** v3 OpenAPI: required path parameters are typed nullable, so generated clients break

The document at `https://docs.devin.ai/v3-openapi.yaml` (last modified 2026-10-15, OpenAPI 3.1.0,
161 paths) types every path parameter as nullable, for example on
`GET /v3/organizations/{org_id}/sessions/{devin_id}`:

```yaml
- name: devin_id
  in: path
  required: true
  schema:
    anyOf: [{type: string}, {type: "null"}]
```

A path segment can't be null, and `required: true` already says so. This looks like FastAPI's
rendering of `Optional[str]` path parameters. Code generators that reject a `null` branch then
drop the parameter: Apple's swift-openapi-generator 1.14.1 emits a client that doesn't compile
(see `generator-skipped-path-parameter.md`).

The same pattern affects the whole document: 733 of its 739 `anyOf`s are `[X, {type: null}]`.
For response fields that's a fair way to say "nullable". For path parameters it's a defect.

**Ask:** declare path parameters as plain `type: string`, by typing them `str` rather than
`Optional[str]` in the route signatures.

**Also worth a line in the docs:** the required `qs` object on `GET …/sessions` has no
`style`/`explode`. The default (form, explode) works: `?first=5&tags=x` filtered correctly in a
live call on 2026-10-18. Saying so would spare client authors the guess.
