import XCTest
@testable import PokeBar

/// The random half of a hatch.
///
/// Distribution tests over a seeded generator, because the alternative is
/// asserting that a function calls `random` and learning nothing.
final class HatchRollTests: XCTestCase {

    private var dex: Pokedex!

    override func setUpWithError() throws {
        dex = try Pokedex.loadBundled()
    }

    /// Weighted on the capture rate, not on the band. The pool spans 3 to 255, so
    /// a common entry must come up far more often than a legendary, and a uniform
    /// draw would make the rarity signal meaningless.
    func testDrawIsWeightedOnCaptureRate() {
        var rng = SeededGenerator(seed: 1)
        let pool = dex.hatchable
        var counts: [Rarity: Int] = [:]
        for _ in 0..<20_000 {
            let entry = HatchRoll.draw(from: pool, using: &rng)!
            counts[entry.rarity, default: 0] += 1
        }
        // Measured shares of the hatch pool's total weight, re-measured
        // 2026-08-27 under `HatchRoll.legendaryWeightCap`: common 74.3%,
        // legendary 0.8%, mythical 0.3%. Legendaries were 1.7% before the cap,
        // which the old accuracy of 0.01 was loose enough to cover either way, so
        // the figures are tightened here rather than left ambiguous.
        let share = { (rarity: Rarity) in Double(counts[rarity] ?? 0) / 20_000 }
        XCTAssertEqual(share(.common), 0.743, accuracy: 0.02, "\(counts)")
        XCTAssertEqual(share(.legendary), 0.0076, accuracy: 0.004, "\(counts)")
        XCTAssertEqual(share(.mythical), 0.0032, accuracy: 0.003, "\(counts)")

        // The draw follows weight, not headcount: 234 hatchable entries are
        // common against 140 rare, but commons take three quarters of the draws
        // rather than the 41% their count would give.
        XCTAssertGreaterThan(share(.common), 0.6)
        XCTAssertEqual(pool.filter { $0.rarity == .common }.count, 234)
    }

    func testDrawOnlyEverReturnsHatchableEntries() {
        var rng = SeededGenerator(seed: 2)
        let hatchable = Set(dex.hatchable.map(\.id))
        for _ in 0..<2_000 {
            let entry = HatchRoll.draw(from: dex.hatchable, using: &rng)!
            XCTAssertTrue(hatchable.contains(entry.id), entry.slug)
            XCTAssertFalse(dex.isEvolutionGated(entry), entry.slug)
        }
    }

    func testDrawFromAnEmptyPoolIsNil() {
        var rng = SeededGenerator(seed: 3)
        XCTAssertNil(HatchRoll.draw(from: [], using: &rng))
    }

    /// A female Magnemite is a bug a coin flip produces one time in two, which is
    /// why the roll reads the species' own gender rate.
    func testGenderRespectsTheSpeciesRate() throws {
        var rng = SeededGenerator(seed: 4)
        let magnemite = try XCTUnwrap(dex.entry(slug: "magnemite"))
        let tauros = try XCTUnwrap(dex.entry(slug: "tauros"))        // male only
        let chansey = try XCTUnwrap(dex.entry(slug: "chansey"))      // female only
        let bulbasaur = try XCTUnwrap(dex.entry(slug: "bulbasaur"))  // 7/8 male

        for _ in 0..<500 {
            XCTAssertEqual(HatchRoll.gender(for: magnemite, using: &rng), .genderless)
            XCTAssertEqual(HatchRoll.gender(for: tauros, using: &rng), .male)
            XCTAssertEqual(HatchRoll.gender(for: chansey, using: &rng), .female)
        }

        var females = 0
        for _ in 0..<4_000 where HatchRoll.gender(for: bulbasaur, using: &rng) == .female {
            females += 1
        }
        XCTAssertEqual(Double(females) / 4_000, 0.125, accuracy: 0.02)
    }

    /// Oinkologne is the one species where PokeAPI's gender rate and the sprite
    /// files disagree, because the female is modelled as a separate variety. The
    /// sprite wins, repaired at generation time, so the roll must be able to
    /// produce the sex that sprite is for.
    func testOinkologneCanRollFemale() throws {
        var rng = SeededGenerator(seed: 5)
        let oinkologne = try XCTUnwrap(dex.entry(slug: "oinkologne"))
        XCTAssertTrue(oinkologne.female)
        XCTAssertEqual(Set(oinkologne.possibleGenders), [.male, .female])
        var sexes: Set<Gender> = []
        for _ in 0..<200 { sexes.insert(HatchRoll.gender(for: oinkologne, using: &rng)) }
        XCTAssertEqual(sexes, [.male, .female])
    }

    /// The shiny rate is a promise about how often a hatch is special. Measured
    /// over 64,000 draws so a broken constant shows up as a rate, not as luck.
    func testShinyOddsAreOneIn64AndOneIn48WithTheCharm() {
        var rng = SeededGenerator(seed: 6)
        var plain = 0, charmed = 0
        let trials = 64_000
        for _ in 0..<trials {
            if HatchRoll.isShiny(charm: false, using: &rng) { plain += 1 }
            if HatchRoll.isShiny(charm: true, using: &rng) { charmed += 1 }
        }
        XCTAssertEqual(Double(plain) / Double(trials), 1.0 / 64, accuracy: 0.002)
        XCTAssertEqual(Double(charmed) / Double(trials), 1.0 / 48, accuracy: 0.002)
        XCTAssertGreaterThan(charmed, plain)
    }

