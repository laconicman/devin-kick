@testable import DevinKickKit
import Foundation
import Testing

@Suite("Schema — kick's completion field, added and read back")
struct SchemaTests {
    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theDefaultSchemaGainsARequiredFinalField() throws {
        let schema = try Self.object(try Schema.augmented())
        let properties = try #require(schema["properties"] as? [String: Any])
        let final = try #require(properties[Schema.finalField] as? [String: Any])
        #expect(final["type"] as? String == "boolean")
        #expect(Set(properties.keys) == ["answer_md", "doubts", "questions_for_user", Schema.finalField])
        #expect(schema["required"] as? [String] == ["answer_md", "doubts", "questions_for_user", Schema.finalField])
    }

    @Test func aCustomObjectSchemaKeepsItsOwnFields() throws {
        let custom = Data(#"{"type":"object","properties":{"verdict":{"type":"string"}},"required":["verdict"]}"#.utf8)
        let schema = try Self.object(try Schema.augmented(custom))
        #expect(schema["required"] as? [String] == ["verdict", Schema.finalField])
        #expect((schema["properties"] as? [String: Any])?["verdict"] != nil)
    }

    /// A root kick can't merge a property into is a usage error before anything is sent.
    @Test(arguments: [
        #"[1, 2]"#,
        #"{"type": "array"}"#,
        #"{"allOf": [{"type": "object"}]}"#,
        #"{"type": "object", "anyOf": [{"required": ["a"]}]}"#,
        #"{"type": "object", "properties": {"kick_final": {"type": "boolean"}}}"#,
        "not json",
    ])
    func unaugmentableSchemasAreUsageErrors(_ text: String) {
        #expect {
            try Schema.augmented(Data(text.utf8))
        } throws: { error in
            (error as? KickError)?.exitCode == 64
        }
    }

    @Test func aSchemaOverTheAPICapIsAUsageError() {
        let padding = String(repeating: "x", count: Schema.maximumBytes)
        let big = Data(#"{"type":"object","description":"\#(padding)"}"#.utf8)
        #expect(throws: KickError.self) { try Schema.augmented(big) }
    }

    struct VerdictCase: Sendable, CustomTestStringConvertible {
        let output: String?
        let replied: Bool
        let expected: OutputVerdict
        var testDescription: String { "\(output ?? "nil")\(replied ? " after a reply" : "") → \(expected.rawValue)" }
    }

    @Test(arguments: [
        VerdictCase(output: nil, replied: false, expected: .none),
        VerdictCase(output: #"{"answer_md":"a","questions_for_user":[],"kick_final":true}"#, replied: false, expected: .final),
        VerdictCase(output: #"{"answer_md":"a","questions_for_user":[],"kick_final":true}"#, replied: true, expected: .staleFinal),
        VerdictCase(output: #"{"answer_md":"","kick_final":false}"#, replied: false, expected: .provisional),
        // A pending question outranks a final flag: Devin is asking.
        VerdictCase(output: #"{"questions_for_user":["Which repo?"],"kick_final":true}"#, replied: false, expected: .provisional),
        VerdictCase(output: #"{"questions_for_user":["Which repo?"],"kick_final":true}"#, replied: true, expected: .provisional),
        // A session kick didn't create, or output that isn't an object.
        VerdictCase(output: #"{"answer_md":"a"}"#, replied: false, expected: .unmarked),
        VerdictCase(output: #"{"kick_final":"yes"}"#, replied: false, expected: .unmarked),
        VerdictCase(output: #"[true]"#, replied: false, expected: .unmarked),
    ])
    func outputReadsAsAVerdict(_ c: VerdictCase) {
        #expect(OutputVerdict(output: c.output.map { Data($0.utf8) }, repliedByKick: c.replied) == c.expected)
    }
}
