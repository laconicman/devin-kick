# Feedback draft — Cognition (Devin API v3 OpenAPI document)

> Not sent yet. Cognition has no public tracker for the API document; this is for its feedback or
> support channel.

**Subject:** v3 OpenAPI: `AutomationSchemasResponse` forbids fields the live API sends

The document at `https://docs.devin.ai/v3-openapi.yaml` (unchanged since 2026-10-15; sha256
`90e117ab…11c8d28` on 2026-10-18) declares `AutomationSchemasResponse`, the 200 body of
`GET /v3/organizations/{org_id}/automations/schemas`, with `additionalProperties: false`, and
lists `available_devin_modes`, `default_fallback_devin_mode`, `default_net_policy`,
`security_profile`, `sources` and `update_semantics`.

The live endpoint answered (2026-10-18) with two more top-level keys, `oncall` and
`preflight_available`. A client that honors the document rejects the whole answer: Apple's
swift-openapi-generator emits `ensureNoAdditionalProperties` for `additionalProperties: false`, so
decoding fails and the documented fields, `available_devin_modes` among them, are unreadable.

Eight more schemas reachable from that answer are closed the same way
(`AutomationEventSchemaResponse`, `AutomationSchemaFieldDef`, `AutomationSchemaSelectOption`,
`AutomationNetPolicy`, its three destination shapes, `AutomationSchemasSecurityProfile`), so a
field added to any of them breaks the same clients. The session, message and attachment
responses don't declare it, and decode fine as fields are added.

**Ask:** either drop `additionalProperties: false` from response schemas, so a field added
later can't break a client, or document `oncall` and `preflight_available` and keep the document
in step with the server.

**Also worth a line in the docs** (observed on 2026-10-18, `DELETE …/sessions/{id}?archive=true`):
- a terminate settles asynchronously: the session reads `running`/`finished`, then `exit` a few
  seconds later, and the answer itself carries the status from before the call;
- a terminate of a sleeping (`suspended`) session answers 200 and leaves it asleep;
- a terminate of an ended session answers 400 `Devin session already exited`;
- one terminate sent about a second after create answered 200 and never ended the session.
