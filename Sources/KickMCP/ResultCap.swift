/// The one cap every tool result passes (plan decision 5). A result lands in the model's
/// context, so it stays compact (CLAUDE.md rule 6), and what doesn't fit is named, never inlined.
enum ResultCap {
    /// The most UTF-8 bytes of text in one tool result: 4 KB.
    static let maximumBytes = 4 * 1024

    /// The reply as text: its lines, then its next step. Over the cap, whole lines are kept
    /// while they fit, then a note says how many were left out and where the rest is. The next
    /// step is always kept. A single line longer than the cap is cut within.
    static func apply(_ reply: ToolReply) -> String {
        let next = reply.next.map { [$0] } ?? []
        let whole = (reply.lines + next).joined(separator: "\n")
        guard whole.utf8.count > maximumBytes else { return whole }
        // The longest note this reply could need bounds the room the lines leave for it.
        let longestNote = max(note(leftOut: reply.lines.count, rest: reply.rest).utf8.count, note(leftOut: 0, rest: reply.rest).utf8.count)
        let reserved = longestNote + next.reduce(0) { $0 + $1.utf8.count + 1 } + 1
        let budget = max(maximumBytes - reserved, 0)
        var kept: [String] = []
        var used = 0
        for line in reply.lines {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else {
                if kept.isEmpty { kept.append(prefix(of: line, maximumBytes: budget)) }
                break
            }
            kept.append(line)
            used += cost
        }
        return (kept + [note(leftOut: reply.lines.count - kept.count, rest: reply.rest)] + next).joined(separator: "\n")
    }

    /// `… 37 more lines left out at the 4 KB result cap; the rest: …`, or, when only one line was
    /// cut within, that it was.
    static func note(leftOut: Int, rest: String) -> String {
        let cut = switch leftOut {
        case 0: "the line above was cut"
        case 1: "1 more line left out"
        default: "\(leftOut) more lines left out"
        }
        return "… \(cut) at the \(maximumBytes / 1024) KB result cap; the rest: \(rest)"
    }

    /// The longest prefix of `line` that ends on a character boundary and, with an ellipsis,
    /// fits in `maximumBytes`.
    static func prefix(of line: String, maximumBytes: Int) -> String {
        let ellipsis = "…"
        var prefix = ""
        var used = ellipsis.utf8.count
        for character in line {
            used += character.utf8.count
            guard used <= maximumBytes else { break }
            prefix.append(character)
        }
        return prefix + ellipsis
    }
}
