import XCTest
@testable import PokeBar

/// A seeded generator, so every roll in these tests is reproducible.
///
/// SplitMix64. Small enough to read, good enough that a distribution test over
/// 20,000 draws means something.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The game loop, end to end, without a running app.
///
/// `Trainer` takes its clock and its randomness as parameters precisely so this
/// can exist: every rule that decides what the player owns is exercised here
/// rather than inferred from a view.
final class TrainerTests: XCTestCase {

    private var dex: Pokedex!
    private var rng = SeededGenerator(seed: 20_260_823)

    override func setUpWithError() throws {
        dex = try Pokedex.loadBundled()
        rng = SeededGenerator(seed: 20_260_823)
    }

    private func entry(_ slug: String) throws -> DexEntry {
        try XCTUnwrap(dex.entry(slug: slug), slug)
    }

    /// Starts a trainer already raising `slug`, without going through a hatch.
    private func raising(_ slug: String, shiny: Bool = false) throws -> Trainer {
        let entry = try self.entry(slug)
        var trainer = Trainer()
        let gender = HatchRoll.canonicalGender(for: entry)
        trainer.log.append(CatchEvent(
            entryID: entry.id, variant: gender.spriteVariant(shiny: shiny, for: entry),
            gender: gender, source: .hatch))
        trainer.active = Raise(entryID: entry.id, shiny: shiny, gender: gender)
        return trainer
    }

    // MARK: - XP and levels

    func testCreditingTokensRaisesTheLevel() throws {
        var trainer = try raising("bulbasaur")
        // 25,500 XP short of nothing: level 1 starts at 100, so this reaches 25,600.
        let events = trainer.credit(
            weightedTokens: 25_500 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.active?.level, 16)
        XCTAssertTrue(events.contains(.levelledUp(to: 16)))
    }

    /// Coins accrue whether or not something is being raised, so a quiet slot
    /// must not be an error. This is the state after a graduation.
    func testCreditingWithNothingActiveIsANoOp() {
        var trainer = Trainer()
        XCTAssertEqual(trainer.credit(weightedTokens: 1_000_000, dex: dex), [])
        XCTAssertNil(trainer.active)
    }

    func testGraduationFiresOnceAtLevel100() throws {
        var trainer = try raising("lapras")  // never evolves; still graduates
        let first = trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.active?.level, 100)
        XCTAssertTrue(first.contains { if case .graduated = $0 { true } else { false } })

