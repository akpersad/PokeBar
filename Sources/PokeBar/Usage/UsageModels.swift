import Foundation

/// The four token classes Claude Code reports. Kept separate rather than
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

/// One assistant turn's usage, parsed from a line of
/// `~/.claude/projects/**/*.jsonl`.
struct UsageEntry: Sendable, Equatable, Identifiable, Codable {
    /// Stable across rescans so re-reading a file cannot double-count.
    /// Claude Code writes a `requestId` per turn; where absent we fall back to
    /// "<sessionId>|<line offset>", which is equally stable for an append-only log.
    let id: String
    let date: Date
    /// Raw model identifier exactly as Claude Code wrote it, unnormalized.
    /// Normalization belongs to pricing, not to parsing.
    let model: String
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
