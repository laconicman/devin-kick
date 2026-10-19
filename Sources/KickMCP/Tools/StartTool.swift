import DevinKickKit
import Foundation
import MCP

extension ToolSpec {
    struct StartInput: Decodable, Sendable {
        struct Session: Decodable, Sendable {
            var promptFile: String?
            var prompt: String?
            var title: String?
            var schemaFile: String?
            var attach: StringList?
            var tags: StringList?
            var mode: String?

            enum CodingKeys: String, CodingKey {
                case prompt, title, attach, tags, mode
                case promptFile = "prompt_file"
                case schemaFile = "schema_file"
            }

            /// Exactly one of `prompt_file` and `prompt`.
            func source() throws(KickError) -> PromptSource {
                switch (promptFile, prompt) {
                case (let file?, nil): return .file(file)
                case (nil, let text?): return .text(text)
                default: throw .usage("Give exactly one of prompt_file and prompt.")
                }
            }
        }

        var sessions: [Session]
        var mode: String?
        var resumable: Bool?
        var confirmedByOperator: Bool?

        enum CodingKeys: String, CodingKey {
            case sessions, mode, resumable
            case confirmedByOperator = "confirmed_by_operator"
        }
    }

    /// The most sessions one `kick_start` call starts without the operator's confirmation
    /// (owner, 2026-10-19): approvals are bypassed by default and no tool can turn that off, so
    /// one call must not fan out without a bound. The CLI's manifests stay uncapped, since a
    /// person runs them.
    static let startBatchLimit = 20

    /// `kick_start`: one session or a batch, each recorded at submit; returns at once.
    /// `bypassApproval` is the operator's choice at `kick serve`'s launch, never an argument.
    static func start(bypassApproval: Bool) -> ToolSpec {
        let modes = DevinMode.known
        return ToolSpec(
            name: "kick_start",
            title: "Start Devin sessions",
            description: """
            Start Devin sessions, one or a batch, and return AT ONCE with each one's run id, \
            session id, URL and run directory: it does not wait for Devin. Next, call kick_wait \
            with the run ids, and again until every session has settled; then kick_save, and read \
            the results from the files it names.

            Each session takes exactly one of:
            - prompt_file: a file whose text is sent byte for byte. Preferred: byte-identical by \
            construction, reusable, and it costs you no context.
            - prompt: the text inline. It needs no file and is recorded as prompt.md in the run \
            directory just the same, but re-typing text that already exists risks \
            mis-transcribing it.

            Every session returns structured output: a schema_file's JSON Schema, or by default \
            {answer_md, doubts, questions_for_user}, and kick adds its kick_final field. attach \
            files must lie inside KICK_UPLOAD_ROOTS. The mode is the call's mode, else the \
            session's, else KICK_MODE, else swe-2-max.

            At most \(startBatchLimit) sessions per call. For more, split the batch, or ask the \
            operator and, if they agree, call again with confirmed_by_operator: true; give such a \
            batch one tag of its own, since kick_status can read every session by it.
            """,
            schema: InputSchema.object([
                "sessions": InputSchema.array(of: InputSchema.object([
                    "prompt_file": InputSchema.string("A file whose text is the first message, byte for byte; absolute, or relative to the server's working directory."),
                    "prompt": InputSchema.string("The first message itself, when there is no file; recorded as prompt.md."),
                    "title": InputSchema.string("The session's title."),
                    "schema_file": InputSchema.string("A JSON Schema file for the structured output (root type object); kick adds kick_final."),
                    "attach": InputSchema.list("Files to attach, inside KICK_UPLOAD_ROOTS."),
                    "tags": InputSchema.list("Tags for this session; kick adds kick and kick-run-<run id>."),
                    "mode": InputSchema.oneOf(modes, "This session's Devin mode."),
                ]), "The sessions to start."),
                "mode": InputSchema.oneOf(modes, "Every session's Devin mode, over the sessions' own."),
                "resumable": InputSchema.boolean("Keep each session's machine when it stops, so a reply can wake it. Default true."),
                "confirmed_by_operator": InputSchema.boolean("True only after the operator agreed to start more than \(startBatchLimit) sessions in this call."),
            ], required: ["sessions"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        ) { (input: StartInput, kick: DevinKick) async throws(KickError) -> ToolReply in
            let requests = try prepare(input, kick: kick, bypassApproval: bypassApproval)
            var lines: [String] = []
            var started: [StartedRun] = []
            for (index, request) in requests.enumerated() {
                // A cancelled call starts nothing more; the one in flight is recorded either way.
                guard !Task.isCancelled else { break }
                do throws(KickError) {
                    let run = try await kick.start(request)
                    started.append(run)
                    lines.append(run.line)
                } catch {
                    // Named by its index too, as a validation error is: untitled inline prompts
                    // share a name (swe-2-max review, 2026-10-19).
                    lines.append(ToolReply.failure("sessions[\(index)] (\(request.name))", error))
                }
            }
            let failed = requests.count - started.count
            // Up to the batch limit the next step names every run id; a confirmed larger batch's
            // ids would outgrow the cap (Devin Review, PR #13), so it points at the lines instead.
            let wait = started.count <= startBatchLimit
                ? "call kick_wait with ids [\(started.map { "\"\($0.run.runID)\"" }.joined(separator: ", "))],"
                : "call kick_wait with the run ids above, at most \(startBatchLimit) per call,"
            return ToolReply(
                lines: ["started \(started.count) of \(requests.count):"] + lines,
                next: started.isEmpty
                    ? "next: fix what each line says, then call kick_start again."
                    : "next: \(wait) and again until every session has settled."
                        + (failed > 0 ? " The ones that failed did not start: fix them and start them again." : ""),
                rest: "kick_status with a tag every session of the batch carries (`kick list --tag kick` in a shell)",
                isError: started.isEmpty
            )
        }
    }

    /// Every session of `input`, validated before the first is started, as a manifest's are: a
    /// usage error names the session and nothing is sent.
    static func prepare(_ input: StartInput, kick: DevinKick, bypassApproval: Bool) throws(KickError) -> [SessionRequest] {
        guard !input.sessions.isEmpty else { throw .usage("sessions is empty: give at least one session to start.") }
        guard input.sessions.count <= startBatchLimit || input.confirmedByOperator == true else {
            throw .usage("\(input.sessions.count) sessions in one call is over the limit of \(startBatchLimit), and nothing was started. Split the batch into calls of at most \(startBatchLimit), or ask the operator and, if they agree, call again with confirmed_by_operator: true.")
        }
        let options = StartOptions(
            mode: try input.mode.map { mode throws(KickError) in try DevinMode(mode) },
            resumable: input.resumable ?? true,
            bypassApproval: bypassApproval
        )
        var requests: [SessionRequest] = []
        for (index, session) in input.sessions.enumerated() {
            do throws(KickError) {
                requests.append(try kick.prepare(
                    try session.source(), title: session.title, schemaFile: session.schemaFile,
                    attach: session.attach?.items ?? [], mode: try session.mode.map { mode throws(KickError) in try DevinMode(mode) },
                    tags: session.tags?.items ?? [], options: options
                ))
            } catch {
                throw .usage("sessions[\(index)] (\(session.title ?? "untitled")): \(error.localizedDescription) Nothing was started.")
            }
        }
        return requests
    }
}