        let second = trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertFalse(second.contains { if case .graduated = $0 { true } else { false } })
        XCTAssertEqual(trainer.active?.totalXP, 1_000_000)
    }

    // MARK: - Evolution

    func testLevelEvolutionFiresOnItsOwn() throws {
        var trainer = try raising("bulbasaur")
        let bulbasaur = try entry("bulbasaur"), ivysaur = try entry("ivysaur")

        trainer.credit(weightedTokens: 20_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, bulbasaur.id, "level 14, too early")

        let events = trainer.credit(
            weightedTokens: 10_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, ivysaur.id)
        XCTAssertTrue(events.contains(.evolved(from: bulbasaur.id, to: ivysaur.id)))
        XCTAssertTrue(trainer.log.owns(entryID: ivysaur.id))
    }

    /// One credit can cross several thresholds. Caterpie evolves at 7 and again
    /// at 10, and a single large credit has to fire both rather than stopping at
    /// Metapod until the next scan.
    func testOneCreditCanChainTwoEvolutions() throws {
        var trainer = try raising("caterpie")
        let events = trainer.credit(
            weightedTokens: 20_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("butterfree").id)
        XCTAssertEqual(events.filter { if case .evolved = $0 { true } else { false } }.count, 2)
    }

    /// Where several item-free edges are satisfied at once the choice is the
    /// player's and nothing may fire. Eevee at level 36 has three.
    func testBranchingEvolutionWaitsForThePlayer() throws {
        var trainer = try raising("eevee")
        let eevee = try entry("eevee")
        let events = trainer.credit(weightedTokens: 200_000 * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(trainer.active?.entryID, eevee.id, "must not pick for the player")
        let choice = events.compactMap { event -> [Int]? in
            if case .evolutionChoice(_, let options) = event { options } else { nil }
        }.first
        XCTAssertEqual(choice?.count, 3, "Espeon, Umbreon and Sylveon")
    }

    /// A stone is a thing you choose to use, so an item edge must never fire on
    /// its own no matter how high the level goes.
    func testItemEvolutionNeverFiresOnItsOwn() throws {
        var trainer = try raising("pikachu")
        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("pikachu").id)
        XCTAssertEqual(trainer.active?.level, 100)
    }

    func testItemEvolutionConsumesTheItem() throws {
        var trainer = try raising("pikachu")
        let raichu = try entry("raichu")

        XCTAssertThrowsError(try trainer.evolveActive(into: raichu.id, dex: dex)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .missingItem("thunder-stone"))
        }

        trainer.inventory["thunder-stone"] = 1
        let events = try trainer.evolveActive(into: raichu.id, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, raichu.id)
        XCTAssertEqual(trainer.count(ofItem: "thunder-stone"), 0)
        XCTAssertTrue(events.contains { if case .evolved = $0 { true } else { false } })
    }

    /// The only way a shiny Charizard slot can ever be filled, since eggs draw
    /// from the hatchable pool and Charizard is not in it.
    func testShininessCarriesThroughEvolution() throws {
        var trainer = try raising("charmander", shiny: true)
        trainer.credit(weightedTokens: 1e6 * XPCurve.weightedTokensPerXP, dex: dex)
        let charizard = try entry("charizard")
        XCTAssertEqual(trainer.active?.entryID, charizard.id)
        XCTAssertTrue(trainer.log.owns(entryID: charizard.id, variant: .shiny))
        XCTAssertFalse(trainer.log.owns(entryID: charizard.id, variant: .normal))
    }

    /// A Rare Candy at a low level can carry a Pokemon past two thresholds, so it
    /// runs the same resolution path a token credit does rather than a shortcut.
    func testRareCandyGrantsXPAndCanTriggerEvolution() throws {
        var trainer = try raising("caterpie")
        XCTAssertThrowsError(try trainer.useRareCandy(dex: dex))

        trainer.inventory[Trainer.rareCandySlug] = 1
        let events = try trainer.useRareCandy(dex: dex)
        XCTAssertEqual(trainer.active?.totalXP, 10_100)
        XCTAssertEqual(trainer.count(ofItem: Trainer.rareCandySlug), 0)
        XCTAssertTrue(events.contains { if case .evolved = $0 { true } else { false } })
    }

    // MARK: - Hatching and currency

    func testHatchingCostsCoinsAndFillsASlot() throws {
        var trainer = Trainer()
        XCTAssertThrowsError(try trainer.hatch(coinsEarned: 100, dex: dex, using: &rng)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notEnoughCoins(needed: 300, have: 100))
        }

        let events = try trainer.hatch(coinsEarned: 1_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.coinsSpent, Prices.egg)
        XCTAssertEqual(trainer.coins(earned: 1_000), 700)
        XCTAssertEqual(trainer.log.events.count, 1)
        XCTAssertNotNil(trainer.active, "the first hatch starts raising itself")
        XCTAssertTrue(events.contains { if case .caught = $0 { true } else { false } })
    }

    /// A hatch never interrupts a raise in progress. Losing 40 levels to a
    /// Zubat you did not ask for would make hatching hostile.
    func testHatchingDoesNotStealAnActiveRaise() throws {
        var trainer = try raising("bulbasaur")
        trainer.credit(weightedTokens: 1e9, dex: dex)
        let before = trainer.active
        _ = try trainer.hatch(coinsEarned: 10_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.active, before)
    }

    /// Duplicates are judged on the sprite, not the species: a shiny Pikachu is
    /// new even when Pikachu is not.
    func testDuplicateIsPerVariantNotPerSpecies() throws {
        var trainer = Trainer()
        let pikachu = try entry("pikachu")
        XCTAssertTrue(trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch)))
        XCTAssertTrue(trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .shiny, gender: .male, source: .hatch)))
        XCTAssertFalse(trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch)))
    }

    /// Dust is minted by eggs only. A re-roll that paid out would print money on
    /// exactly the entries its price is meant to protect: a legendary re-roll
    /// costs 25 Dust and its duplicate would be worth 85.
    func testOnlyEggsMintDust() throws {
        var trainer = Trainer()
        let caterpie = try entry("caterpie")
        trainer.log.append(CatchEvent(
            entryID: caterpie.id, variant: .normal, gender: .male, source: .hatch))
        trainer.dust = 100

        _ = try trainer.reroll(entryID: caterpie.id, dex: dex, using: &rng)
        XCTAssertLessThan(trainer.dust, 100, "the re-roll was paid for")
        XCTAssertEqual(trainer.dust, 100 - Prices.reroll(caterpie.rarity))
    }

    func testDuplicateHatchPaysDustScaledOnCaptureRate() throws {
        var trainer = Trainer()
        // Fill every hatchable slot so the next hatch is guaranteed a duplicate.
        for entry in dex.hatchable {
            for variant in entry.ownableVariants {
                trainer.log.append(CatchEvent(
                    entryID: entry.id, variant: variant, gender: .male, source: .hatch))
            }
        }
        let events = try trainer.hatch(coinsEarned: 10_000, dex: dex, using: &rng)
        let paid = events.compactMap { event -> Int? in
            if case .duplicate(_, let dust) = event { dust } else { nil }
        }.first
        XCTAssertEqual(paid, trainer.dust)
        XCTAssertGreaterThan(trainer.dust, 0)
    }

    // MARK: - The guaranteed path

    func testTargetedPickBuysAnEntryOutright() throws {
        var trainer = Trainer()
        let mewtwo = try entry("mewtwo")
        XCTAssertThrowsError(try trainer.targetedPick(entryID: mewtwo.id, dex: dex))

        trainer.dust = Prices.targetedPick(mewtwo.rarity)
        _ = try trainer.targetedPick(entryID: mewtwo.id, dex: dex)
        XCTAssertEqual(trainer.dust, 0)
        XCTAssertTrue(trainer.log.owns(entryID: mewtwo.id))
        XCTAssertEqual(trainer.log.events.first?.source, .targetedPick)

        trainer.dust = 10_000
        XCTAssertThrowsError(try trainer.targetedPick(entryID: mewtwo.id, dex: dex)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .alreadyOwned)
        }
        XCTAssertEqual(trainer.dust, 10_000, "a refused purchase must not charge")
    }

    /// A purchase is not a roll, so it must land on the plain slot rather than
    /// rolling female and leaving the slot it was bought for still empty.
    func testTargetedPickLandsOnThePlainSlot() throws {
        var trainer = Trainer()
        let venusaur = try entry("venusaur")  // has a distinct female sprite
        trainer.dust = 1_000
        _ = try trainer.targetedPick(entryID: venusaur.id, dex: dex)
        XCTAssertTrue(trainer.log.owns(entryID: venusaur.id, variant: .normal))
        XCTAssertFalse(trainer.log.owns(entryID: venusaur.id, variant: .female))
    }

    func testRerollRequiresOwningTheSpecies() throws {
        var trainer = Trainer()
        trainer.dust = 1_000
        XCTAssertThrowsError(
            try trainer.reroll(entryID: try entry("pikachu").id, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notOwned)
        }
    }

    // MARK: - Switching

    func testSwitchingIsFreeAndRestartsAtLevelOne() throws {
        var trainer = try raising("bulbasaur")
        trainer.credit(weightedTokens: 1e9, dex: dex)
        let reached = try XCTUnwrap(trainer.active?.level)
        XCTAssertGreaterThan(reached, 1)

        let pikachu = try entry("pikachu")
        trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch))
        try trainer.setActive(entryID: pikachu.id, dex: dex)

        XCTAssertEqual(trainer.active?.entryID, pikachu.id)
        XCTAssertEqual(trainer.active?.level, 1)
        XCTAssertEqual(trainer.coinsSpent, 0, "switching is free")
        // The abandoned individual's levels are gone, but the collection is not.
        XCTAssertTrue(trainer.log.owns(entryID: try entry("bulbasaur").id))
    }

    func testCannotRaiseSomethingNotOwned() throws {
        var trainer = Trainer()
        XCTAssertThrowsError(
            try trainer.setActive(entryID: try entry("mew").id, dex: dex)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notOwned)
        }
    }

    // MARK: - Shop

    func testBuyingSpendsCoinsAndStocksTheInventory() throws {
        var trainer = Trainer()
        try trainer.buy(.item(slug: "fire-stone", name: "Fire Stone"), coinsEarned: 1_000)
        XCTAssertEqual(trainer.count(ofItem: "fire-stone"), 1)
        XCTAssertEqual(trainer.coinsSpent, Prices.evolutionStone)

        XCTAssertThrowsError(try trainer.buy(.shinyCharm, coinsEarned: 1_000))
        XCTAssertFalse(trainer.hasShinyCharm)
        XCTAssertEqual(trainer.coinsSpent, Prices.evolutionStone, "a refused purchase is free")
    }

    func testShinyCharmIsBoughtOnce() throws {
        var trainer = Trainer()
        try trainer.buy(.shinyCharm, coinsEarned: 100_000)
        XCTAssertTrue(trainer.hasShinyCharm)
        XCTAssertThrowsError(try trainer.buy(.shinyCharm, coinsEarned: 100_000)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .alreadyOwned)
        }
    }

    // MARK: - Persistence

    /// The log is the only thing written to disk; the slot index is rebuilt on
    /// decode. Two copies of the same fact is two things that can disagree.
    func testRoundTripsThroughJSONAndRebuildsTheIndex() throws {
        var trainer = try raising("bulbasaur")
        trainer.credit(weightedTokens: 1e8, dex: dex)
        trainer.dust = 42
        trainer.inventory["fire-stone"] = 2

        let data = try JSONEncoder().encode(trainer)
        let restored = try JSONDecoder().decode(Trainer.self, from: data)

        XCTAssertEqual(restored, trainer)
        XCTAssertEqual(restored.log.filledSlots, trainer.log.filledSlots)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("filledSlots"))
    }
}
