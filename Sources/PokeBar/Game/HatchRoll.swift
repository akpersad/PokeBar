import Foundation

/// The random parts of a hatch: which species, whether it is shiny, and its sex.
///
/// Split out from `Trainer` so every roll can be driven by a seeded generator in
/// tests. Nothing here reads the clock or a global RNG.
enum HatchRoll {

    /// The most weight a legendary or mythical entry may carry in a hatch roll.
    ///
    /// **Three legendaries hold the game's maximum capture rate of 255**, because
    /// each is a scripted, effectively guaranteed story catch in its most recent
    /// appearance: Necrozma (rebalanced from 3 in Sun/Moon to 255 in Ultra
    /// Sun/Moon and Sword/Shield), Eternatus and Terapagos. The manifest is right
    /// and all three sources agree; PokeAPI, its own source CSV and PokemonDB all
    /// say 255, and Bulbapedia's infobox showing Necrozma at 3 is its debut
    /// generation, contradicted by that same page's trivia.
    ///
    /// Uncapped, that data makes the three *heaviest* draws in every pool
    /// legendary, which only shows up once a pool is narrowed: 2.8% each of a
    /// Great Egg against the next-heaviest entry's 0.87%, and **18.5% each of an
    /// Ultra Egg, so 55.5% of a 3,500 coin guaranteed legendary was one of three
    /// species**. It also inverts the Dust payout, since Dust is `255 /
    /// captureRate` and so these three pay the floor of 1: the most likely
    /// legendary duplicate was worth the same as a Caterpie, which is the reading
    /// that surfaced this on screen.
    ///
    /// 45 is where the other legendaries cluster (7 of the 91 hatchable ones sit
    /// there exactly), so the cap reads as "no legendary outweighs the ordinary
    /// legendaries" rather than as a tuned constant. It **changes exactly three
    /// entries**, the three at 255, and leaves the other 88 weighting on their own
    /// number. A lower cap is not free: at 30 it also pulls the seven down, and
    /// the resulting shift broke invariant 42 as well as 41.
    ///
    /// **The cap is on the weight only. Dust still pays on the raw rate**, per
    /// invariant 17: the weight decides how often a thing appears, the raw rate is
    /// what the thing is worth, and conflating them is what invariant 42 already
    /// guards one layer up.
    static let legendaryWeightCap = 45

    /// The weight one entry carries in a hatch roll.
    ///
    /// Exposed rather than inlined into `draw` because the egg ladder's two
    /// pricing invariants are asserted against this distribution, and a test that
    /// recomputed the weights would be free to disagree with the roll. One source
    /// of truth, so a change here fails there.
    static func weight(for entry: DexEntry) -> Int {
        let raw = max(entry.captureRate, 1)
        switch entry.rarity {
        case .legendary, .mythical: return min(raw, legendaryWeightCap)
        default: return raw
        }
    }

    /// Draws one entry, weighted on `captureRate`, capped for the top two bands.
    ///
    /// **Weighted on the raw number, never on `Rarity`.** `capture_rate` is
    /// quantized hard (327 of 1,083 entries share the value 45, and 86% sit at 45
    /// or above), so every band scheme puts a 30-45% lump in one band; three were
    /// evaluated and all three did. The bands are a display label, the raw number
    /// behaves like a smooth weight. See DECISIONS.md.
    ///
    /// The one exception to "raw" is `legendaryWeightCap`, which is a ceiling on
    /// three entries whose capture rate contradicts their rarity, not a banding
    /// scheme: every other entry still weights on its own number.
    ///
    /// Returns nil only for an empty pool, which cannot happen with the real dex
    /// and is not worth throwing over.
    static func draw(
        from pool: [DexEntry], using rng: inout some RandomNumberGenerator
    ) -> DexEntry? {
        guard !pool.isEmpty else { return nil }
        let total = pool.reduce(0) { $0 + weight(for: $1) }
        var roll = Int.random(in: 0..<total, using: &rng)
        for entry in pool {
            roll -= weight(for: entry)
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
