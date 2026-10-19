import DevinKickKit
import Foundation
import MCP

extension ToolSpec {
    struct UploadInput: Decodable, Sendable {
        var paths: StringList
    }

    /// `kick_upload`: files into Devin's attachments, only from `KICK_UPLOAD_ROOTS`, never twice.
    static let upload = ToolSpec(
        name: "kick_upload",
        title: "Upload files for Devin",
        description: """
        Upload local files for Devin sessions to read; returns each file's attachment URL. Only \
        files inside the directories in KICK_UPLOAD_ROOTS can be uploaded, because uploads are \
        permanent, and a file whose content and name were uploaded before is not sent again. \
        kick_start and kick_reply upload their attach files themselves: call this only to check \
        files, or to upload them ahead of time. Absolute paths are safest; a relative one resolves \
        against the server's working directory.
        """,
        schema: InputSchema.object(["paths": InputSchema.list("The files to upload.")], required: ["paths"]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    ) { (input: UploadInput, kick: DevinKick) async throws(KickError) -> ToolReply in
        guard !input.paths.items.isEmpty else { throw .usage("Name at least one file in paths.") }
        let uploads = try await kick.upload(input.paths.items)
        return ToolReply(
            lines: uploads.map { "\($0.file.path) → \($0.url) (\($0.cached ? "cached" : "uploaded"))" },
            next: "next: name these files in attach for kick_start or kick_reply; they are not uploaded again.",
            rest: "`kick upload` with the same paths prints every line, uploading nothing twice"
        )
    }
}
