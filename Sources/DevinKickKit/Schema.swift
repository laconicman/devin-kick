public import Foundation

/// The JSON Schema kick sends with every session, and how it reads the output back.
///
/// Every session carries a schema (Design: "Every session carries a schema"). Without a
/// `schema_file`, kick sends ``defaultSchema``. Whichever schema is sent gains kick's own
/// completion field, ``finalField``, because the API never shows whether an output was meant as
/// final (<doc:TechDebt> TD-4): with `structured_output_required: true` the agent must call
/// `provide_structured_output` with `is_final=true` before *every* turn ends, asking turns
/// included (the spec's `SessionCreateRequest.structured_output_required`).
public enum Schema {
    /// kick's completion field, added as a required boolean to every schema kick sends.
    public static let finalField = "kick_final"

    /// The default schema's field for questions; a non-empty array also reads as not final.
    static let questionsField = "questions_for_user"

    /// The API's cap on `structured_output_schema`: "Max 64KB" (the spec's
    /// `SessionCreateRequest.structured_output_schema`), read as 64 × 1024 bytes.
    static let maximumBytes = 64 * 1024

    /// What the agent is told about ``finalField``.
    static let finalFieldDescription =
        "true only when this output is your final result; false while you are asking, blocked, or stopping early"

    /// `{answer_md, doubts, questions_for_user}` (owner's decision, 2026-10-18), before
    /// ``finalField`` is added.
    public static let defaultSchema = Data("""
    {
      "type": "object",
      "properties": {
        "answer_md": {
          "type": "string",
          "description": "The answer, in Markdown."
        },
        "doubts": {
          "type": "array",
          "items": {"type": "string"},
          "description": "What you are unsure of, and why."
        },
        "questions_for_user": {
          "type": "array",
          "items": {"type": "string"},
          "description": "Questions you need answered before you can finish; empty when you are done."
        }
      },
      "required": ["answer_md", "doubts", "questions_for_user"]
    }
    """.utf8)

    /// The schema as sent: `schema` (or ``defaultSchema``) with ``finalField`` added to its
    /// `properties` and `required`.
    ///
    /// The root must be a plain `type: object`, because a composed root (`allOf`, `anyOf`,
    /// `oneOf`) can't take a merged property. A root of any other kind, one that already defines
    /// ``finalField``, or a result over the API's 64 KB is a usage error.
    public static func augmented(_ schema: Data? = nil) throws(KickError) -> Data {
        let source = schema ?? defaultSchema
        guard var root = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] else {
            throw .usage("The schema is not a JSON object.")
        }
        guard root["type"] as? String == "object",
              root["allOf"] == nil, root["anyOf"] == nil, root["oneOf"] == nil else {
            throw .usage("The schema's root must be a plain \"type\": \"object\" (not composed with allOf/anyOf/oneOf), so kick can add its \"\(finalField)\" field.")
        }
        var properties = root["properties"] as? [String: Any] ?? [:]
        guard properties[finalField] == nil else {
            throw .usage("The schema already defines \"\(finalField)\"; kick adds that field itself. Remove it from the schema.")
        }
        properties[finalField] = ["type": "boolean", "description": finalFieldDescription]
        root["properties"] = properties
        root["required"] = (root["required"] as? [String] ?? []) + [finalField]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            throw .usage("The schema could not be re-encoded as JSON.")
        }
        guard data.count <= maximumBytes else {
            throw .usage("The schema is \(data.count) bytes once kick adds \"\(finalField)\"; the API accepts at most \(maximumBytes).")
        }
        return data
    }
}

/// What a session's structured output says about completion, as ``Settlement`` reads it.
public enum OutputVerdict: String, Sendable, Hashable {
    /// No output.
    case none
    /// `kick_final` is true, and no question is pending.
    case final
    /// `kick_final` is true, but kick posted a reply since: the session may have ended mid-turn
    /// with the previous turn's declaration still in place.
    case staleFinal = "stale-final"
    /// `kick_final` is false, or the default schema's `questions_for_user` is not empty.
    case provisional
    /// Output without `kick_final`: a session kick didn't create, or not a JSON object.
    case unmarked

    /// Reads `output`, the session's `structured_output` as JSON. `repliedByKick` is true when
    /// the run store holds a `replied` event for the session.
    public init(output: Data?, repliedByKick: Bool) {
        guard let output else {
            self = .none
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any],
              let final = object[Schema.finalField] as? Bool else {
            self = .unmarked
            return
        }
        let questions = object[Schema.questionsField] as? [Any] ?? []
        switch (final && questions.isEmpty, repliedByKick) {
        case (false, _): self = .provisional
        case (true, false): self = .final
        case (true, true): self = .staleFinal
        }
    }
}
