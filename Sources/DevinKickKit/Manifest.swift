public import Foundation

/// A batch of sessions to start: a JSON array of
/// `{prompt_file, title, schema_file?, attach?, mode?, tags?}`.
///
/// It is decoded by Foundation, so it needs no YAML dependency. Relative paths resolve against
/// the manifest's own directory, and every entry is validated before the first POST
/// (``DevinKick/prepare(manifest:options:)``), so a usage error aborts with nothing started.
public struct Manifest: Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var promptFile: String
        public var title: String
        public var schemaFile: String?
        public var attach: [String]?
        public var mode: String?
        public var tags: [String]?

        enum CodingKeys: String, CodingKey {
            case title, attach, mode, tags
            case promptFile = "prompt_file"
            case schemaFile = "schema_file"
        }
    }

    public var entries: [Entry]
    /// The directory relative paths resolve against.
    public var directory: URL

    public init(entries: [Entry], directory: URL) {
        self.entries = entries
        self.directory = directory
    }

    /// Reads and decodes the manifest at `file`.
    public static func load(_ file: URL) throws(KickError) -> Manifest {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .usage("Couldn't read the manifest \(file.path) (\(error.localizedDescription)).")
        }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch let error as DecodingError {
            throw .usage("The manifest \(file.path) is not valid: \(describe(error)). Expected a JSON array of {prompt_file, title, schema_file?, attach?, mode?, tags?}.")
        } catch {
            throw .usage("The manifest \(file.path) is not valid (\(error.localizedDescription)).")
        }
        guard !entries.isEmpty else { throw .usage("The manifest \(file.path) has no entries.") }
        return Manifest(entries: entries, directory: file.deletingLastPathComponent())
    }

    /// A decoding error as a path and a cause, such as `[2].prompt_file is missing`; the MCP
    /// server names a tool's bad argument the same way.
    public static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : (text.isEmpty ? "the root" : text)
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context.codingPath)) has the wrong type"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not JSON" : "\(path(context.codingPath)) is unreadable"
        @unknown default:
            return "unreadable"
        }
    }
}
