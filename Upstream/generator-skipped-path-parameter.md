# Issue draft — apple/swift-openapi-generator

> Not filed yet. No existing issue matched on 2026-10-18 (searched: "path parameter anyOf null",
> "has no member 'path'"). The closest, #286, is about decoding a nullable `anyOf` body field.

**Title:** A path parameter whose schema is skipped as unsupported still emits `input.path` in
`Client.swift`, which then fails to compile

**Labels:** `kind/bug`, `area/generator`

## Description

When every path parameter of an operation has a schema the generator doesn't support, it warns
and skips the parameters, so `Input` gets no `Path` struct. The client code for the operation
still reads `input.path.<name>`, so the generated sources don't compile. The diagnostic is a
compile error pointing at generated code, not at the document.

Nullable path parameters are common in FastAPI output: an `Optional[str]` path parameter (even a
`required: true` one) is emitted as `anyOf: [{type: string}, {type: "null"}]`. Devin's official
v3 API document (`https://docs.devin.ai/v3-openapi.yaml`, 161 paths) has this on every path
parameter.

## Reproduction

swift-openapi-generator **1.14.1** (exact), swift-openapi-runtime 1.13.1, Swift 6.4, macOS 26.

`openapi.yaml`:

```yaml
openapi: 3.1.0
info: {title: Repro, version: 1.0.0}
paths:
  /items/{item_id}:
    get:
      operationId: getItem
      parameters:
        - name: item_id
          in: path
          required: true
          schema:
            anyOf: [{type: string}, {type: "null"}]
      responses:
        '200': {description: OK}
```

`openapi-generator-config.yaml`: `generate: [types, client]`, `accessModifier: internal`.

## Actual

```
warning: Schema "null" is not supported, reason: "schema type", skipping
  [context: foundIn=Operations.getItem.Input.Path (#/paths/items/{item_id}/GET/path)/item_id]
GeneratedSources/Client.swift:44:31: error: value of type 'Operations.getItem.Input' has no member 'path'
```

## Expected

One of:
- a generation-time **error** naming the parameter, since a required path parameter cannot be
  dropped without breaking the URL; or
- treat `anyOf: [T, {type: null}]` on a **parameter** as `T`, since a path segment can't be null.

## Workaround

Normalize the document before generation (`anyOf: [X, {type: null}]` → `X`), as
laconicman/devin-kick's `devin-spec-tool` does.
