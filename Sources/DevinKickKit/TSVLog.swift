import Foundation

/// The optional run log: when `KICK_LOG_TSV` names a file, every run that settles appends one
/// line in the 9 columns fstec's `devin.py` already keeps:
/// `date title session_id url mode status status_detail acus attachments`, with a header when
/// the file is new.
///
/// ``DevinKick/save(_:)`` writes it, so `kick save`, `kick run` and the MCP server's `kick_save`
/// each log a settled run once, and neither face can forget to. It is a derived file: a write
/// that fails only warns, since a log line must never break a result. Adapted from
/// deepwiki-mcp's `UsageLog` (`Sources/deepwiki/UsageLog.swift`), which lives in its executable;
/// this one moved into the Kit with M2, because the server is a library target.
enum TSVLog {
    static let header = ["date", "title", "session_id", "url", "mode", "status", "status_detail", "acus", "attachments"]

    /// Appends `saved`'s line to `url` in one `write(2)`, as the index appends
    /// (``RunStore/appendLine(_:to:)``), after a header when the file is new. Nothing for a run
    /// whose session wasn't read.
    static func append(_ saved: SavedRun, to url: URL, date: Date = Date()) throws {
        guard let session = saved.reading.session else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fields = [
            formatter.string(from: date), session.title ?? saved.run.title ?? "", session.id, session.url,
            saved.run.mode ?? session.mode ?? "", session.status, session.statusDetail ?? "",
            String(session.acusConsumed), String(attachmentCount(saved.run.directory)),
        ]
        var text = fields.map(clean).joined(separator: "\t")
        if !FileManager.default.fileExists(atPath: url.path) {
            text = header.joined(separator: "\t") + "\n" + text
        }
        try RunStore.appendLine(Data(text.utf8), to: url)
    }

    /// Tabs and line breaks would break the columns.
    static func clean(_ field: String) -> String {
        field.components(separatedBy: CharacterSet(charactersIn: "\t\r\n")).joined(separator: " ")
    }

    /// The files attached at create, from `request.json`; 0 for a session kick didn't start.
    static func attachmentCount(_ directory: URL) -> Int {
        guard let data = try? Data(contentsOf: directory.appending(path: "request.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return (record["attach"] as? [Any])?.count ?? 0
    }
}
