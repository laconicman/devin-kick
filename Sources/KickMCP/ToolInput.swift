import DevinKickKit
import Foundation
import MCP

/// A tool call's arguments, decoded into the tool's own `Decodable` input (amendment A17).
enum ToolInput {
    /// `arguments` as `Input`, checked against the tool's `schema` first. Every failure is a usage
    /// error naming the field, such as `sessions[1].prompt_file has the wrong type`, so the model
    /// can correct the call.
    ///
    /// Two checks go beyond decoding:
    /// - A name the schema doesn't list is refused. Decoding ignores it, and a guessed name such
    ///   as `attachments` for `attach` would start a session without its files.
    /// - A text that reads as a `data:` URL is refused. swift-sdk 0.12.1 decodes such a string
    ///   into bytes (`Value.data`) and re-encodes it as base64, so a prompt beginning
    ///   `data: …, …` would reach Devin rewritten (`Value.init(from:)`, verified in its source).
    static func decode<Input: Decodable>(_ type: Input.Type, from arguments: [String: Value], schema: Value) throws(KickError) -> Input {
        try check(.object(arguments), against: schema, at: "")
        let data: Data
        do {
            data = try JSONEncoder().encode(arguments)
        } catch {
            throw .usage("The arguments could not be read (\(error.localizedDescription)).")
        }
        do {
            return try JSONDecoder().decode(Input.self, from: data)
        } catch let error as DecodingError {
            throw .usage("Invalid arguments: \(Manifest.describe(error)).")
        } catch {
            throw .usage("Invalid arguments (\(error.localizedDescription)).")
        }
    }

    /// Walks `value` beside its `schema`, through object properties and array items.
    static func check(_ value: Value, against schema: Value?, at path: String) throws(KickError) {
        switch value {
        case .data:
            // TODO(TD-9): goes once the SDK keeps such a string a string (swift-sdk#277).
            throw .usage("\(path) reads as a data: URL, which this server's MCP library turns into bytes, so it can't pass the text on as written. Put the text in a file and pass the file's path instead.")
        case .object(let fields):
            guard let properties = schema?.objectValue?["properties"]?.objectValue else { return }
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                let fieldPath = path.isEmpty ? name : "\(path).\(name)"
                guard let fieldSchema = properties[name] else {
                    throw .usage("Unknown argument \(fieldPath). Arguments here: \(properties.keys.sorted().joined(separator: ", ")).")
                }
                try check(field, against: fieldSchema, at: fieldPath)
            }
        case .array(let items):
            let itemSchema = schema?.objectValue?["items"]
            for (index, item) in items.enumerated() {
                try check(item, against: itemSchema, at: "\(path)[\(index)]")
            }
        case .null, .bool, .int, .double, .string:
            return
        }
    }
}

/// A list argument, as models send lists: a JSON array of strings, or one comma-separated string
/// (deepwiki-mcp's `stringArray`). In the second form an item can't contain a comma. Items are
/// trimmed, and empty ones dropped.
struct StringList: Decodable, Sendable, Hashable {
    var items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw: [String]
        if let array = try? container.decode([String].self) {
            raw = array
        } else {
            raw = try container.decode(String.self).components(separatedBy: ",")
        }
        items = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// JSON Schema for tool inputs, as the SDK's `Value`.
enum InputSchema {
    /// An object of `properties`, of which `required` must be given; no other names.
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    /// An array of `items`, at least one.
    static func array(of items: Value, _ description: String) -> Value {
        ["type": "array", "items": items, "minItems": 1, "description": .string(description)]
    }

    /// A ``StringList``, declared both ways it decodes: a client that validates arguments against
    /// the schema would otherwise refuse the comma-separated form before it reached the server
    /// (Devin Review, PR #13).
    static func list(_ description: String) -> Value {
        [
            "anyOf": [
                ["type": "array", "items": ["type": "string"]],
                ["type": "string", "description": "The items in one string, separated by commas; an item can't contain one."],
            ],
            "description": .string(description),
        ]
    }

    static func integer(_ description: String, minimum: Int, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "minimum": .int(minimum), "description": .string(description)]
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func oneOf(_ values: [String], _ description: String) -> Value {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }
}
