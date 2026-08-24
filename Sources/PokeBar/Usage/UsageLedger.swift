import Foundation

/// Accumulates scan results into durable totals.
///
/// Two problems make this necessary rather than incidental:
///
/// 1. **Cursors are persisted, so a scan only ever returns newly-appended
///    lines.** Totals therefore cannot be derived from the latest scan — they
///    have to be carried forward. Without this, all-time usage would reset to
///    zero on every relaunch.
/// 2. **A turn can straddle two scans.** Streaming rewrites the same
///    `(message.id, requestId)` as output grows (~2.4 copies per turn on this
///    corpus). Dedup inside one pass cannot see the partial copy counted by the
///    previous pass, so naive accumulation double-counts. The fix is to remember
///    what was already credited per turn and apply only the growth.
///
/// The ledger also gives per-day history essentially for free. That was
/// deprioritised as a feature, but it is the natural storage shape here, so the
/// data will exist if it is ever wanted.
struct UsageLedger: Sendable, Codable, Equatable {

    /// How long a turn is considered still-growing.
    ///
    /// A turn grows only while its response streams — seconds. Two days is
    /// absurdly generous and keeps the in-flight table small: ~900 entries here
    /// versus ~155,000 if every turn were retained for a year. Once an entry
    /// ages out, its credited tokens live on in `daily`; only the
    /// growth-tracking record is dropped.
    static let growthWindow: TimeInterval = 2 * 24 * 3600

    /// Per-day, per-model totals. The durable record.
    var daily: [String: [String: TokenCounts]] = [:]

    /// Cumulative tier-weighted tokens, frozen at credit time.
    ///
    /// Never recomputed from current pricing. Prices move — the live snapshot
    /// currently reports `claude-sonnet-5` at its introductory rate while the
    /// bundled table holds list, which would shift that tier from 0.6 to 0.4 on
    /// refresh. Recomputing history would take earned currency away from the
    /// player, so credit is applied once, at the rate in effect then.
    var weightedTokens: Double = 0

    /// What has already been credited per turn, for turns young enough to still
    /// grow. Keyed by the dedup identity.
    var inFlight: [String: InFlightEntry] = [:]

    struct InFlightEntry: Sendable, Codable, Equatable {
        var credited: TokenCounts
        var date: Date
        var localDay: String
        var model: String
    }

    /// Credits everything new in `entries` and returns what was actually added.
    ///
    /// Safe to call with entries that have been seen before: a re-scan of
    /// unchanged data credits nothing. That property is what lets the caller
    /// rescan freely on every filesystem tick without reconciling anything.
    @discardableResult
    mutating func credit(
        _ entries: [UsageEntry],
        pricing: ModelPricing,
        now: Date = Date()
    ) -> TokenCounts {
        var added = TokenCounts.zero

        for entry in entries {
            let delta: TokenCounts
            if let seen = inFlight[entry.id] {
                delta = Self.growth(from: seen.credited, to: entry.tokens)
                guard delta.total > 0 else { continue }
            } else {
                delta = entry.tokens
            }

            daily[entry.localDay, default: [:]][
                UsageSource.ledgerKey(model: entry.model, source: entry.source), default: .zero
            ] += delta

            // Pricing lookup stays on the exact, unprefixed model id (invariant
            // 4), never on the ledger key: the Copilot marker exists only to
            // keep two sources' totals from merging under one dictionary key.
            let multiplier = pricing.tierMultiplier(for: entry.model)
                ?? ModelPricing.unknownModelTierMultiplier
            weightedTokens += Double(delta.total) * multiplier

            added += delta
            inFlight[entry.id] = InFlightEntry(
                credited: entry.tokens, date: entry.date,
                localDay: entry.localDay, model: entry.model)
        }

        pruneInFlight(now: now)
        return added
    }

    /// Per-class growth, floored at zero.
    ///
    /// Clamped rather than trusted because only `output` is expected to grow
    /// while `input` and `cacheRead` stay fixed across copies. A negative delta
    /// would mean a later copy reported *fewer* tokens; crediting that would
    /// silently subtract already-earned currency, so it is ignored.
    static func growth(from old: TokenCounts, to new: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(0, new.input - old.input),
            output: max(0, new.output - old.output),
            cacheWrite: max(0, new.cacheWrite - old.cacheWrite),
            cacheRead: max(0, new.cacheRead - old.cacheRead))
    }

    private mutating func pruneInFlight(now: Date) {
        guard !inFlight.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-Self.growthWindow)
        inFlight = inFlight.filter { $0.value.date >= cutoff }
    }

    // MARK: - Queries

    func totals(forDay day: String) -> [String: TokenCounts] { daily[day] ?? [:] }

    func tokens(forDay day: String) -> TokenCounts {
        (daily[day] ?? [:]).values.reduce(into: .zero) { $0 += $1 }
    }

    func allTimeByModel() -> [String: TokenCounts] {
        var out: [String: TokenCounts] = [:]
        for models in daily.values {
            for (model, tokens) in models { out[model, default: .zero] += tokens }
        }
        return out
    }

    /// Visible game currency. Weighted tokens are in the billions, so the
    /// displayed figure is scaled: measured here, 31 days is 3.36B weighted,
    /// which reads as ~33,456 coins lifetime and ~1,079/day.
    static let tokensPerCoin: Double = 100_000

    var coins: Int { Int(weightedTokens / Self.tokensPerCoin) }
}