    /// A purchase is not a roll: it must land on the sprite the plain slot uses,
    /// or the entry stays incomplete after being bought.
    func testCanonicalGenderPicksThePlainSlot() throws {
        XCTAssertEqual(
            HatchRoll.canonicalGender(for: try XCTUnwrap(dex.entry(slug: "bulbasaur"))), .male)
        XCTAssertEqual(
            HatchRoll.canonicalGender(for: try XCTUnwrap(dex.entry(slug: "magnemite"))),
            .genderless)
        XCTAssertEqual(
            HatchRoll.canonicalGender(for: try XCTUnwrap(dex.entry(slug: "chansey"))), .female)
    }

    /// **No legendary or mythical entry outweighs an ordinary legendary.**
    ///
    /// Three entries hold the game's maximum capture rate of 255 while being
    /// legendary: Necrozma, Eternatus and Terapagos, each a scripted guaranteed
    /// story catch in its most recent appearance. The manifest is correct, and
    /// PokeAPI, its source CSV and PokemonDB all agree. Uncapped they were the
    /// three heaviest entries in every pool, which is invisible in the 570 entry
    /// pool and dominant once a tier narrows it: 18.5% each of an Ultra Egg, so
    /// 55.5% of a guaranteed legendary was one of three species. The user hit it
    /// on screen, hatching two Terapagos in 14 hatches.
    ///
    /// This is the test that makes the cap non-silent. Removing it puts three
    /// species back at 3.2x the weight of the next-heaviest entry in the pool.
    func testNoLegendaryOutweighsAnOrdinaryLegendary() {
        let anomalies = ["necrozma", "eternatus", "terapagos"]

        for entry in dex.hatchable where entry.rarity == .legendary || entry.rarity == .mythical {
            XCTAssertLessThanOrEqual(
                HatchRoll.weight(for: entry), HatchRoll.legendaryWeightCap, entry.slug)
        }

        // Exactly three entries are changed by it, and they are the known three.
        // Asserted by name so that a manifest regeneration adding a fourth fails
        // here and gets looked at, rather than being absorbed silently.
        let changed = dex.hatchable
            .filter { HatchRoll.weight(for: $0) != max($0.captureRate, 1) }
            .map(\.slug)
            .sorted()
        XCTAssertEqual(changed, anomalies.sorted(), "the capped set moved")

        // The cap is scoped to the top two bands. A common at 255 is a Caterpie
        // and must still be the heaviest thing in the plain Egg's pool.
        let caterpie = dex.hatchable.first { $0.slug == "caterpie" }!
        XCTAssertEqual(caterpie.captureRate, 255)
        XCTAssertEqual(HatchRoll.weight(for: caterpie), 255, "the cap escaped its bands")
    }

    /// **The cap is on the weight, never on the payout.** Dust pays on the raw
    /// capture rate per invariant 17, so a Terapagos duplicate is still worth the
    /// floor of 1 Dust. Capping the payout too would lift the Great Egg's expected
    /// Dust, which invariant 42 pins against the plain Egg.
    func testTheWeightCapDoesNotChangeWhatADuplicatePays() {
        let terapagos = dex.hatchable.first { $0.slug == "terapagos" }!
        XCTAssertEqual(terapagos.captureRate, 255, "PokeAPI's current value")
        XCTAssertEqual(HatchRoll.weight(for: terapagos), 45, "capped for the roll")
        XCTAssertEqual(
            Prices.dust(forCaptureRate: terapagos.captureRate), 1,
            "paid on the raw rate, so still the floor")
    }

    /// The Ultra Egg is the tier the cap was for: 3,500 coins for a guaranteed
    /// legendary, and **55.5% of its draws used to be one of three species**.
    ///
    /// Measures the three named species rather than "the three most sampled",
    /// which is what the first version did and it read 18.75% against an expected
    /// 18.1%. That gap is not a weighting error: ten entries sit tied at the cap,
    /// so picking the top three *observed* counts selects on sampling noise and
    /// biases high. Naming the species up front is unbiased and is also the claim
    /// worth defending.
    func testTheUltraEggIsNoLongerThreeSpecies() {
        var rng = SeededGenerator(seed: 11)
        let pool = dex.hatchPool(for: .ultra)
        let anomalies = Set(
            pool.filter { ["necrozma", "eternatus", "terapagos"].contains($0.slug) }.map(\.id))
        XCTAssertEqual(anomalies.count, 3, "all three must be in the Ultra pool")

        var hits = 0
        for _ in 0..<20_000 where anomalies.contains(HatchRoll.draw(from: pool, using: &rng)!.id) {
            hits += 1
        }
        let share = Double(hits) / 20_000
        // 55.5% before the cap (18.5% each), 18.1% after (6.02% each), which is
        // now the same weight as Mew, Celebi and Rayquaza.
        XCTAssertEqual(share, 0.181, accuracy: 0.02, "the three take \(share)")
        XCTAssertLessThan(share, 0.30, "an Ultra Egg is three species again")
    }
}
