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

    /// Weighted on the raw capture rate, not on the band. The pool spans 3 to
    /// 255, so a common entry must come up far more often than a legendary, and
    /// a uniform draw would make the rarity signal meaningless.
    func testDrawIsWeightedOnCaptureRate() {
        var rng = SeededGenerator(seed: 1)
        let pool = dex.hatchable
        var counts: [Rarity: Int] = [:]
        for _ in 0..<20_000 {
            let entry = HatchRoll.draw(from: pool, using: &rng)!
            counts[entry.rarity, default: 0] += 1
        }
        // Measured shares of the hatch pool's total weight: common 73.6%,
        // legendary 1.7%, mythical 0.3%.
        let share = { (rarity: Rarity) in Double(counts[rarity] ?? 0) / 20_000 }
        XCTAssertEqual(share(.common), 0.736, accuracy: 0.02, "\(counts)")
        XCTAssertEqual(share(.legendary), 0.017, accuracy: 0.01, "\(counts)")
        XCTAssertEqual(share(.mythical), 0.003, accuracy: 0.01, "\(counts)")

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
}
