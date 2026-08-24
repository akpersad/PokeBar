import Foundation

/// The four non-overlapping token classes Claude Code and Codex report. Kept separate rather than
/// collapsed to a total because they differ in price by up to ~60x
/// (cache read vs output), so a single number cannot be costed.
struct TokenCounts: Sendable, Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0

    static let zero = TokenCounts()

    var total: Int { input + output + cacheWrite + cacheRead }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// Which tool produced a `UsageEntry`.
///
/// Only affects display and ledger *grouping*, never pricing: `entry.model` is
/// always the exact, unprefixed identifier the source wrote, and pricing lookup
/// stays exact-key on that (invariant 4). Claude Code and Codex are shown
/// identically today (bare model name) and stay that way; only Copilot CLI gets
/// a visible tag, so a model both sources have used (e.g. `claude-opus-5`)
/// reads as two rows instead of one merged total.
enum UsageSource: String, Sendable, Equatable, Codable, CaseIterable {
    case claudeCode
    case codex
    case copilotCLI

    /// Marker prepended to `model` when grouping ledger totals, so the same
    /// model from two sources cannot collide in a `[String: TokenCounts]`
    /// dictionary. The colon makes it invalid as a model id, so it cannot
    /// collide the other way either. Declared here and nowhere else: every
    /// reader goes through the three functions below, so the marker's spelling
    /// is one fact in one place.
    static let copilotLedgerPrefix = "copilot:"

    /// The key `UsageLedger` groups totals under. Claude Code and Codex use the
    /// bare model id unchanged, preserving every existing persisted ledger;
    /// only Copilot gets the prefix, since only Copilot needs to be told apart
    /// from a same-named model elsewhere.
    static func ledgerKey(model: String, source: UsageSource) -> String {
        source == .copilotCLI ? copilotLedgerPrefix + model : model
    }

    /// The real model id inside a ledger key, for a pricing lookup: invariant 4
    /// requires the exact, unprefixed key, so every call site that starts from a
    /// ledger key must come through here first.
    ///
    /// Deliberately *not* a full inverse returning a `UsageSource`. Claude Code
    /// and Codex keys are identical by design, so any such inverse would have to
    /// invent one of the two, and an invented value is exactly the kind of thing
    /// a later reader trusts.
    static func model(fromLedgerKey key: String) -> String {
        isCopilotLedgerKey(key)
            ? String(key.dropFirst(copilotLedgerPrefix.count))
            : key
    }

    /// Whether a ledger key was credited from Copilot CLI. The only source
    /// distinction a ledger key can answer, and the only one anything needs.
    static func isCopilotLedgerKey(_ key: String) -> Bool {
        key.hasPrefix(copilotLedgerPrefix)
    }
}

/// One assistant turn's usage, parsed from a Claude Code line, a Codex line, or
/// a Copilot CLI usage row.
struct UsageEntry: Sendable, Equatable, Identifiable, Codable {
    /// Stable across rescans so re-reading a file cannot double-count.
    /// Claude Code writes a `requestId` per turn; where absent we fall back to
    /// "<sessionId>|<line offset>", which is equally stable for an append-only log.
    let id: String
    let date: Date
    /// Raw model identifier exactly as the source wrote it, unnormalized.
    /// Normalization belongs to pricing, not to parsing.
    let model: String
    let source: UsageSource
    let tokens: TokenCounts
    /// Local calendar day key ("2026-08-22") for day bucketing. Stored rather
    /// than derived so a timezone change cannot silently reshuffle history.
    let localDay: String
}

/// Aggregate over a set of entries. Deliberately holds no formatting.
struct UsageTotals: Sendable, Equatable {
    var tokens: TokenCounts = .zero
    var costUSD: Double = 0
    var byModel: [String: TokenCounts] = [:]

    /// True when at least one contributing model had no known price, so the
    /// cost shown is a floor rather than the real figure. The upstream project
    /// silently reported $0.00 for unpriced models, which is how a brand new
    /// model reads as free instead of as unknown.
    var hasUnpricedModels: Bool = false
}
