/// The exit statuses `kick` documents, in one place. `kick --help` prints ``help``, and a test
/// holds the README's table and every ``Settlement`` and ``KickError`` status to ``rows``, so a
/// change to one can't silently miss the others (CLAUDE.md rule 2).
public enum ExitStatus {
    /// Each status and its meaning, as the README's table states them.
    public static let rows: [(code: Int32, meaning: String)] = [
        (0, "done"),
        (10, "needs input: Devin asks, or awaits an approval"),
        (11, "unknown state, printed raw"),
        (75, "still working: poll again"),
        (69, "no answer, or 429 / 5xx: retry"),
        (1, "failed"),
        (64, "usage error"),
        (73, "the run store couldn't record the run (`KICK_STORE`, `--out`)"),
        (78, "configuration error"),
    ]

    /// The table for `kick --help`.
    public static var help: String {
        rows.map { row in
            let code = String(row.code)
            return "  " + code + String(repeating: " ", count: 4 - code.count) + row.meaning
        }.joined(separator: "\n")
    }
}
