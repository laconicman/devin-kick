import DevinKickKit
import MCP

extension ToolSpec {
    struct ArchiveInput: Decodable, Sendable {
        var ids: StringList
    }

    /// `kick_archive`: puts sessions away, reversibly. Ending one for good stays a person's CLI
    /// action, `kick archive --terminate` (owner, 2026-10-19).
    static let archive = ToolSpec(
        name: "kick_archive",
        title: "Archive Devin sessions",
        description: """
        Archive sessions you are done with: a running one is put to sleep, and a reply wakes it \
        again. Returns each session's status after the archive. Save the ones whose results you \
        need first (kick_save). This tool never ends a session for good: a person does that with \
        `kick archive --terminate`.
        """,
        schema: InputSchema.object(["ids": InputSchema.list("Run ids, session ids or run directories.")], required: ["ids"]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    ) { (input: ArchiveInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        guard !input.ids.items.isEmpty else { throw .usage("Name at least one session in ids.") }
        var lines: [String] = []
        var archived = 0
        for id in input.ids.items {
            do throws(KickError) {
                let session = try await kick.archive(id)
                lines.append("\(session.id)  archived  \(session.status)\(session.statusDetail.map { "/\($0)" } ?? "")")
                archived += 1
            } catch {
                lines.append(ToolReply.failure(id, error))
            }
        }
        return ToolReply(
            lines: lines,
            next: "next: nothing more is needed; kick_reply wakes an archived session if you need it again.",
            rest: "`kick list --tag kick` in a shell lists the runs",
            isError: archived == 0
        )
    }
}
