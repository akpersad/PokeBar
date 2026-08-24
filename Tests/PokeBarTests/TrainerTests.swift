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

    /// The event alone is not enough. `Raise` holds the level of the *active*
    /// Pokemon only, so without a written record the fact that this one reached
    /// 100 disappears the moment the player switches, and the Dex ring has
    /// nothing to derive itself from.
    func testGraduationIsWrittenToTheLogOncePerIndividual() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")
        XCTAssertFalse(trainer.log.hasGraduated(entryID: lapras.id))

        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id))
        XCTAssertEqual(trainer.log.graduationCount(entryID: lapras.id), 1)

        let recorded = try XCTUnwrap(trainer.log.graduations.first)
        XCTAssertEqual(recorded.entryID, lapras.id)
        XCTAssertEqual(recorded.raiseID, trainer.active?.id)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id, variant: recorded.variant))

        // Crediting a graduate again must not write a second trophy.
        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.log.graduationCount(entryID: lapras.id), 1)
    }

    /// It graduates as whatever it is *now*. A Charmander that climbed all the
    /// way is a Charizard at the top, and the ring belongs on Charizard's tile.
    func testGraduationIsCreditedToTheEvolvedForm() throws {
        let charmander = try entry("charmander")
        let charizard = try entry("charizard")
        var trainer = try raising("charmander")

        trainer.credit(weightedTokens: 1e12, dex: dex)

        XCTAssertEqual(trainer.active?.entryID, charizard.id)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: charizard.id))
        XCTAssertFalse(
            trainer.log.hasGraduated(entryID: charmander.id),
            "the origin did not finish the climb, the evolved form did")
    }

    /// Graduation is per sprite, the same way ownership is. A shiny at 100 is a
    /// separate trophy from a plain one, and the species-level question stays
    /// true for both.
    func testGraduationIsPerSpriteNotPerSpecies() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras", shiny: true)
        trainer.credit(weightedTokens: 1e12, dex: dex)

        let gender = HatchRoll.canonicalGender(for: lapras)
        let shinySlot = gender.spriteVariant(shiny: true, for: lapras)
        let plainSlot = gender.spriteVariant(shiny: false, for: lapras)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id, variant: shinySlot))
        XCTAssertFalse(trainer.log.hasGraduated(entryID: lapras.id, variant: plainSlot))
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id))
    }

    /// Invariant 23. Every save written before graduations existed omits the
    /// key, and a throwing decode there means `GameMonitor` cannot tell "no save
    /// yet" from "save I could not read" and writes an empty log over a real
    /// collection.
    func testALogSavedBeforeGraduationsExistedStillDecodes() throws {
        let legacy = Data(#"{"events":[]}"#.utf8)
        let log = try JSONDecoder().decode(CatchLog.self, from: legacy)
        XCTAssertTrue(log.graduations.isEmpty)
        XCTAssertTrue(log.graduatedSlots.isEmpty)
        XCTAssertFalse(log.hasGraduated(entryID: 25))
    }

    /// The derived sets are rebuilt on decode rather than stored, the same bet
    /// `filledSlots` makes. A round trip has to reproduce them.
    func testGraduationIndexIsRebuiltOnDecode() throws {
        var trainer = try raising("lapras")
        trainer.credit(weightedTokens: 1e12, dex: dex)

        let data = try JSONEncoder().encode(trainer.log)
        let restored = try JSONDecoder().decode(CatchLog.self, from: data)
        XCTAssertEqual(restored.graduations, trainer.log.graduations)
        XCTAssertEqual(restored.graduatedSlots, trainer.log.graduatedSlots)
        XCTAssertEqual(restored.graduatedEntryIDs, trainer.log.graduatedEntryIDs)
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

    // MARK: - Everstone

    /// The games' item, doing the games' job: no automatic evolution while held.
    func testEverstoneStopsAutomaticEvolution() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, dex: dex)

        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("charmander").id)
        XCTAssertEqual(trainer.active?.level, 100, "it still levels, it just does not evolve")
    }

    /// A hold **queues** rather than cancels, which is what makes it safe to use
    /// and why there is no point of no return. A Caterpie held past both 7 and 10
    /// becomes a Butterfree the moment the stone comes off, in order.
    func testRemovingTheEverstoneFiresEverythingItPassed() throws {
        var trainer = try raising("caterpie")
        trainer.setEverstone(true, dex: dex)
        trainer.credit(weightedTokens: 1e9, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("caterpie").id)

        let events = trainer.setEverstone(false, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("butterfree").id)
        XCTAssertEqual(events.filter { if case .evolved = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(trainer.log.owns(entryID: try entry("metapod").id), "the middle stage counts")
    }

    /// Pressing an evolve button while holding one is an unambiguous instruction.
    func testEverstoneDoesNotBlockAnExplicitEvolution() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, dex: dex)
        trainer.credit(weightedTokens: 1e9, dex: dex)

        try trainer.evolveActive(into: try entry("charmeleon").id, dex: dex)
        XCTAssertEqual(trainer.active?.entryID, try entry("charmeleon").id)
    }

    /// It is held by the individual, so the next one starts without it.
    func testEverstoneDoesNotFollowASwitch() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, dex: dex)
        let pikachu = try entry("pikachu")
        trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch))
        try trainer.setActive(entryID: pikachu.id, dex: dex)
        XCTAssertEqual(trainer.active?.everstone, false)
    }

    // MARK: - Save compatibility

    /// **A new field must never destroy a saved game.** The synthesized decoder
    /// throws on a missing key even where the property has a default, and the
    /// collection is the one thing in this app that cannot be re-derived: the
    /// usage ledger can be rebuilt by rescanning, a Pokemon caught last week
    /// cannot. This is a real save written before `everstone` existed.
    func testASaveWrittenBeforeEverstoneStillLoads() throws {
        let json = """
            {"coinsSpent":30000,"inventory":{},"hasShinyCharm":true,
             "active":{"originEntryID":4,"shiny":false,"totalXP":2360.546,
                       "gender":"female","id":"2C6F0687-6264-48A2-AD07-EDB508169BB8",
                       "startedAt":809232069.327612,"entryID":4},
             "dust":0,
             "log":{"events":[{"source":{"starter":{}},"gender":"female","entryID":4,
                               "variant":{"female":false,"shiny":false},
                               "id":"EE118714-DB61-4975-90CA-2761F1B79779",
                               "date":809232069.327612}]}}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertEqual(trainer.active?.entryID, 4)
        XCTAssertEqual(trainer.active?.totalXP, 2360.546)
        XCTAssertEqual(trainer.active?.everstone, false, "absent means not held")
        XCTAssertTrue(trainer.hasShinyCharm)
        XCTAssertEqual(trainer.coinsSpent, 30_000)
        XCTAssertEqual(trainer.log.events.count, 1)
        XCTAssertEqual(trainer.log.events.first?.source, .starter)
        XCTAssertTrue(trainer.log.owns(entryID: 4), "the slot index rebuilt on decode")
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

    /// Nothing that *acquires* a Pokemon may interrupt a raise in progress.
    /// Losing 40 levels to a Zubat you did not ask for would make hatching
    /// hostile, and losing them to a shiny hunt would make re-rolling unusable:
    /// the whole point of a re-roll is to keep fishing while the current one
    /// climbs. Hatch, re-roll and the targeted pick all share `obtain`, which
    /// assigns an active raise only when there is none, so this pins all three
    /// rather than trusting that they stay on one path.
    func testAcquiringNeverStealsAnActiveRaise() throws {
        var trainer = try raising("bulbasaur")
        trainer.credit(weightedTokens: 1e9, dex: dex)
        let before = try XCTUnwrap(trainer.active)
        XCTAssertGreaterThan(before.level, 1)

        _ = try trainer.hatch(coinsEarned: 10_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.active, before, "a hatch stole the raise")

        // Re-roll the species being raised, which is the worst case: same entry,
        // so a careless implementation would overwrite the individual.
        trainer.dust = 1_000
        _ = try trainer.reroll(entryID: before.entryID, dex: dex, using: &rng)
        XCTAssertEqual(trainer.active, before, "a re-roll stole the raise")

        _ = try trainer.targetedPick(entryID: try entry("mewtwo").id, dex: dex)
        XCTAssertEqual(trainer.active, before, "a targeted pick stole the raise")

        // And the XP is genuinely still there, not merely an equal-looking Raise.
        XCTAssertEqual(trainer.active?.totalXP, before.totalXP)
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

    // MARK: - The first pick

    /// The starter list is hardcoded, because nothing in PokeAPI marks a species
    /// as one. This is what keeps it from being 27 magic numbers: every property
    /// that made them starters is asserted against the real dex.
    func testStarterListIsThreePerGenerationAndAllHatchable() {
        let starters = dex.starters
        XCTAssertEqual(starters.count, 27, "one missing from the dex would silently vanish")
        XCTAssertEqual(Set(starters.map(\.id)).count, 27)

        for generation in 1...9 {
            XCTAssertEqual(
                starters.filter { $0.generation == generation }.count, 3,
                "generation \(generation)")
        }
        for entry in starters {
            XCTAssertFalse(dex.isEvolutionGated(entry), "\(entry.slug) must be hatchable")
            XCTAssertFalse(entry.isRegionalForm, entry.slug)
            XCTAssertFalse(entry.evolutions.isEmpty, "\(entry.slug) should grow into something")
        }
        XCTAssertEqual(starters.first?.slug, "bulbasaur")
        XCTAssertEqual(starters.last?.slug, "quaxly")
    }

    /// Every starter is a three-stage line, and exactly three of them fork at the
    /// second stage into a Hisuian form. That fork is only in the data because the
    /// edge join was corrected: under the old join these regional evolutions had no
    /// incoming edge at all. The picker names both branches, so this pins which
    /// lines have one.
    func testStarterChainDepthsAndBranches() {
        var branching: [String] = []
        for entry in dex.starters {
            var current = entry
            var depth = 0
            while let next = current.evolutions.first.flatMap({ dex.entry(id: $0.to) }) {
                if current.evolutions.count > 1 { branching.append(current.slug) }
                current = next
                depth += 1
                if depth > 4 { XCTFail("\(entry.slug) chain does not terminate"); break }
            }
            XCTAssertEqual(depth, 2, "\(entry.slug) should be a three-stage line")
        }
        XCTAssertEqual(branching.sorted(), ["dartrix", "dewott", "quilava"])
    }

    /// The rule is "one item-free edge in total fires", not "one *ready* edge
    /// fires". The narrower version looks equivalent and silently locks targets
    /// out: Dartrix would evolve into Decidueye the moment it hit 34, stop being a
    /// Dartrix, and never reach the level-36 edge to Hisuian Decidueye. Nincada is
    /// the same shape with Ninjask at 20 and Shedinja at 36.
    ///
    /// The graph still contained both edges either way, which is why the
    /// generator's reachability assertion did not catch it.
    func testBranchingWaitsEvenWhenOnlyOneBranchIsReady() throws {
        for (slug, early, late) in [
            ("dartrix", "decidueye", "decidueye-hisui"),
            ("nincada", "ninjask", "shedinja"),
        ] {
            var trainer = try raising(slug)
            let start = try entry(slug)
            // Past the earlier edge, short of the later one.
            let level = slug == "dartrix" ? 34 : 20
            trainer.credit(
                weightedTokens: Double(XPCurve.totalXP(forLevel: level))
                    * XPCurve.weightedTokensPerXP, dex: dex)

            XCTAssertEqual(trainer.active?.entryID, start.id, "\(slug) must not auto-evolve")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(trainer.active?.level), level)

            // Both remain reachable by raising, which is the point.
            try trainer.evolveActive(into: try entry(early).id, dex: dex)
            XCTAssertEqual(trainer.active?.entryID, try entry(early).id)

            var second = try raising(slug)
            second.credit(weightedTokens: 1e12, dex: dex)
            try second.evolveActive(into: try entry(late).id, dex: dex)
            XCTAssertEqual(second.active?.entryID, try entry(late).id)
        }
    }

    func testChoosingAStarterIsFreeAndStartsTheRaise() throws {
        var trainer = Trainer()
        XCTAssertTrue(trainer.needsStarter)

        let squirtle = try entry("squirtle")
        let events = try trainer.chooseStarter(entryID: squirtle.id, dex: dex, using: &rng)

        XCTAssertEqual(trainer.coinsSpent, 0, "the first pick costs nothing")
        XCTAssertEqual(trainer.active?.entryID, squirtle.id)
        XCTAssertEqual(trainer.active?.level, 1)
        XCTAssertTrue(trainer.log.owns(entryID: squirtle.id))
        XCTAssertEqual(trainer.log.events.first?.source, .starter)
        XCTAssertFalse(trainer.needsStarter)
        XCTAssertTrue(events.contains { if case .caught = $0 { true } else { false } })
    }

    /// Once only, and the guard is the log rather than a flag: "have I ever caught
    /// anything" is a question the log already answers.
    func testStarterCanOnlyBeChosenOnce() throws {
        var trainer = Trainer()
        _ = try trainer.chooseStarter(entryID: try entry("squirtle").id, dex: dex, using: &rng)
        XCTAssertThrowsError(
            try trainer.chooseStarter(entryID: try entry("bulbasaur").id, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notStartingOut)
        }
        XCTAssertEqual(trainer.log.events.count, 1)
    }

    /// A hatch closes the window too, so the free pick cannot be taken after
    /// seeing what luck gave you.
    func testHatchingFirstForfeitsTheStarterPick() throws {
        var trainer = Trainer()
        _ = try trainer.hatch(coinsEarned: 1_000, dex: dex, using: &rng)
        XCTAssertFalse(trainer.needsStarter)
        XCTAssertThrowsError(
            try trainer.chooseStarter(entryID: try entry("squirtle").id, dex: dex, using: &rng))
    }

    func testOnlyStartersCanBeChosen() throws {
        var trainer = Trainer()
        XCTAssertThrowsError(
            try trainer.chooseStarter(entryID: try entry("mewtwo").id, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .unknownEntry(150))
        }
        XCTAssertTrue(trainer.needsStarter, "a refused pick must not consume it")
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
