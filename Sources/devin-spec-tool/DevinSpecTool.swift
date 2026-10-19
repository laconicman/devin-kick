import CryptoKit
import Foundation
import Yams

/// Maintainer tool that (re)vendors Devin's official v3 OpenAPI document for DevinKickKit and
/// applies the normalizations that make it usable with `swift-openapi-generator`.
/// Pattern: GitLabKit's `gitlab-spec-tool` (laconicman/swift-gitlab).
///
///   swift run devin-spec-tool                         # fetch the latest spec, normalize, write
///   swift run devin-spec-tool --input raw.yaml        # normalize a spec already on disk
///   swift run devin-spec-tool --no-fetch              # re-normalize the vendored spec in place
///
/// Transforms (the why is in the DocC Design and TechDebt articles):
///  1. Nullables — FastAPI's `anyOf: [X, {type: null}]` becomes `X` with `type: [T, "null"]`,
///     3.1's own nullable spelling, which the generator reads as `T?`; `required` stays. A nullable
///     `$ref` has no such spelling, so it becomes the bare `$ref` and leaves `required` instead.
///     Without this the generator skips every path parameter and emits code that doesn't compile.
///  2. Response enums — `enum` is dropped from every schema reachable from a response, so a
///     status, detail or mode Devin adds later can never fail decoding. Request-side enums stay.
///  3. Operation ids — `handle_create_session_v3_organizations__org_id__sessions_post` becomes
///     `create_session` (idiomatic: `createSession`); an enterprise twin gets `enterprise_`, and a
///     name that would still collide keeps its original id.
///  4. Open response schemas — `additionalProperties: false` is dropped from every schema
///     reachable from a response, in transform 2's walk, so a field Devin adds later can't fail
///     decoding either: the generator enforces it (`ensureNoAdditionalProperties`), and live
///     (2026-10-18) the automation schemas carried two fields the document doesn't list (TD-8).
///     A schema used only in requests stays closed; one shared with a response opens, which
///     changes nothing for a request, since the generator emits no encoder check for it.
///
/// All four are idempotent: a second run over the output reports `0 / 0 / 0 / 0 / 0`.
@main
struct DevinSpecTool {
    static let specURL = URL(string: "https://docs.devin.ai/v3-openapi.yaml")!
    static let defaultOutput = "Sources/DevinOpenAPI/openapi.yaml"

    struct Stats {
        var nullables = 0
        var unrequired = 0
        var responseEnums = 0
        var openedSchemas = 0
        var renamed = 0
    }

