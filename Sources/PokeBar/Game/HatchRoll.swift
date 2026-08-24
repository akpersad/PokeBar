import Foundation

/// The random parts of a hatch: which species, whether it is shiny, and its sex.
///
/// Split out from `Trainer` so every roll can be driven by a seeded generator in
/// tests. Nothing here reads the clock or a global RNG.
enum HatchRoll {

    /// Draws one entry, weighted on the raw `captureRate`.
    ///
    /// **Weighted on the raw number, never on `Rarity`.** `capture_rate` is
    /// quantized hard (327 of 1,083 entries share the value 45, and 86% sit at 45
    /// or above), so every band scheme puts a 30-45% lump in one band; three were
    /// evaluated and all three did. The bands are a display label, the raw number
    /// behaves like a smooth weight. See DECISIONS.md.
    ///
    /// Returns nil only for an empty pool, which cannot happen with the real dex
    /// and is not worth throwing over.
    static func draw(
        from pool: [DexEntry], using rng: inout some RandomNumberGenerator
    ) -> DexEntry? {
        guard !pool.isEmpty else { return nil }
        let total = pool.reduce(0) { $0 + max($1.captureRate, 1) }
        var roll = Int.random(in: 0..<total, using: &rng)
        for entry in pool {
            roll -= max(entry.captureRate, 1)
            if roll < 0 { return entry }
        }
        // Unreachable: the weights sum to `total` by construction. Returning the
        // last entry rather than crashing, because a hatch failing outright is a
        // worse outcome than an off-by-one in the tail.
        return pool.last
    }

    /// 1/64, or 1/48 holding the Shiny Charm.
    ///
    /// The mainline 1/4096 would mean never seeing a shiny in a desktop app's
    /// lifetime. Upstream says so explicitly and picked these; the reasoning
    /// holds here.
    static func isShiny(charm: Bool, using rng: inout some RandomNumberGenerator) -> Bool {
        let odds = charm ? Prices.shinyOddsWithCharm : Prices.shinyOdds
        return Int.random(in: 0..<odds, using: &rng) == 0
    }

    /// Sex, from the species' own `gender_rate` in eighths female.
    ///
    /// Rolled from the data rather than a coin flip, because 218 of 1,083 entries
    /// are not 50/50: 155 are genderless, 26 male-only and 37 female-only, and a
    /// female Magnemite is a bug a coin flip produces one time in two.
    static func gender(for entry: DexEntry, using rng: inout some RandomNumberGenerator) -> Gender {
        switch entry.genderRate {
        case ..<0: .genderless
        case 0: .male
        case 8...: .female
        case let rate: Int.random(in: 0..<8, using: &rng) < rate ? .female : .male
        }
    }

    /// The sex a *guaranteed* acquisition arrives as: the one whose sprite is the
    /// entry's plain slot. A targeted pick is a purchase, not a roll, so it must
    /// not land on the female slot and leave the plain one still empty.
    static func canonicalGender(for entry: DexEntry) -> Gender {
        switch entry.genderRate {
        case ..<0: .genderless
        case 8...: .female
        default: .male
        }
    }
}
