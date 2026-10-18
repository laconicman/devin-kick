import DevinKickKit
import Foundation

/// The optional run log: when `KICK_LOG_TSV` names a file, every run that settles (`run`,
/// `save`) appends one line in the 9 columns fstec's `devin.py` already keeps:
/// `date title session_id url mode status status_detail acus attachments`, with a header when
/// the file is new.
///
/// Off by default, and its failures are swallowed: a log line must never break a result. It
/// lives in the executable, not the Kit, because logging policy is an application concern;
/// adapted from deepwiki-mcp's `UsageLog` (`Sources/deepwiki/UsageLog.swift`).
enum TSVLog {
    static let environmentVariable = "KICK_LOG_TSV"
    static let header = ["date", "title", "session_id", "url", "mode", "status", "status_detail", "acus", "attachments"]

    static func append(
        _ saved: SavedRun,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        date: Date = Date()
    ) {
        guard let path = environment[environmentVariable], !path.isEmpty, let session = saved.reading.session else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fields = [
            formatter.string(from: date), session.title ?? saved.run.title ?? "", session.id, session.url,
            saved.run.mode ?? session.mode ?? "", session.status, session.statusDetail ?? "",
            String(session.acusConsumed), String(attachmentCount(saved.run.directory)),
        ]
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        var text = fields.map(clean).joined(separator: "\t") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            text = header.joined(separator: "\t") + "\n" + text
            try? Data(text.utf8).write(to: url)
        }
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
