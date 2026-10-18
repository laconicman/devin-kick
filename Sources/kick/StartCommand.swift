import ArgumentParser
import DevinKickKit
import Foundation

/// The options `kick start` and `kick run` share.
struct StartFlags: ParsableArguments {
    @Option(help: "A prompt file; its text is the session's first message, byte for byte.")
    var prompt: String?

    @Option(help: "A JSON manifest: [{prompt_file, title, schema_file?, attach?, mode?, tags?}]. Relative paths resolve against its directory.")
    var manifest: String?

    @Option(help: "The session's title (with --prompt).")
    var title: String?

    @Option(help: "A JSON Schema file for the structured output (with --prompt); kick adds kick_final. Default: {answer_md, doubts, questions_for_user}.")
    var schema: String?

    @Option(help: "A file to attach (with --prompt), inside KICK_UPLOAD_ROOTS. Repeatable.")
    var attach: [String] = []

    @Option(help: "The Devin mode, for every session (default: a manifest entry's mode, then KICK_MODE, then swe-2-max).")
    var mode: String?

    @Option(name: .customLong("tag"), help: "A tag for every session. Repeatable.")
    var tags: [String] = []

    @Flag(name: .customLong("no-resumable"), help: "Don't keep the session's VM state after it stops.")
    var noResumable = false

    @Flag(name: .customLong("no-bypass-approval"), help: "Let Devin wait for approvals (they read as needs input).")
    var noBypassApproval = false

    @Option(name: .customLong("acu-limit"), help: "The session's ACU limit.")
    var acuLimit: Int?

    @Option(help: "The directory to put run directories in, instead of KICK_STORE/runs; the index stays in KICK_STORE.")
    var out: String?

    func validate() throws {
        guard (prompt == nil) != (manifest == nil) else {
            throw ValidationError("Give exactly one of --prompt and --manifest.")
        }
        if manifest != nil, title != nil || schema != nil || !attach.isEmpty {
            throw ValidationError("--title, --schema and --attach go with --prompt; a manifest names them per entry.")
        }
    }

    /// Every session these flags describe, validated before anything is sent.
    func requests(_ kick: DevinKick) throws(KickError) -> [SessionRequest] {
        let options = StartOptions(
            mode: try mode.map { mode throws(KickError) in try DevinMode(mode) },
            tags: tags,
            resumable: !noResumable,
            bypassApproval: !noBypassApproval,
            acuLimit: acuLimit,
            outDirectory: out.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        )
        if let manifest {
            return try kick.prepare(manifest: try Manifest.load(URL(fileURLWithPath: manifest)), options: options)
        }
        return [try kick.prepare(promptFile: prompt ?? "", title: title, schemaFile: schema, attach: attach, options: options)]
    }
}

/// `kick start` — create sessions, recorded at submit.
struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start one session from a prompt file, or a batch from a manifest.",
        discussion: """
        Prints one line per session: run id, session id, URL, run directory. Every entry is \
        validated before the first one starts; then entries start one at a time, and one that \
        fails doesn't stop the rest. The exit status is then the first failure's.
        """
    )

    @OptionGroup var flags: StartFlags

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            let kick = try DevinKick.fromEnvironment()
            var firstFailure: KickError?
            for request in try flags.requests(kick) {
                do throws(KickError) {
                    let started = try await kick.start(request)
                    print(started.line)
                } catch {
                    printError("\(request.title ?? request.promptFile.lastPathComponent): \(error.localizedDescription)")
                    firstFailure = firstFailure ?? error
                }
            }
            if let firstFailure { throw firstFailure }
        }
    }
}

extension StartedRun {
    /// `run id  session id  URL  directory`, and any duplicate found under the run's tag.
    var line: String {
        var line = "\(run.runID)  \(sessionID)  \(url)  \(run.directory.path)"
        if !run.duplicates.isEmpty {
            line += "\n  also under this run's tag: \(run.duplicates.joined(separator: ", "))"
        }
        return line
    }
}