    static func main() async throws {
        // Hand-rolled parsing keeps the tool dependency-light (GitLabKit precedent).
        var fetch = true
        var input: String?
        var output = defaultOutput
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--no-fetch": fetch = false
            case "--input": input = iterator.next()
            default: if !arg.hasPrefix("--") { output = arg }
            }
        }

        let raw: Data
        let source: String?
        if let input {
            raw = try Data(contentsOf: URL(fileURLWithPath: input))
            source = specURL.absoluteString + " (via \((input as NSString).lastPathComponent))"
        } else if fetch {
            FileHandle.standardError.write(Data("Fetching \(specURL.absoluteString)\n".utf8))
            raw = try await URLSession.shared.data(from: specURL).0
            source = specURL.absoluteString
        } else {
            raw = try Data(contentsOf: URL(fileURLWithPath: output))
            source = nil  // in place: keep the existing provenance stamp
        }

        guard var root = try Yams.compose(yaml: String(decoding: raw, as: UTF8.self)) else {
            throw ToolError.couldNotParse
        }

        var stats = Stats()
        root = collapseNullables(root, stats: &stats)
        root = normalizeResponseSchemas(root, stats: &stats)
        root = shortenOperationIDs(root, stats: &stats)
        if let source {
            root = stamp(root, source: source, sha256: sha256(raw))
        }

        try Yams.serialize(node: root, allowUnicode: true)
            .write(toFile: output, atomically: true, encoding: .utf8)
        print("""
        Wrote \(output)
          nullable anyOf collapsed:  \(stats.nullables)
          properties made optional:  \(stats.unrequired)
          response enums stringified: \(stats.responseEnums)
          response schemas opened:   \(stats.openedSchemas)
          operation ids shortened:   \(stats.renamed)
        """)
    }

    // MARK: Transform 1 — nullables

    static func collapseNullables(_ node: Node, stats: inout Stats) -> Node {
        switch node {
        case .scalar, .alias:
            return node
        case .sequence(var seq):
            for i in seq.indices {
                let child = collapseNullables(seq[i], stats: &stats)
                if let collapsed = collapsedNullable(child) {
                    seq[i] = collapsed
                    stats.nullables += 1
                } else {
                    seq[i] = child
                }
            }
            return .sequence(seq)
        case .mapping(var map):
            var optionalized: Set<String> = []
            for key in Array(map.keys) {
                guard let value = map[key] else { continue }
                // Properties are handled here, one level down, so that collapsing one is
                // seen and its name can leave `required`.
                if key.string == "properties", case .mapping(var properties) = value {
                    for name in Array(properties.keys) {
                        guard let property = properties[name] else { continue }
                        var child = collapseNullables(property, stats: &stats)
                        if let collapsed = collapsedNullable(child) {
                            child = collapsed
                            stats.nullables += 1
                            // Only a nullable `$ref` (or an untyped schema) lost its `null`;
                            // a typed one says `type: [T, "null"]` and stays required.
                            if !isTypedNullable(collapsed), let name = name.string { optionalized.insert(name) }
                        }
                        properties[name] = child
                    }
                    map[key] = .mapping(properties)
                    continue
                }
                var child = collapseNullables(value, stats: &stats)
                if let collapsed = collapsedNullable(child) {
                    child = collapsed
                    stats.nullables += 1
                }
                map[key] = child
            }
            if !optionalized.isEmpty, case .sequence(let required)? = map["required"] {
                let kept = required.filter { !optionalized.contains($0.string ?? "") }
                stats.unrequired += required.count - kept.count
                map["required"] = kept.isEmpty ? nil : .sequence(Node.Sequence(kept))
            }
            return .mapping(map)
        }
    }

    /// The rewrite of a schema of the form `anyOf: [X, {type: null}]` (either order), else `nil`.
    ///
    /// - If `X` has a single `type: T`, the result is `X` with `type: [T, "null"]`: OpenAPI 3.1's own
    ///   spelling of nullable, which the generator reads as `T?`. `required` can then stay as the
    ///   spec says (DeepWiki review of swift-openapi-generator, 2026-10-18).
    /// - Otherwise (a `$ref`, or an untyped schema) 3.1 has no other spelling, so the result is `X`
    ///   alone and the caller makes the field non-required. Onto a `$ref` only `description` carries
    ///   over, since the generator ignores `$ref` siblings.
    ///
    /// Sibling keys (`title`, `description`, `default`, …) carry over onto a non-`$ref` `X`.
    static func collapsedNullable(_ node: Node) -> Node? {
        guard case .mapping(let map) = node,
              case .sequence(let anyOf)? = map["anyOf"], anyOf.count == 2,
              anyOf.filter(isNullSchema).count == 1,
              let kept = anyOf.first(where: { !isNullSchema($0) }),
              case .mapping(var merged) = kept
        else { return nil }
        let isRef = merged["$ref"] != nil
        for (key, value) in map where key.string != "anyOf" {
            if isRef {
                if key.string == "description" { merged[key] = value }
            } else if merged[key] == nil {
                merged[key] = value
            }
        }
        if !isRef, let type = merged["type"]?.string, type != "null" {
            merged["type"] = [Node(type), Node("null")]
        }
        return .mapping(merged)
    }

    /// Whether `node` declares its nullability itself (`type: [T, "null"]`).
    static func isTypedNullable(_ node: Node) -> Bool {
        guard case .sequence(let types)? = node["type"] else { return false }
        return types.contains { $0.string == "null" }
    }

    static func isNullSchema(_ node: Node) -> Bool {
        guard case .mapping(let map) = node else { return false }
        return map.count == 1 && map["type"]?.string == "null"
    }

    // MARK: Transforms 2 and 4 — response enums, closed response schemas

    /// Walks every schema reachable from a response, inline or by reference, and applies
    /// transforms 2 and 4 to it (``normalizingResponse(_:stats:)``).
    static func normalizeResponseSchemas(_ root: Node, stats: inout Stats) -> Node {
        guard case .mapping(var rootMap) = root else { return root }

        // Inline response schemas, and the names of every component schema they reach.
        var reached = Set<String>()
        if case .mapping(var paths)? = rootMap["paths"] {
            for pathKey in Array(paths.keys) {
                guard case .mapping(var item)? = paths[pathKey] else { continue }
                for method in Array(item.keys) {
                    guard case .mapping(var operation)? = item[method],
                          let responses = operation["responses"] else { continue }
                    collectSchemaRefs(responses, into: &reached)
                    operation["responses"] = normalizingResponse(responses, stats: &stats)
                    item[method] = .mapping(operation)
                }
                paths[pathKey] = .mapping(item)
            }
            rootMap["paths"] = .mapping(paths)
        }

        guard case .mapping(var components)? = rootMap["components"],
              case .mapping(var schemas)? = components["schemas"] else { return .mapping(rootMap) }
        var frontier = reached
        while !frontier.isEmpty {
            var next = Set<String>()
            for name in frontier {
                guard let schema = schemas[name] else { continue }
                var refs = Set<String>()
                collectSchemaRefs(schema, into: &refs)
                for ref in refs where !reached.contains(ref) {
                    reached.insert(ref)
                    next.insert(ref)
                }
            }
            frontier = next
        }
        for name in reached {
            guard let schema = schemas[name] else { continue }
            schemas[name] = normalizingResponse(schema, stats: &stats)
        }
        components["schemas"] = .mapping(schemas)
        rootMap["components"] = .mapping(components)
        return .mapping(rootMap)
    }

    /// In `node`'s subtree, drops `enum` from every string (or untyped) schema (transform 2) and
    /// `additionalProperties: false` from every schema (transform 4). An `additionalProperties`
    /// that is a schema, or `true`, stays: only the boolean `false` closes an object.
    ///
    /// Every mapping is read as a schema. That holds for this document, which has no property
    /// named `enum` or `additionalProperties` and no such key inside example or default data
    /// (checked 2026-10-19); a document that did would need a walk aware of schema positions.
    static func normalizingResponse(_ node: Node, stats: inout Stats) -> Node {
        switch node {
        case .scalar, .alias:
            return node
        case .sequence(var seq):
            for i in seq.indices { seq[i] = normalizingResponse(seq[i], stats: &stats) }
            return .sequence(seq)
        case .mapping(var map):
            for key in Array(map.keys) where key.string != "enum" {
                guard let value = map[key] else { continue }
                map[key] = normalizingResponse(value, stats: &stats)
            }
            // A nullable string enum arrives from transform 1 as `type: [string, "null"]`, a
            // sequence, which `.string` can't read: it is typed already and must keep its "null"
            // (diff review of M1's second PR through kick). Only an untyped enum gets "string".
            let type = map["type"]
            let types = type?.sequence?.compactMap(\.string) ?? type?.string.map { [$0] } ?? []
            if map["enum"] != nil, types.isEmpty || types.contains("string") {
                map["enum"] = nil
                if type == nil { map["type"] = "string" }
                stats.responseEnums += 1
            }
            if map["additionalProperties"]?.bool == false {
                map["additionalProperties"] = nil
                stats.openedSchemas += 1
            }
            return .mapping(map)
        }
    }

    // MARK: Transform 3 — operation ids

    static func shortenOperationIDs(_ root: Node, stats: inout Stats) -> Node {
        guard case .mapping(var rootMap) = root,
              case .mapping(var paths)? = rootMap["paths"] else { return root }

        // Pass 1: the candidate short name for every FastAPI-style id.
        var all = Set<String>()
        var candidates: [String: String] = [:]
        for (pathKey, item) in paths {
            guard case .mapping(let methods) = item, let path = pathKey.string else { continue }
            for (_, operation) in methods {
                guard let id = operation["operationId"]?.string else { continue }
                all.insert(id)
                guard let match = id.wholeMatch(of: #/handle_(.+?)_v3_.*_(?:get|post|put|delete|patch)/#)
                else { continue }
                let short = String(match.1)
                candidates[id] = path.hasPrefix("/v3/enterprise/") ? "enterprise_" + short : short
            }
        }
        var uses: [String: Int] = [:]
        for name in candidates.values { uses[name, default: 0] += 1 }
        let renames = candidates.filter { uses[$0.value] == 1 && !all.contains($0.value) }

        // Pass 2: apply the unique ones.
        for pathKey in Array(paths.keys) {
            guard case .mapping(var methods)? = paths[pathKey] else { continue }
            for method in Array(methods.keys) {
                guard case .mapping(var operation)? = methods[method],
                      let id = operation["operationId"]?.string, let short = renames[id] else { continue }
                operation["operationId"] = Node(short)
                methods[method] = .mapping(operation)
                stats.renamed += 1
            }
            paths[pathKey] = .mapping(methods)
        }
        rootMap["paths"] = .mapping(paths)
        return .mapping(rootMap)
    }

    // MARK: Helpers

    /// Collects every `#/components/schemas/X` reference reachable in `node` as the bare `X`.
    static func collectSchemaRefs(_ node: Node, into refs: inout Set<String>) {
        switch node {
        case .scalar, .alias:
            return
        case .sequence(let seq):
            for item in seq { collectSchemaRefs(item, into: &refs) }
        case .mapping(let map):
            let prefix = "#/components/schemas/"
            for (key, value) in map {
                if key.string == "$ref", let ref = value.string, ref.hasPrefix(prefix) {
                    refs.insert(String(ref.dropFirst(prefix.count)))
                } else {
                    collectSchemaRefs(value, into: &refs)
                }
            }
        }
    }

    /// Records where the vendored spec came from, under `info.x-devin-kick`.
    static func stamp(_ root: Node, source: String, sha256: String) -> Node {
        guard case .mapping(var rootMap) = root, case .mapping(var info)? = rootMap["info"] else { return root }
        let date = Date.now.formatted(.iso8601.year().month().day())
        info["x-devin-kick"] = ["source": Node(source), "sha256": Node(sha256), "vendored": Node(date)]
        rootMap["info"] = .mapping(info)
        return .mapping(rootMap)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ToolError: Error { case couldNotParse }
