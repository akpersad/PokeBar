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
    static func consume(
        line: String,
        fallbackID: @autoclosure () -> String,
        currentModel: inout String?
    ) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }

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
            id: fallbackID(),
            date: date,
            model: currentModel ?? "unknown-codex-model",
            tokens: tokens,
            localDay: ClaudeUsageParser.localDayKey(date))
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
