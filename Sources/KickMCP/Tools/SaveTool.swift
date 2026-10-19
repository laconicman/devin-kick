import DevinKickKit
import Foundation
import MCP

extension ToolSpec {
    struct SaveInput: Decodable, Sendable {
        var ids: StringList
    }

    /// `kick_save`: each session's files into its run directory. The result is named, its keys
    /// listed, and never inlined (CLAUDE.md rule 6).
    static let save = ToolSpec(
        name: "kick_save",
        title: "Save Devin sessions' results",
        description: """
        Save sessions into their run directories: session.json, result.json (the structured \
        output), messages.json (the whole transcript) and attachments/. Returns each run \
        directory, its files with their sizes, and result.json's top-level keys and kick_final, \
        never the result itself: read result.json from the run directory. Save a session once \
        it has settled (kick_wait); a save of one still working records its current state, and \
        saving again replaces it.
        """,
        schema: InputSchema.object(["ids": InputSchema.list("Run ids, session ids or run directories.")], required: ["ids"]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    ) { (input: SaveInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        guard !input.ids.items.isEmpty else { throw .usage("Name at least one session in ids.") }
        var lines: [String] = []
        var saved = 0
        for id in input.ids.items {
            do throws(KickError) {
                lines += savedLines(try await kick.save(id))
                saved += 1
            } catch {
                lines.append(ToolReply.failure(id, error))
            }
        }
        return ToolReply(
            lines: lines,
            next: "next: read result.json in each run directory; kick_archive the sessions you are done with.",
            // A batch of up to 64 is saved in parts: saving again only rewrites the same files.
            rest: "call again with fewer ids at a time; every file is in its run directory",
            isError: saved == 0
        )
    }

    /// `run id  session id  state  directory`, then each file with its size in bytes, then the
    /// result's shape.
    static func savedLines(_ saved: SavedRun) -> [String] {
        let directory = saved.run.directory.path + "/"
        var lines = ["\(saved.run.runID)  \(saved.run.sessionID ?? "-")  \(saved.reading.outcome.label)  \(saved.run.directory.path)"]
        for file in saved.files {
            let name = file.path.hasPrefix(directory) ? String(file.path.dropFirst(directory.count)) : file.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
            lines.append("  \(name)  \(size.map { "\($0) B" } ?? "size unknown")")
        }
        lines.append("  " + resultShape(saved.reading.session?.structuredOutput))
        return lines
    }

    /// `result.json: kick_final true; keys answer_md, doubts, …`: what the result holds, never
    /// what it says.
    static func resultShape(_ output: Data?) -> String {
        guard let output else { return "result.json: none; Devin has given no structured output yet" }
        guard let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            return "result.json: not a JSON object"
        }
        let final = (object[Schema.finalField] as? Bool).map { "\(Schema.finalField) \($0)" } ?? "no \(Schema.finalField)"
        return "result.json: \(final); keys \(object.keys.sorted().joined(separator: ", "))"
    }
}
