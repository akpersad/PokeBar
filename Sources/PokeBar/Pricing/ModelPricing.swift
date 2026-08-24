import Foundation

/// Per-token USD rates for one model.
///
/// All four classes are stored explicitly because ratios vary by provider and
/// model and can change independently.
struct ModelRate: Sendable, Equatable, Codable {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    /// Declared per **million** tokens for readability, stored per token.
    static func perMillion(
        input: Double, output: Double, cacheWrite: Double, cacheRead: Double
    ) -> ModelRate {
        ModelRate(
            input: input / 1_000_000,
            output: output / 1_000_000,
            cacheWrite: cacheWrite / 1_000_000,
            cacheRead: cacheRead / 1_000_000)
    }

    func costUSD(for tokens: TokenCounts) -> Double {
        Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheWrite) * cacheWrite
            + Double(tokens.cacheRead) * cacheRead
    }
}

/// Model rate lookup, with a bundled snapshot and an optional runtime refresh.
///
/// Two consumers, and they are different jobs:
///
/// 1. **Currency weighting.** Raw token count times a per-model tier multiplier
///    derived from `input`. This is load-bearing: it decides what a token is
///    worth in the game.
/// 2. **The optional dollar readout.** Informational only. On a subscription the
///    figure is what the usage *would* have cost on the API, not money spent.
///
/// The upstream project hand-maintained its table and shipped a commit per model
/// launch. Measured against this machine's corpus, that table had no entry for
/// `claude-opus-5` or `claude-sonnet-5`, covering 342,492,125 tokens — 18.5% of
/// total volume — silently priced at $0.00. Hence: unknown models resolve to
/// `nil`, never to a zero rate.
struct ModelPricing: Sendable {

    /// Rates verified 2026-08-22 against both the Anthropic pricing reference
    /// and the LiteLLM snapshot; the two agreed exactly.
    ///
    /// Note on `claude-sonnet-5`: list price is $3/$15, but an introductory
    /// $2/$10 runs through 2026-08-31. The bundled entry carries **list**, not
    /// intro, so the tier multiplier does not silently shift when the promo
    /// lapses. A runtime refresh will pick up whichever is current.
    static let bundled: [String: ModelRate] = [
        "claude-fable-5":   .perMillion(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1.0),
        "claude-mythos-5":  .perMillion(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1.0),
        "claude-opus-5":    .perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
        "claude-opus-4-8":  .perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
        "claude-opus-4-7":  .perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
        "claude-opus-4-6":  .perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
        "claude-sonnet-5":  .perMillion(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
        "claude-sonnet-4-6": .perMillion(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
        "claude-haiku-4-5": .perMillion(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
        "claude-haiku-4-5-20251001":
            .perMillion(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
        // OpenAI API pricing, verified 2026-08-23. Codex rollout input is
        // decomposed into these non-overlapping classes before costing.
        "gpt-5.6-sol":    .perMillion(input: 2.5, output: 15, cacheWrite: 3.125, cacheRead: 0.25),
        "gpt-5.6-terra":  .perMillion(input: 1.25, output: 7.5, cacheWrite: 1.5625, cacheRead: 0.125),
        "gpt-5.6-luna":   .perMillion(input: 0.5, output: 3, cacheWrite: 0.625, cacheRead: 0.05),
    ]

    /// The model whose input rate defines a tier multiplier of exactly 1.0.
    /// Opus rather than the cheapest model so multipliers land near 1 for the
    /// models actually in use (fable 2.0, opus 1.0, sonnet 0.6, haiku 0.2).
    static let tierBaselineModel = "claude-opus-5"

    private let table: [String: ModelRate]

    init(table: [String: ModelRate] = ModelPricing.bundled) {
        self.table = table
    }

    /// Exact-key lookup only.
    ///
    /// Deliberately not fuzzy. The upstream pricing source carries ten prefixed
    /// variants of `claude-opus-5` alone — `au.anthropic.claude-opus-5` at
    /// $5.50, plus `azure_ai/`, `vertex_ai/`, `openrouter/`, and regional `us.`
    /// / `eu.` / `jp.` forms — so any substring match would silently pick up a
    /// marked-up regional rate. Claude Code writes the bare id.
    func rate(for model: String) -> ModelRate? { table[model] }

    /// Currency weight for a model: its input rate relative to the baseline.
    /// `nil` for an unknown model, so callers must decide explicitly rather
    /// than inheriting a wrong-but-plausible number.
    func tierMultiplier(for model: String) -> Double? {
        guard let rate = table[model],
              let baseline = table[Self.tierBaselineModel],
              baseline.input > 0
        else { return nil }
        return rate.input / baseline.input
    }

    /// Weight assumed for a model absent from the table — a model newer than
    /// both the bundled snapshot and the last successful refresh.
    ///
    /// Baseline rather than zero: a brand new model should not silently earn
    /// nothing. Callers surface the substitution via `UsageTotals`.
    static let unknownModelTierMultiplier: Double = 1.0

    /// Aggregate entries into totals, tier-weighted currency, and cost.
    func totals(for entries: [UsageEntry]) -> (totals: UsageTotals, weightedTokens: Double) {
        var out = UsageTotals()
        var weighted = 0.0
        for entry in entries {
            out.tokens += entry.tokens
            out.byModel[entry.model, default: .zero] += entry.tokens

            if let rate = rate(for: entry.model) {
                out.costUSD += rate.costUSD(for: entry.tokens)
            } else {
                out.hasUnpricedModels = true
            }
            let multiplier = tierMultiplier(for: entry.model)
                ?? Self.unknownModelTierMultiplier
            weighted += Double(entry.tokens.total) * multiplier
        }
        return (out, weighted)
    }
}
