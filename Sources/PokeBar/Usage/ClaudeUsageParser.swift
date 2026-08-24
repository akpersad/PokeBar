import Foundation

/// Parses `~/.claude/projects/**/*.jsonl` into `UsageEntry` values.
///
/// Shape, verified against 1,029 files / 60,433 lines on this machine:
/// usage lives on `type == "assistant"` lines at `message.usage`, carrying
/// `input_tokens`, `output_tokens`, `cache_creation_input_tokens` and
/// `cache_read_input_tokens`, with `message.model` and a top-level `timestamp`.
///
/// `JSONSerialization` rather than `Codable` on purpose: these files interleave
/// at least ten unrelated line types (`user`, `attachment`, `mode`,
/// `file-history-snapshot`, `queue-operation`, ...) and a strict decoder spends
/// its time throwing on lines we do not want.
enum ClaudeUsageParser {

    /// Claude Code writes this model name for locally generated placeholder
    /// messages (interrupts and similar) rather than real API turns. Measured
    /// at 19 lines / 0 tokens here, so skipping them changes no total; it only
    /// keeps a bogus "<synthetic>" row out of the per-model breakdown.
    static let syntheticModel = "<synthetic>"

    // Sendable value types, so these are safe as statics under Swift 6.
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoWhole = Date.ISO8601FormatStyle()

    /// - Parameter fallbackID: identity to use when the line carries neither
    ///   `message.id` nor `requestId`. Must be unique per line, e.g.
    ///   "<file path>#<byte offset>". Upstream used `"|"` for this case, which
    ///   collapses every id-less line in the corpus into a single entry.
    static func entry(fromLine line: String, fallbackID: @autoclosure () -> String) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = message["model"] as? String ?? "unknown"
        guard model != syntheticModel else { return nil }

        let tokens = TokenCounts(
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheWrite: int(usage["cache_creation_input_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]))
        // A turn with no tokens in any class is not usage.
        guard tokens.total > 0 else { return nil }

        guard let date = parseTimestamp(object["timestamp"]) else { return nil }

        let messageID = message["id"] as? String
        let requestID = object["requestId"] as? String
        let id: String
        if messageID == nil && requestID == nil {
            id = fallbackID()
        } else {
            id = (messageID ?? "") + "|" + (requestID ?? "")
        }

        return UsageEntry(
            id: id,
            date: date,
            model: model,
            source: .claudeCode,
            tokens: tokens,
            localDay: localDayKey(date))
    }

    /// Collapse repeats of the same turn, keeping the **largest** total.
    ///
    /// This is the single most important correctness rule in the parser, and it
    /// is not obvious. Streaming and session resume log the same
    /// `(message.id, requestId)` many times; `input` and `cacheRead` are fixed
    /// across those copies but `output` grows as the response completes.
    /// Measured on this machine's corpus:
    ///
    /// - no dedup at all  -> 4.10B tokens, a **2.22x over-count**
    /// - keep first copy  -> 1.845B tokens, **under-counts output by 26.5%**
    /// - keep max total   -> 1.848B tokens, correct
    ///
    /// Both naive strategies are badly wrong, in opposite directions.
    static func dedupKeepMax(_ entries: [UsageEntry]) -> [UsageEntry] {
        var best: [String: UsageEntry] = [:]
        best.reserveCapacity(entries.count)
        for entry in entries {
            if let existing = best[entry.id], existing.tokens.total >= entry.tokens.total { continue }
            best[entry.id] = entry
        }
        return Array(best.values)
    }

    /// Local-calendar day key, "2026-08-22".
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` because this
    /// runs once per parsed turn (13k+ per full scan) and because formatters are
    /// reference types that would need synchronising under Swift 6 concurrency.
    static func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Helpers

    /// Every timestamp in this corpus is `2026-08-22T14:20:59.123Z`, but the
    /// whole-second fallback costs nothing and avoids silently dropping turns
    /// if Claude Code ever omits the fractional part.
    static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        if let date = try? isoFractional.parse(string) { return date }
        return try? isoWhole.parse(string)
    }

    /// Tolerates the number arriving as Int, Double, or a numeric string.
    private static func int(_ raw: Any?) -> Int {
        switch raw {
        case let value as Int: return max(0, value)
        case let value as Double: return max(0, Int(value))
        case let value as String: return max(0, Int(value) ?? 0)
        default: return 0
        }
    }
}
