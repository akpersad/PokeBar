import Foundation

/// Parses Codex rollout JSONL from `~/.codex/sessions/YYYY/MM/DD`.
///
/// Codex emits one `token_count` event after each response. `input_tokens`
/// includes both cached reads and cache writes, while PokeBar's `TokenCounts`
/// classes are non-overlapping, so ordinary input is the remainder after both
/// cache classes are removed. `reasoning_output_tokens` is already included in
/// `output_tokens` and must not be added again.
enum CodexUsageParser {

    /// Consumes one rollout line, updating the model carried by `turn_context`
    /// records and returning an entry only for response usage records.
    ///
    /// `sessionKey` is the rollout's file name, which carries the session UUID
    /// (`rollout-2026-08-23T23-24-29-01a031cc-...jsonl`). Together with the
    /// record's `ordinal` it forms an id that is a function of the *content*,
    /// not of where the scan happened to start reading. See `stableID`.
    static func consume(
        line: String,
        sessionKey: String,
        fallbackID: @autoclosure () -> String,
        currentModel: inout String?,
        currentProject: inout String?
    ) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        // The project comes off `turn_context`, the same record the model does.
        // Unlike the Claude path there is nothing on the `token_count` event
        // itself, so it has to be carried forward, which is the pattern
        // `currentModel` already established. `session_meta` carries it too and
        // arrives first, but never reaches here: the scanner's prefilter only
        // hands over lines containing `turn_context` or `token_count`. That
        // costs nothing, because a `token_count` is always preceded by the
        // `turn_context` for its turn, which is the same assumption the model
        // has depended on since Codex support shipped.
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
            currentProject = cwd
        }
        if object["type"] as? String == "turn_context",
           let model = payload["model"] as? String,
           !model.isEmpty {
            currentModel = model
            return nil
        }

        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let date = ClaudeUsageParser.parseTimestamp(object["timestamp"])
        else { return nil }

        let allInput = int(usage["input_tokens"])
        let cacheRead = int(usage["cached_input_tokens"])
        let cacheWrite = int(usage["cache_write_input_tokens"])
        let tokens = TokenCounts(
            input: max(0, allInput - cacheRead - cacheWrite),
            output: int(usage["output_tokens"]),
            cacheWrite: cacheWrite,
            cacheRead: cacheRead)
        guard tokens.total > 0 else { return nil }

        return UsageEntry(
            id: stableID(object, sessionKey: sessionKey) ?? fallbackID(),
            date: date,
            model: currentModel ?? "unknown-codex-model",
            source: .codex,
            tokens: tokens,
            localDay: ClaudeUsageParser.localDayKey(date),
            project: currentProject)
    }

    /// An id derived from the record, not from its byte offset.
    ///
    /// This matters more here than on the Claude path. A Claude turn carries a
    /// `requestId`, so re-reading a file from a different offset reproduces the
    /// same id and the ledger's keep-max dedup absorbs it. A Codex record has no
    /// such field, and the positional fallback embeds the offset the scan began
    /// at, so the same event read once incrementally and once from zero would
    /// arrive under two ids and be credited twice. Coins are frozen at credit
    /// time, so that inflation would be permanent.
    ///
    /// `ordinal` is a per-record counter within a rollout, verified unique
    /// across every record of every rollout on this machine, so
    /// `session + ordinal` identifies the event even if the tree is moved or a
    /// resumed session replays it into a second file. Falls back to the
    /// positional id if a future Codex build stops writing it.
    private static func stableID(_ object: [String: Any], sessionKey: String) -> String? {
        guard let ordinal = object["ordinal"] as? Int else { return nil }
        return "codex|\(sessionKey)#\(ordinal)"
    }

    /// Tolerates the numeric representations JSONSerialization can produce.
    private static func int(_ raw: Any?) -> Int {
        switch raw {
        case let value as Int: return max(0, value)
        case let value as Double: return max(0, Int(value))
        case let value as String: return max(0, Int(value) ?? 0)
        default: return 0
        }
    }
}
