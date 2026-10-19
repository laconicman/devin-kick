import Foundation

/// Reads what was appended to a file since it last read.
///
/// The run store's `index.jsonl` and the upload cache's `uploads.jsonl` are append-only JSON
/// Lines files that every `kick` process shares. A one-shot CLI could read them once, but a
/// long-lived process (the MCP server) would then miss what another process appends, so each of
/// its reads folds in the new lines (Design: "The run store").
///
/// Only complete lines are returned: a line another process is still writing is read once its
/// newline lands, so a partial line is never parsed.
struct TailReader: Sendable {
    let url: URL
    /// The bytes read so far, through the last complete line.
    private(set) var offset: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    /// The complete lines appended since the last read, oldest first. A file that no longer has
    /// a newline just before ``offset``, or is shorter than it, has been replaced, so it is read
    /// again from its start, and `restarted` says that what was folded from the old one no longer
    /// stands. A replacement with a newline at that very byte still reads as appended; kick's own
    /// files are only ever appended to. A missing file reads as nothing new.
    mutating func read() -> (lines: [Data], restarted: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], false) }
        // A read ends just past a newline, so any other byte there means another file; a size
        // check alone missed a replacement that grew (swe-2-max review, 2026-10-19).
        let restarted = size < offset || !Self.newline(before: offset, in: handle)
        if restarted { offset = 0 }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], restarted) }
        offset += UInt64(data.distance(from: data.startIndex, to: end) + 1)
        return (data[..<end].split(separator: UInt8(ascii: "\n")).map { Data($0) }, restarted)
    }

    /// Whether the byte just before `offset` is a newline; true at the start of a file.
    private static func newline(before offset: UInt64, in handle: FileHandle) -> Bool {
        guard offset > 0 else { return true }
        guard (try? handle.seek(toOffset: offset - 1)) != nil, let byte = try? handle.read(upToCount: 1) else { return false }
        return byte == Data([UInt8(ascii: "\n")])
    }
}
