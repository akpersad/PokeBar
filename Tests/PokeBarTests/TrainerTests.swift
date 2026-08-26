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

    /// Another individual, straight into the roster and into a free slot.
    ///
    /// `beginRaising` is the same call every acquisition path makes, so this is
    /// the production path with the price and the variant roll skipped.
    @discardableResult
    private func addMember(to trainer: inout Trainer, entryID: Int) -> UUID {
        let entry = dex.entry(id: entryID)!
        return trainer.beginRaising(
            entryID: entryID, gender: HatchRoll.canonicalGender(for: entry))
    }

    /// The lead's id, for the verbs that now insist on naming an individual.
    /// Force-unwrapped on purpose: a test whose lead vanished should fail loudly.
    private func leadID(_ trainer: Trainer) -> UUID { trainer.lead!.id }

    /// Starts a trainer already raising `slug`, without going through a hatch.
    private func raising(_ slug: String, shiny: Bool = false) throws -> Trainer {
        let entry = try self.entry(slug)
        var trainer = Trainer()
        let gender = HatchRoll.canonicalGender(for: entry)
        trainer.log.append(CatchEvent(
            entryID: entry.id, variant: gender.spriteVariant(shiny: shiny, for: entry),
            gender: gender, source: .hatch))
        trainer.beginRaising(entryID: entry.id, shiny: shiny, gender: gender)
        return trainer
    }

    // MARK: - XP and levels

    func testCreditingTokensRaisesTheLevel() throws {
        var trainer = try raising("bulbasaur")
        // 25,500 XP short of nothing: level 1 starts at 100, so this reaches 25,600.
        let events = trainer.credit(
            weightedTokens: 25_500 * XPCurve.weightedTokensPerXP, dex: dex)
        let raise = try XCTUnwrap(trainer.lead)
        XCTAssertEqual(raise.level, 16)
        // Ivysaur, not Bulbasaur: the edge is at 16, so at level 16 it is an
        // Ivysaur. "Reached level 16" is a statement about what it is at 16.
        XCTAssertTrue(
            events.contains(
                .levelledUp(raiseID: raise.id, entryID: try entry("ivysaur").id, to: 16)),
            "and the event names which individual did it, and what it was at the time")
    }

    /// Coins accrue whether or not something is being raised, so a quiet slot
    /// must not be an error. This is the state after a graduation.
    func testCreditingWithNothingActiveIsANoOp() {
        var trainer = Trainer()
        XCTAssertEqual(trainer.credit(weightedTokens: 1_000_000, dex: dex), [])
        XCTAssertNil(trainer.lead)
    }

    func testGraduationFiresOnceAtLevel100() throws {
        var trainer = try raising("lapras")  // never evolves; still graduates
        let first = trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.lead?.level, 100)
        XCTAssertTrue(first.contains { if case .graduated = $0 { true } else { false } })

        let second = trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertFalse(second.contains { if case .graduated = $0 { true } else { false } })
        XCTAssertEqual(trainer.lead?.totalXP, 1_000_000)
    }

    /// The event alone is not enough. `Raise` holds the level of the *active*
    /// Pokemon only, so without a written record the fact that this one got
    /// there disappears the moment the player switches, and the Dex ring has
    /// nothing to derive itself from.
    func testMilestonesAreWrittenToTheLog() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")
        XCTAssertNil(trainer.log.milestone(entryID: lapras.id))

        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 100)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id))

        let recorded = try XCTUnwrap(trainer.log.milestones.last)
        XCTAssertEqual(recorded.entryID, lapras.id)
        XCTAssertEqual(recorded.raiseID, trainer.lead?.id)
        XCTAssertEqual(trainer.log.milestoneCount(entryID: lapras.id, level: 100), 1)

        // Crediting a graduate again must not write a second mark.
        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.log.milestoneCount(entryID: lapras.id, level: 100), 1)
    }

    /// The silver ring. Halfway is its own recorded fact, not something inferred
    /// from a level the log does not keep.
    func testHalfwayIsRecordedOnItsOwn() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")

        // Level 50 starts at 250,000 XP; level 1 already banks 100.
        trainer.credit(weightedTokens: 249_900 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.level, 50)
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 50)
        XCTAssertFalse(trainer.log.hasGraduated(entryID: lapras.id))
        XCTAssertEqual(trainer.log.milestones.count, 1)
    }

    // MARK: - Marks across an evolution

    /// **The Dragonite case.** Dragonair evolves at 55, so on the normal path no
    /// Dragonite ever *crosses* level 50: the mark is recorded against Dragonair
    /// and the Dragonite tile would sit blank from 55 to 99 and then jump to gold.
    /// A level 60 Dragonite is plainly a Pokemon that has reached level 50, so the
    /// tile reads the roster as well as the log.
    func testALineThatEvolvesAboveFiftyStillShowsSilverOnTheEvolvedForm() throws {
        var trainer = try raising("dratini")
        let dragonair = try entry("dragonair"), dragonite = try entry("dragonite")

        // Level 60: past 50 as a Dragonair, then past the 55 edge.
        trainer.credit(weightedTokens: 360_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.level, 60)
        XCTAssertEqual(trainer.lead?.entryID, dragonite.id)

        XCTAssertEqual(
            trainer.log.milestone(entryID: dragonair.id), 50,
            "it crossed 50 while it was a Dragonair, and the log says so")
        XCTAssertNil(
            trainer.log.milestone(entryID: dragonite.id),
            "and no Dragonite has ever crossed 50, which is the whole problem")

        XCTAssertEqual(trainer.milestone(entryID: dragonair.id), 50, "the mark it earned")
        XCTAssertEqual(
            trainer.milestone(entryID: dragonite.id), 50,
            "and the one it plainly qualifies for, from the roster")
        XCTAssertEqual(trainer.milestoneCount(entryID: dragonite.id, level: 50), 1)
    }

    /// One credit can carry an individual past a mark, past an evolution, and
    /// past a second mark. Each has to land on what it was at the time, and the
    /// answer must not depend on how the XP happened to arrive.
    func testMarksAcrossOneHugeCreditLandOnTheRightForms() throws {
        let dragonair = try entry("dragonair"), dragonite = try entry("dragonite")

        // Incrementally: 50 first, then past 55, then 100.
        var slow = try raising("dratini")
        slow.credit(weightedTokens: 250_000 * XPCurve.weightedTokensPerXP, dex: dex)
        slow.credit(weightedTokens: 1e9, dex: dex)

        // All at once, from level 1. This is a cold first scan, not an exotic case.
        var fast = try raising("dratini")
        fast.credit(weightedTokens: 1e9, dex: dex)

        for (name, trainer) in [("incremental", slow), ("one credit", fast)] {
            XCTAssertEqual(
                trainer.log.milestone(entryID: dragonair.id), 50,
                "\(name): 50 belongs to the Dragonair that crossed it")
            XCTAssertEqual(
                trainer.log.milestone(entryID: dragonite.id), 100,
                "\(name): and 100 to the Dragonite that graduated")
            XCTAssertEqual(trainer.lead?.entryID, dragonite.id, "\(name)")
        }
    }

    /// The union is by individual, so one that crossed the line *and* is still
    /// that form is one Pokemon, not two.
    func testTheMarkCountDoesNotDoubleCountOneIndividual() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        trainer.credit(weightedTokens: 250_000 * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 50, "crossed it as a Lapras")
        XCTAssertEqual(
            trainer.milestoneCount(entryID: lapras.id, level: 50), 1,
            "and is still a Lapras, which is the same Pokemon")
        XCTAssertFalse(trainer.hasGraduated(entryID: lapras.id))
    }

    /// A stone used on a graduate opens the same gap above 100: the Vaporeon
    /// never crossed anything, the Eevee did.
    func testAnItemEvolutionAfterGraduationCarriesTheMark() throws {
        var trainer = try raising("eevee")
        trainer.credit(weightedTokens: 1e9, dex: dex)
        let eevee = try entry("eevee"), vaporeon = try entry("vaporeon")
        XCTAssertEqual(trainer.lead?.level, 100)

        trainer.inventory["water-stone"] = 1
        _ = try trainer.evolve(leadID(trainer), into: vaporeon.id, dex: dex)

        XCTAssertEqual(trainer.log.milestone(entryID: eevee.id), 100, "the Eevee graduated")
        XCTAssertNil(trainer.log.milestone(entryID: vaporeon.id), "the Vaporeon never crossed")
        XCTAssertEqual(
            trainer.milestone(entryID: vaporeon.id), 100,
            "but it is a level 100 Vaporeon and the tile should say so")
        XCTAssertTrue(trainer.hasGraduated(entryID: vaporeon.id))
    }

    /// Just short of the mark is not the mark.
    func testLevel49LeavesNoRing() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")
        trainer.credit(weightedTokens: 239_900 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.level, 48)
        XCTAssertNil(trainer.log.milestone(entryID: lapras.id))
    }

    /// One credit can clear both marks: a Rare Candy, or a quiet hour on a busy
    /// machine. The log should say it passed 50 rather than skipping it, the
    /// same way `resolveEvolutions` loops rather than firing once.
    func testOneCreditCrossingBothMarksRecordsBoth() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")

        trainer.credit(weightedTokens: 1e12, dex: dex)

        XCTAssertEqual(trainer.log.milestones.map(\.level), [50, 100])
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 100, "gold, not silver")
    }

    /// Gold replaces silver. Everything at 100 passed 50 on the way, and the
    /// grid draws only the highest mark.
    func testGraduationSupersedesHalfway() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras")
        trainer.credit(weightedTokens: 249_900 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 50)

        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 100)
        XCTAssertEqual(trainer.log.milestoneCount(entryID: lapras.id, level: 50), 1)
    }

    /// It reaches the mark as whatever it is *now*. A Charmander raised all the
    /// way is a Charizard at the top, and the ring belongs on Charizard's tile.
    func testMilestoneIsCreditedToTheEvolvedForm() throws {
        let charmander = try entry("charmander")
        let charizard = try entry("charizard")
        var trainer = try raising("charmander")

        trainer.credit(weightedTokens: 1e12, dex: dex)

        XCTAssertEqual(trainer.lead?.entryID, charizard.id)
        XCTAssertTrue(trainer.log.hasGraduated(entryID: charizard.id))
        XCTAssertNil(
            trainer.log.milestone(entryID: charmander.id),
            "the origin did not finish the climb, the evolved form did")
    }

    /// Per sprite, the same way ownership is. A shiny at 100 is a separate mark
    /// from a plain one, and the species-level question stays true for both.
    func testMilestonesArePerSpriteNotPerSpecies() throws {
        let lapras = try entry("lapras")
        var trainer = try raising("lapras", shiny: true)
        trainer.credit(weightedTokens: 1e12, dex: dex)

        let gender = HatchRoll.canonicalGender(for: lapras)
        XCTAssertEqual(
            trainer.log.milestone(
                entryID: lapras.id, variant: gender.spriteVariant(shiny: true, for: lapras)),
            100)
        XCTAssertNil(
            trainer.log.milestone(
                entryID: lapras.id, variant: gender.spriteVariant(shiny: false, for: lapras)))
        XCTAssertTrue(trainer.log.hasGraduated(entryID: lapras.id))
    }

    /// Invariant 23. Every save written before milestones existed omits the key,
    /// and a throwing decode there means `GameMonitor` cannot tell "no save yet"
    /// from "save I could not read" and writes an empty log over a real
    /// collection.
    func testALogSavedBeforeMilestonesExistedStillDecodes() throws {
        let legacy = Data(#"{"events":[]}"#.utf8)
        let log = try JSONDecoder().decode(CatchLog.self, from: legacy)
        XCTAssertTrue(log.milestones.isEmpty)
        XCTAssertNil(log.milestone(entryID: 25))
    }

    /// The field shipped once as `graduations`, holding records with no `level`,
    /// from when 100 was the only marked level. Both the old key and the old
    /// record shape have to read back as level 100.
    func testTheFirstShippedGraduationShapeReadsBackAsLevel100() throws {
        let json =
            #"{"events":[],"graduations":[{"id":"E1B7A0B0-0000-4000-8000-000000000001","#
            + #""entryID":131,"variant":{"shiny":false,"female":false},"#
            + #""raiseID":"E1B7A0B0-0000-4000-8000-000000000002","date":809232069.3}]}"#
        let log = try JSONDecoder().decode(CatchLog.self, from: Data(json.utf8))
        XCTAssertEqual(log.milestones.count, 1)
        XCTAssertEqual(log.milestone(entryID: 131), 100)
        XCTAssertTrue(log.hasGraduated(entryID: 131))
    }

    /// The derived maps are rebuilt on decode rather than stored, the same bet
    /// `filledSlots` makes. A round trip has to reproduce them, and the encoded
    /// form must use the current key.
    func testMilestoneIndexIsRebuiltOnDecode() throws {
        var trainer = try raising("lapras")
        trainer.credit(weightedTokens: 1e12, dex: dex)

        let data = try JSONEncoder().encode(trainer.log)
        XCTAssertTrue(
            try XCTUnwrap(String(data: data, encoding: .utf8)).contains("milestones"))
        let restored = try JSONDecoder().decode(CatchLog.self, from: data)
        XCTAssertEqual(restored.milestones, trainer.log.milestones)
        XCTAssertEqual(restored.milestoneBySlot, trainer.log.milestoneBySlot)
        XCTAssertEqual(restored.milestoneByEntry, trainer.log.milestoneByEntry)
    }

    // MARK: - Evolution

    func testLevelEvolutionFiresOnItsOwn() throws {
        var trainer = try raising("bulbasaur")
        let bulbasaur = try entry("bulbasaur"), ivysaur = try entry("ivysaur")

        trainer.credit(weightedTokens: 20_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, bulbasaur.id, "level 14, too early")

        let events = trainer.credit(
            weightedTokens: 10_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, ivysaur.id)
        XCTAssertTrue(events.contains(.evolved(
            raiseID: try XCTUnwrap(trainer.lead).id, from: bulbasaur.id, to: ivysaur.id)))
        XCTAssertTrue(trainer.log.owns(entryID: ivysaur.id))
    }

    /// One credit can cross several thresholds. Caterpie evolves at 7 and again
    /// at 10, and a single large credit has to fire both rather than stopping at
    /// Metapod until the next scan.
    func testOneCreditCanChainTwoEvolutions() throws {
        var trainer = try raising("caterpie")
        let events = trainer.credit(
            weightedTokens: 20_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("butterfree").id)
        XCTAssertEqual(events.filter { if case .evolved = $0 { true } else { false } }.count, 2)
    }

    /// Where several item-free edges are satisfied at once the choice is the
    /// player's and nothing may fire. Eevee at level 36 has three.
    func testBranchingEvolutionWaitsForThePlayer() throws {
        var trainer = try raising("eevee")
        let eevee = try entry("eevee")
        let events = trainer.credit(weightedTokens: 200_000 * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(trainer.lead?.entryID, eevee.id, "must not pick for the player")
        let choice = events.compactMap { event -> [Int]? in
            if case .evolutionChoice(_, _, let options) = event { options } else { nil }
        }.first
        XCTAssertEqual(choice?.count, 3, "Espeon, Umbreon and Sylveon")
    }

    /// A stone is a thing you choose to use, so an item edge must never fire on
    /// its own no matter how high the level goes.
    func testItemEvolutionNeverFiresOnItsOwn() throws {
        var trainer = try raising("pikachu")
        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("pikachu").id)
        XCTAssertEqual(trainer.lead?.level, 100)
    }

    func testItemEvolutionConsumesTheItem() throws {
        var trainer = try raising("pikachu")
        let raichu = try entry("raichu")

        XCTAssertThrowsError(try trainer.evolve(leadID(trainer), into: raichu.id, dex: dex)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .missingItem("thunder-stone"))
        }

        trainer.inventory["thunder-stone"] = 1
        let events = try trainer.evolve(leadID(trainer), into: raichu.id, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, raichu.id)
        XCTAssertEqual(trainer.count(ofItem: "thunder-stone"), 0)
        XCTAssertTrue(events.contains { if case .evolved = $0 { true } else { false } })
    }

    /// The only way a shiny Charizard slot can ever be filled, since eggs draw
    /// from the hatchable pool and Charizard is not in it.
    func testShininessCarriesThroughEvolution() throws {
        var trainer = try raising("charmander", shiny: true)
        trainer.credit(weightedTokens: 1e6 * XPCurve.weightedTokensPerXP, dex: dex)
        let charizard = try entry("charizard")
        XCTAssertEqual(trainer.lead?.entryID, charizard.id)
        XCTAssertTrue(trainer.log.owns(entryID: charizard.id, variant: .shiny))
        XCTAssertFalse(trainer.log.owns(entryID: charizard.id, variant: .normal))
    }

    /// A Rare Candy at a low level can carry a Pokemon past two thresholds, so it
    /// runs the same resolution path a token credit does rather than a shortcut.
    func testRareCandyGrantsXPAndCanTriggerEvolution() throws {
        var trainer = try raising("caterpie")
        XCTAssertThrowsError(try trainer.useRareCandy(on: leadID(trainer), dex: dex))

        trainer.inventory[Trainer.rareCandySlug] = 1
        let events = try trainer.useRareCandy(on: leadID(trainer), dex: dex)
        XCTAssertEqual(trainer.lead?.totalXP, 10_100)
        XCTAssertEqual(trainer.count(ofItem: Trainer.rareCandySlug), 0)
        XCTAssertTrue(events.contains { if case .evolved = $0 { true } else { false } })
    }

    // MARK: - Everstone

    /// The games' item, doing the games' job: no automatic evolution while held.
    func testEverstoneStopsAutomaticEvolution() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, of: leadID(trainer), dex: dex)

        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("charmander").id)
        XCTAssertEqual(trainer.lead?.level, 100, "it still levels, it just does not evolve")
    }

    /// A hold **queues** rather than cancels, which is what makes it safe to use
    /// and why there is no point of no return. A Caterpie held past both 7 and 10
    /// becomes a Butterfree the moment the stone comes off, in order.
    func testRemovingTheEverstoneFiresEverythingItPassed() throws {
        var trainer = try raising("caterpie")
        trainer.setEverstone(true, of: leadID(trainer), dex: dex)
        trainer.credit(weightedTokens: 1e9, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("caterpie").id)

        let events = trainer.setEverstone(false, of: leadID(trainer), dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("butterfree").id)
        XCTAssertEqual(events.filter { if case .evolved = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(trainer.log.owns(entryID: try entry("metapod").id), "the middle stage counts")
    }

    /// Pressing an evolve button while holding one is an unambiguous instruction.
    func testEverstoneDoesNotBlockAnExplicitEvolution() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, of: leadID(trainer), dex: dex)
        trainer.credit(weightedTokens: 1e9, dex: dex)

        try trainer.evolve(leadID(trainer), into: try entry("charmeleon").id, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("charmeleon").id)
    }

    /// It is held by the individual, so the next one starts without it, and the
    /// one that was holding it still is when it comes back off the bench.
    func testEverstoneDoesNotFollowASwitchButStaysWithItsHolder() throws {
        var trainer = try raising("charmander")
        trainer.setEverstone(true, of: leadID(trainer), dex: dex)
        let charmander = try XCTUnwrap(trainer.lead)

        let pikachu = try entry("pikachu")
        trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch))
        let next = addMember(to: &trainer, entryID: pikachu.id)

        XCTAssertEqual(trainer.raise(id: next)?.everstone, false, "a new one starts without")
        XCTAssertEqual(
            trainer.raise(id: charmander.id)?.everstone, true,
            "the stone is that Pokemon's item, not the trainer's")
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

        XCTAssertEqual(trainer.lead?.entryID, 4)
        XCTAssertEqual(trainer.lead?.totalXP, 2360.546)
        XCTAssertEqual(trainer.lead?.everstone, false, "absent means not held")
        XCTAssertTrue(trainer.hasShinyCharm)
        XCTAssertEqual(trainer.coinsSpent, 30_000)
        XCTAssertEqual(trainer.log.events.count, 1)
        XCTAssertEqual(trainer.log.events.first?.source, .starter)
        XCTAssertTrue(trainer.log.owns(entryID: 4), "the slot index rebuilt on decode")
    }

    /// The v1 shape had one `active` individual and no roster. Reading that key
    /// is how a save written before today keeps its Charizard, so it is read
    /// **forever and never written**, the same way `CatchLog` still reads
    /// `graduations`.
    ///
    /// This is a real save, taken verbatim from the live app before the roster
    /// existed.
    func testAPreRosterSaveLandsInTeamSlotOneWithItsLevel() throws {
        let json = """
            {"coinsSpent":30000,"inventory":{},"hasShinyCharm":true,
             "active":{"originEntryID":4,"shiny":false,"totalXP":2360.546,
                       "gender":"female","id":"2C6F0687-6264-48A2-AD07-EDB508169BB8",
                       "startedAt":809232069.327612,"entryID":4,"everstone":true},
             "dust":0,
             "log":{"events":[{"source":{"starter":{}},"gender":"female","entryID":4,
                               "variant":{"female":false,"shiny":false},
                               "id":"EE118714-DB61-4975-90CA-2761F1B79779",
                               "date":809232069.327612}]}}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        let migrated = try XCTUnwrap(trainer.roster.first)
        XCTAssertEqual(trainer.roster.count, 1)
        XCTAssertEqual(trainer.team, [migrated.id])
        XCTAssertEqual(migrated.id.uuidString, "2C6F0687-6264-48A2-AD07-EDB508169BB8")
        XCTAssertEqual(migrated.totalXP, 2360.546, "the XP is the point")
        XCTAssertEqual(migrated.entryID, 4)
        XCTAssertEqual(migrated.everstone, true, "and it is still holding its stone")
        XCTAssertEqual(trainer.lead?.id, migrated.id, "slot 1, so the UI sees it")
    }

    /// Two new persisted fields, so two more chances to make every existing save
    /// unreadable. Same rule as always: absent means false.
    func testASaveWrittenBeforeTheExpShareStillLoads() throws {
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":true,"dust":4,
             "log":{"events":[]}}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertFalse(trainer.hasExpShare)
        XCTAssertFalse(trainer.expShareEnabled)
        XCTAssertFalse(trainer.expShareActive)
        XCTAssertTrue(trainer.hasShinyCharm, "and the field beside it is untouched")
    }

    /// Both halves round trip, because owning it and using it are separate facts.
    func testTheExpShareFlagsSurviveASaveAndReload() throws {
        var trainer = try raising("lapras")
        try trainer.buy(.expShare, coinsEarned: 10_000)
        trainer.setExpShare(false)

        let data = try JSONEncoder().encode(trainer)
        let reloaded = try JSONDecoder().decode(Trainer.self, from: data)

        XCTAssertTrue(reloaded.hasExpShare)
        XCTAssertFalse(reloaded.expShareEnabled)
        XCTAssertEqual(reloaded, trainer)
    }

    /// Writing `active` again would mean two copies of one fact, and the older
    /// reader would win on the next launch of an older build.
    func testTheLegacyActiveKeyIsNeverWritten() throws {
        var trainer = try raising("charmander")
        trainer.credit(weightedTokens: 10_000 * XPCurve.weightedTokensPerXP, dex: dex)

        let data = try JSONEncoder().encode(trainer)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["active"], "read the old key, write the new one, never both")
        XCTAssertNotNil(object["roster"])
        XCTAssertNotNil(object["team"])
        XCTAssertEqual(try JSONDecoder().decode(Trainer.self, from: data), trainer)
    }

    /// A save with both keys is one written by this build and read by it: the
    /// roster is the truth and the legacy key is ignored, not merged.
    func testASaveWithBothKeysPrefersTheRoster() throws {
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":false,"dust":0,
             "log":{"events":[]},
             "roster":[{"originEntryID":25,"shiny":false,"totalXP":40100,
                        "gender":"male","id":"11111111-1111-1111-1111-111111111111",
                        "startedAt":809232069.327612,"entryID":25}],
             "team":["11111111-1111-1111-1111-111111111111"],
             "active":{"originEntryID":4,"shiny":false,"totalXP":100,
                       "gender":"female","id":"2C6F0687-6264-48A2-AD07-EDB508169BB8",
                       "startedAt":809232069.327612,"entryID":4}}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertEqual(trainer.roster.count, 1)
        XCTAssertEqual(trainer.lead?.entryID, 25)
        XCTAssertEqual(trainer.lead?.totalXP, 40_100)
    }

    /// Neither key, which is every save written before anything was ever raised.
    /// An empty roster, not a throw: throwing would quarantine a perfectly good
    /// collection and start the player over.
    func testASaveWithNeitherKeyYieldsAnEmptyRoster() throws {
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":false,"dust":0,
             "log":{"events":[]}}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertTrue(trainer.roster.isEmpty)
        XCTAssertTrue(trainer.team.isEmpty)
        XCTAssertNil(trainer.lead)
        XCTAssertTrue(trainer.needsStarter)
    }

    /// **A file missing the keys every save has always carried is not a save.**
    /// It has to throw, because `GameMonitor` quarantines on a throw and silently
    /// replaces on a success: decoding `{}` into a shiny new empty trainer is how
    /// a collection gets deleted by a bug that looks like it worked.
    func testAnObjectMissingTheOldKeysThrowsRatherThanDecodingEmpty() {
        for json in ["{}", "{\"roster\":[],\"team\":[]}", "{\"log\":{\"events\":[]}}"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(Trainer.self, from: Data(json.utf8)),
                "\(json) must not decode")
        }
    }

    /// The team is a list of references into the roster, so it is the one part of
    /// the save that can contradict itself. Sanitised on decode rather than
    /// guarded at every use site, the same instinct as rebuilding the slot index.
    func testTheTeamIsSanitisedOnDecode() throws {
        let known = "11111111-1111-1111-1111-111111111111"
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":false,"dust":0,
             "log":{"events":[]},
             "roster":[{"originEntryID":25,"shiny":false,"totalXP":100,
                        "gender":"male","id":"\(known)",
                        "startedAt":809232069.327612,"entryID":25}],
             "team":["\(known)","\(known)","22222222-2222-2222-2222-222222222222"]}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertEqual(
            trainer.team.map(\.uuidString), [known],
            "the repeat collapsed and the stranger went")
        XCTAssertEqual(trainer.teamRaises.count, 1)
    }

    /// Capped on decode too, so a file that claims eight cannot hand out eight
    /// shares once step 2 starts distributing them.
    func testAnOversizedTeamIsCappedOnDecode() throws {
        let ids = (1...8).map { String(repeating: "\($0)", count: 8) }
            .map { "\($0)-\($0.prefix(4))-\($0.prefix(4))-\($0.prefix(4))-\($0)\($0.prefix(4))" }
        let roster = ids.map {
            """
            {"originEntryID":25,"shiny":false,"totalXP":100,"gender":"male",
             "id":"\($0)","startedAt":809232069.327612,"entryID":25}
            """
        }
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":false,"dust":0,
             "log":{"events":[]},
             "roster":[\(roster.joined(separator: ","))],
             "team":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))]}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))

        XCTAssertEqual(trainer.roster.count, 8, "the roster is not capped, only the team")
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity)
        XCTAssertEqual(trainer.team.first?.uuidString.lowercased(), ids[0].lowercased())
    }

    // MARK: - Hatching and currency

    func testHatchingCostsCoinsAndFillsASlot() throws {
        var trainer = Trainer()
        XCTAssertThrowsError(try trainer.hatch(coinsEarned: 100, dex: dex, using: &rng)) { error in
            XCTAssertEqual(
                error as? Trainer.GameError, .notEnoughCoins(needed: Prices.egg, have: 100))
        }

        let events = try trainer.hatch(coinsEarned: 1_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.coinsSpent, Prices.egg)
        XCTAssertEqual(trainer.coins(earned: 1_000), 1_000 - Prices.egg)
        XCTAssertEqual(trainer.log.events.count, 1)
        XCTAssertNotNil(trainer.lead, "the first hatch starts raising itself")
        XCTAssertTrue(events.contains { if case .caught = $0 { true } else { false } })
    }

    // MARK: - The egg ladder

    /// Weighted chance that one egg of `tier` produces something in `bands`.
    ///
    /// Weighted on the raw capture rate, because that is what `HatchRoll` does.
    /// Banding the weights would give a different and wrong answer, which is the
    /// point of the decision recorded against `HatchRoll.draw`.
    private func chance(_ tier: EggTier, of bands: Set<Rarity>) -> Double {
        let pool = dex.hatchPool(for: tier)
        let total = pool.reduce(0.0) { $0 + Double(max($1.captureRate, 1)) }
        let hit = pool
            .filter { bands.contains($0.rarity) }
            .reduce(0.0) { $0 + Double(max($1.captureRate, 1)) }
        return hit / total
    }

    /// Expected Dust from one egg of `tier`, assuming the sprite is a duplicate.
    private func expectedDust(_ tier: EggTier) -> Double {
        let pool = dex.hatchPool(for: tier)
        let total = pool.reduce(0.0) { $0 + Double(max($1.captureRate, 1)) }
        return pool.reduce(0.0) {
            $0 + Double(max($1.captureRate, 1)) * Double(Prices.dust(forCaptureRate: $1.captureRate))
        } / total
    }

    /// **Every tier must be the cheapest route to its own promise**, or it is a
    /// trap: it still sells, it just quietly costs more than spamming the egg
    /// below it, which can also produce the same thing because the pools nest.
    ///
    /// This is the inequality the ladder was priced against, restated against the
    /// live manifest rather than against the numbers in the comment, so moving a
    /// price or a pool fails here instead of in a month of play.
    func testEachEggTierIsTheCheapestRouteToItsOwnPromise() {
        let top: Set<Rarity> = [.legendary, .mythical]
        let myth: Set<Rarity> = [.mythical]

        // A legendary. The plain Egg and the Great Egg both roll for one; the
        // Ultra Egg simply hands one over.
        let eggPerLegendary = Double(Prices.egg) / chance(.egg, of: top)
        let greatPerLegendary = Double(Prices.greatEgg) / chance(.great, of: top)
        XCTAssertEqual(chance(.ultra, of: top), 1, accuracy: 1e-12, "Ultra must guarantee it")
        XCTAssertLessThan(greatPerLegendary, eggPerLegendary, "the Great Egg is a worse Egg")
        XCTAssertLessThan(
            Double(Prices.ultraEgg), greatPerLegendary, "the Ultra Egg is a worse Great Egg")

        // A mythical. Same shape one rung up.
        let eggPerMythical = Double(Prices.egg) / chance(.egg, of: myth)
        let greatPerMythical = Double(Prices.greatEgg) / chance(.great, of: myth)
        let ultraPerMythical = Double(Prices.ultraEgg) / chance(.ultra, of: myth)
        XCTAssertEqual(chance(.master, of: myth), 1, accuracy: 1e-12, "Master must guarantee it")
        XCTAssertLessThan(greatPerMythical, eggPerMythical)
        XCTAssertLessThan(ultraPerMythical, greatPerMythical)
        XCTAssertLessThan(
            Double(Prices.masterEgg), ultraPerMythical, "the Master Egg is a worse Ultra Egg")

        // And prices rise with the tier, which the two chains above do not imply
        // on their own.
        let prices = EggTier.allCases.map(\.priceInCoins)
        XCTAssertEqual(prices, prices.sorted(), "\(prices)")
    }

    /// Coins per Dust, which the ladder no longer keeps in order.
    private func coinsPerDust(_ tier: EggTier) -> Double {
        Double(tier.priceInCoins) / expectedDust(tier)
    }

    /// **The Great Egg is the cheapest source of Dust, deliberately, and it is
    /// the only tier allowed to be.**
    ///
    /// The clean rule was "the plain Egg is always the cheapest Dust", because
    /// Dust pays on the raw capture rate and higher tiers are full of
    /// capture-rate-3 species: expected Dust per duplicate runs 1.97, 7.51, 16.90,
    /// 25.75 up the ladder. Pricing a tier under the plain Egg's coins-per-Dust
    /// turns the shop into a Dust mint, and coins must not convert into Dust:
    /// coins accrue passively and buy volume, Dust comes only from duplicates and
    /// buys choice. Same family as invariant 17.
    ///
    /// **The user broke it on purpose, tuning for fun**, and the reasoning is that
    /// the magnitude is small where the principle is loud: coins already converted
    /// through plain eggs, so the Great Egg at 600 makes an existing rate 27%
    /// better rather than opening a new door.
    ///
    /// So this pins the *bound* rather than the ordering, which is the thing still
    /// worth defending. Two halves: nothing but the Great Egg may invert, and its
    /// advantage stays modest. At 400 the ratio is 1.9x and that genuinely is a
    /// mint, so the cap is what stops the next tune going too far.
    func testOnlyTheGreatEggUndercutsThePlainEggOnDust() {
        let egg = coinsPerDust(.egg)
        let great = coinsPerDust(.great)

        XCTAssertLessThan(great, egg, "the recorded exception is gone; update DECISIONS.md")
        XCTAssertLessThan(
            egg / great, 1.5,
            "the Great Egg is now a Dust mint rather than a discount")

        // Ultra and Master must stay strictly worse than both cheaper eggs. These
        // are the ones that would actually print, at ~17 and ~26 Dust a hatch.
        for tier in [EggTier.ultra, .master] {
            XCTAssertGreaterThan(coinsPerDust(tier), egg, "\(tier) undercuts the Egg")
            XCTAssertGreaterThan(coinsPerDust(tier), great, "\(tier) undercuts the Great Egg")
        }
        XCTAssertGreaterThan(
            coinsPerDust(.master), coinsPerDust(.ultra), "the top two are out of order")
    }

    /// A tier charges its own price and draws only from its own pool. The Master
    /// Egg is the one worth exercising: the pool is 22 entries and the promise is
    /// absolute, so a wrong pool is visible in one hatch.
    func testHatchingATierChargesItsPriceAndHonoursItsPool() throws {
        var trainer = Trainer()
        XCTAssertThrowsError(
            try trainer.hatch(tier: .master, coinsEarned: 100, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(
                error as? Trainer.GameError,
                .notEnoughCoins(needed: Prices.masterEgg, have: 100))
        }

        for _ in 0..<12 {
            let before = trainer.log.events.count
            _ = try trainer.hatch(
                tier: .master, coinsEarned: 10_000_000, dex: dex, using: &rng)
            let event = try XCTUnwrap(trainer.log.events.last)
            XCTAssertEqual(trainer.log.events.count, before + 1)
            let entry = try XCTUnwrap(dex.entry(id: event.entryID))
            XCTAssertTrue(entry.mythical, "a Master Egg produced \(entry.slug)")
            // Still an egg, so a duplicate still pays. Invariant 17 keys on the
            // source, and every tier shares it.
            XCTAssertEqual(event.source, .hatch)
        }
        XCTAssertEqual(trainer.coinsSpent, Prices.masterEgg * 12)

        for _ in 0..<12 {
            _ = try trainer.hatch(tier: .ultra, coinsEarned: 10_000_000, dex: dex, using: &rng)
            let entry = try XCTUnwrap(dex.entry(id: try XCTUnwrap(trainer.log.events.last).entryID))
            XCTAssertTrue(
                entry.legendary || entry.mythical, "an Ultra Egg produced \(entry.slug)")
        }
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
        let before = try XCTUnwrap(trainer.lead)
        XCTAssertGreaterThan(before.level, 1)

        _ = try trainer.hatch(coinsEarned: 10_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.lead, before, "a hatch stole the raise")
        XCTAssertEqual(trainer.team.count, 2, "and it filled the next empty slot")

        // Re-roll the species being raised, which is the worst case: same entry,
        // so a careless implementation would overwrite the individual.
        trainer.dust = 1_000
        _ = try trainer.reroll(entryID: before.entryID, dex: dex, using: &rng)
        XCTAssertEqual(trainer.lead, before, "a re-roll stole the raise")

        _ = try trainer.targetedPick(entryID: try entry("mewtwo").id, dex: dex)
        XCTAssertEqual(trainer.lead, before, "a targeted pick stole the raise")

        // And the XP is genuinely still there, not merely an equal-looking Raise.
        XCTAssertEqual(trainer.lead?.totalXP, before.totalXP)
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

            XCTAssertEqual(trainer.lead?.entryID, start.id, "\(slug) must not auto-evolve")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(trainer.lead?.level), level)

            // Both remain reachable by raising, which is the point.
            try trainer.evolve(leadID(trainer), into: try entry(early).id, dex: dex)
            XCTAssertEqual(trainer.lead?.entryID, try entry(early).id)

            var second = try raising(slug)
            second.credit(weightedTokens: 1e12, dex: dex)
            try second.evolve(leadID(second), into: try entry(late).id, dex: dex)
            XCTAssertEqual(second.lead?.entryID, try entry(late).id)
        }
    }

    func testChoosingAStarterIsFreeAndStartsTheRaise() throws {
        var trainer = Trainer()
        XCTAssertTrue(trainer.needsStarter)

        let squirtle = try entry("squirtle")
        let events = try trainer.chooseStarter(entryID: squirtle.id, dex: dex, using: &rng)

        XCTAssertEqual(trainer.coinsSpent, 0, "the first pick costs nothing")
        XCTAssertEqual(trainer.lead?.entryID, squirtle.id)
        XCTAssertEqual(trainer.lead?.level, 1)
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

    /// **The whole of step 1, in one assertion.** Raise something a long way,
    /// switch to something else, come back: it is exactly where it was left.
    ///
    /// v1 built a brand new `Raise` at level 1 on every switch and dropped the
    /// old one on the floor, which is recorded in DECISIONS.md as the cost of
    /// switching and is the thing the user asked to have back: "I shouldn't lose
    /// my progress on Charizard if I want to switch out to another pokemon for a
    /// week."
    func testLevelsSurviveASwitchAndComeBack() throws {
        var trainer = try raising("bulbasaur")
        // Straight to a Venusaur, which is also the interesting case: the
        // individual's own `entryID` moved twice on the way.
        trainer.credit(weightedTokens: 1e9, dex: dex)
        let grown = try XCTUnwrap(trainer.lead)
        XCTAssertEqual(grown.level, 100)
        XCTAssertEqual(grown.entryID, try entry("venusaur").id)

        // Bench it and raise something else, which is the whole scenario.
        XCTAssertTrue(trainer.removeFromTeam(raiseID: grown.id))
        let pikachu = try entry("pikachu")
        trainer.log.append(CatchEvent(
            entryID: pikachu.id, variant: .normal, gender: .male, source: .hatch))
        addMember(to: &trainer, entryID: pikachu.id)
        XCTAssertEqual(trainer.lead?.entryID, pikachu.id)
        XCTAssertEqual(trainer.lead?.level, 1, "a new individual starts at 1")
        XCTAssertEqual(trainer.coinsSpent, 0, "switching is still free")

        // Nothing was deleted, and the levels are on the individual rather than
        // on the slot it happens to occupy.
        XCTAssertEqual(trainer.roster.count, 2)
        XCTAssertEqual(trainer.boxed.map(\.id), [grown.id])
        XCTAssertEqual(trainer.raise(id: grown.id)?.totalXP, grown.totalXP)

        // Through the Dex path the player would actually use: the tile offers the
        // benched individual by name, and adding it resumes rather than restarts.
        let offered = trainer.dexOptions(entryID: try entry("venusaur").id, dex: dex)
        XCTAssertEqual(offered.resumable.map(\.id), [grown.id])
        XCTAssertEqual(offered.resumable.first?.level, 100)
        try trainer.addToTeam(raiseID: try XCTUnwrap(offered.resumable.first).id)
        XCTAssertEqual(trainer.raise(id: grown.id)?.level, 100, "still where it was left")
        XCTAssertEqual(trainer.team.count, 2, "and back to work beside the Pikachu")
        XCTAssertEqual(trainer.roster.count, 2, "coming back creates nobody")

        try trainer.promoteToLead(raiseID: grown.id)
        XCTAssertEqual(trainer.lead?.id, grown.id, "the same individual, not a copy")
    }

    /// The Dex tile is keyed by **entry** while the roster is keyed by individual,
    /// so the tile has to offer the individuals by name. Best first, because
    /// "bring back my Pikachu" means the level 20 one.
    func testTheDexOffersBenchedIndividualsBestFirst() throws {
        var trainer = try raising("pikachu")
        let pikachu = try entry("pikachu")
        let first = try XCTUnwrap(trainer.lead)
        trainer.credit(weightedTokens: 40_000 * XPCurve.weightedTokensPerXP, dex: dex)

        // A second Pikachu, started from scratch and left at level 1.
        let second = addMember(to: &trainer, entryID: pikachu.id)
        XCTAssertEqual(trainer.roster.count, 2)
        XCTAssertEqual(trainer.team.count, 2, "an acquisition fills an empty slot")

        XCTAssertEqual(
            trainer.dexOptions(entryID: pikachu.id, dex: dex).onTeam, 2,
            "both are training, so there is nobody to bring back")
        XCTAssertTrue(trainer.dexOptions(entryID: pikachu.id, dex: dex).resumable.isEmpty)

        trainer.removeFromTeam(raiseID: first.id)
        trainer.removeFromTeam(raiseID: second)
        let options = trainer.dexOptions(entryID: pikachu.id, dex: dex)

        XCTAssertEqual(options.resumable.map(\.id), [first.id, second], "best first")
        XCTAssertEqual(options.resumable.first?.level, 20)
        XCTAssertEqual(options.resumable.last?.level, 1)
        XCTAssertEqual(options.onTeam, 0)
    }

    /// What is left to collect, counted against the sprites that exist rather
    /// than an assumed four (invariant 18). It does **not** gate the offer: a
    /// completed entry is still worth an egg, because a graduated individual earns
    /// nothing and a level 1 does. It only decides what the note may promise.
    func testMissingVariantsCountsUncollectedSpritesWithoutGatingTheOffer() throws {
        var trainer = try raising("charmander")
        let charmander = try entry("charmander")
        XCTAssertEqual(charmander.ownableVariants.count, 2, "normal and shiny, no female sprite")

        let partway = trainer.dexOptions(entryID: charmander.id, dex: dex)
        XCTAssertEqual(partway.missingVariants, 1, "the shiny is still out there")

        let gender = HatchRoll.canonicalGender(for: charmander)
        trainer.log.append(CatchEvent(
            entryID: charmander.id, variant: gender.spriteVariant(shiny: true, for: charmander),
            gender: gender, source: .hatch))

        let complete = trainer.dexOptions(entryID: charmander.id, dex: dex)
        XCTAssertEqual(complete.missingVariants, 0)
        XCTAssertNotNil(
            complete.hatchAnother, "a complete entry can still be hatched, for a level 1 to raise")
    }

    /// **Nothing conjures a Pokemon out of nothing.** The Dex offers individuals
    /// that exist, and a brand new one has to be hatched, at a price, and only at
    /// the bottom of its line.
    func testOnlyABaseFormCanBeHatchedAgain() throws {
        var trainer = try raising("charmander")
        let charmander = try entry("charmander")
        let charmeleon = try entry("charmeleon")

        // Raise it into a Charizard, so all three sprites are owned and the
        // individual that was a Charmander no longer is one.
        trainer.credit(weightedTokens: 1e9, dex: dex)
        XCTAssertEqual(trainer.lead?.entryID, try entry("charizard").id)

        let base = trainer.dexOptions(entryID: charmander.id, dex: dex)
        XCTAssertEqual(base.hatchAnother?.coins, Prices.hatchAnotherCoins)
        XCTAssertEqual(base.hatchAnother?.dust, Prices.hatchAnother(charmander.rarity))
        XCTAssertNil(base.baseFormID, "a Charmander is already the bottom of the line")
        XCTAssertTrue(base.resumable.isEmpty, "the Charmander became the Charizard")

        let middle = trainer.dexOptions(entryID: charmeleon.id, dex: dex)
        XCTAssertNil(middle.hatchAnother, "a Charmeleon is a Charmander that grew")
        XCTAssertEqual(middle.baseFormID, charmander.id, "and this is what to hatch instead")

        XCTAssertThrowsError(
            try trainer.hatchAnother(
                entryID: charmeleon.id, paying: .coins, coinsEarned: 100_000, dex: dex,
                using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notABaseForm(charmeleon.id))
        }
    }

    /// Two currencies, and they curve differently on purpose: Dust is priced on
    /// the band so a common is cheap, coins are flat so a legendary is reachable.
    func testHatchingAnotherTakesEitherCurrency() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        let before = trainer.roster.count

        try trainer.hatchAnother(
            entryID: lapras.id, paying: .coins, coinsEarned: 100_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.coinsSpent, Prices.hatchAnotherCoins)
        XCTAssertEqual(trainer.roster.count, before + 1, "a second individual")
        XCTAssertEqual(trainer.team.count, 2, "and it filled the empty slot")
        XCTAssertEqual(trainer.dust, 0, "a bought duplicate mints no Dust, per invariant 17")

        trainer.dust = 500
        try trainer.hatchAnother(
            entryID: lapras.id, paying: .dust, coinsEarned: 100_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.dust, 500 - Prices.hatchAnother(lapras.rarity))
        XCTAssertEqual(trainer.coinsSpent, Prices.hatchAnotherCoins, "and no coins that time")
        XCTAssertEqual(trainer.roster.count, before + 2)

        // The log can still say which purchase each one was.
        XCTAssertEqual(trainer.log.events.filter { $0.source == .another }.count, 2)
    }

    func testHatchingAnotherRefusesWhatIsNotOwnedOrNotAffordable() throws {
        var trainer = try raising("lapras")
        let mew = try entry("mew")
        XCTAssertThrowsError(
            try trainer.hatchAnother(
                entryID: mew.id, paying: .coins, coinsEarned: 100_000, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notOwned)
        }

        let lapras = try entry("lapras")
        XCTAssertThrowsError(
            try trainer.hatchAnother(
                entryID: lapras.id, paying: .coins, coinsEarned: 100, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(
                error as? Trainer.GameError,
                .notEnoughCoins(needed: Prices.hatchAnotherCoins, have: 100))
        }
        XCTAssertThrowsError(
            try trainer.hatchAnother(
                entryID: lapras.id, paying: .dust, coinsEarned: 100_000, dex: dex, using: &rng)
        ) { error in
            XCTAssertEqual(
                error as? Trainer.GameError,
                .notEnoughDust(needed: Prices.hatchAnother(lapras.rarity), have: 0))
        }
        XCTAssertEqual(trainer.roster.count, 1, "and no refusal created anybody")
    }

    /// Dragging one card onto another exchanges their slots. Swap rather than
    /// insert-and-shift, so dropping onto the lead promotes exactly one Pokemon
    /// and demotes exactly one.
    func testSwappingExchangesTwoSlots() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        let first = try XCTUnwrap(trainer.lead).id
        let second = addMember(to: &trainer, entryID: lapras.id)
        let third = addMember(to: &trainer, entryID: lapras.id)

        try trainer.swapSlots(third, first)
        XCTAssertEqual(trainer.team, [third, second, first], "two moved, nobody shifted")

        try trainer.swapSlots(third, third)
        XCTAssertEqual(trainer.team, [third, second, first], "swapping with itself is inert")

        trainer.removeFromTeam(raiseID: second)
        XCTAssertThrowsError(try trainer.swapSlots(third, second)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .unknownIndividual(second))
        }
        XCTAssertEqual(trainer.team, [third, first], "and a refused swap changes nothing")
    }

    /// **An acquisition fills an empty slot.** Hatching an egg into a team with
    /// room and watching nothing happen is the confusion this fixes, caught by
    /// the user on the day the team shipped.
    func testAnAcquisitionFillsAnEmptySlotAndThenTheBench() throws {
        var trainer = Trainer()
        _ = try trainer.chooseStarter(
            entryID: try entry("squirtle").id, dex: dex, using: &rng)
        XCTAssertEqual(trainer.team.count, 1, "the first pick starts training itself")

        for _ in 1..<Trainer.teamCapacity {
            _ = try trainer.hatch(coinsEarned: 100_000, dex: dex, using: &rng)
        }
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity, "every hatch took a slot")

        _ = try trainer.hatch(coinsEarned: 100_000, dex: dex, using: &rng)
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity, "and then they stop")
        XCTAssertEqual(trainer.boxed.count, 1, "the seventh waits on the bench")
        XCTAssertEqual(trainer.roster.count, Trainer.teamCapacity + 1)
    }

    /// Slots 2 to 6 all take the same share, so their order is cosmetic and the
    /// only reorder worth a control is "make this one the lead".
    func testPromotingMovesAMemberToSlotOne() throws {
        var trainer = try raising("pikachu")
        let squirtle = try entry("squirtle")
        trainer.log.append(CatchEvent(
            entryID: squirtle.id, variant: .normal, gender: .male, source: .hatch))
        let second = addMember(to: &trainer, entryID: squirtle.id)
        let third = addMember(to: &trainer, entryID: squirtle.id)
        let first = try XCTUnwrap(trainer.lead).id

        try trainer.promoteToLead(raiseID: third)

        XCTAssertEqual(trainer.team, [third, first, second], "promoted, and nobody dropped")
        XCTAssertEqual(trainer.lead?.id, third)
        try trainer.promoteToLead(raiseID: third)
        XCTAssertEqual(trainer.team.first, third, "promoting the lead is a no-op")

        let stranger = UUID()
        XCTAssertThrowsError(try trainer.promoteToLead(raiseID: stranger)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .unknownIndividual(stranger))
        }
        // A benched Pokemon has no slot to be promoted within: it has to be brought
        // back first, which is a different verb and a deliberate one.
        trainer.removeFromTeam(raiseID: second)
        XCTAssertThrowsError(try trainer.promoteToLead(raiseID: second)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .unknownIndividual(second))
        }
        XCTAssertEqual(trainer.team, [third, first])
    }

    /// A refused switch must leave the team alone. Emptying it and then throwing
    /// would stop XP accruing with nothing on screen to say why.
    func testCannotRaiseSomethingNotOwnedAndARefusalChangesNothing() throws {
        var trainer = try raising("bulbasaur")
        let before = trainer
        XCTAssertThrowsError(
            try trainer.hatchAnother(
                entryID: try entry("mew").id, paying: .coins, coinsEarned: 100_000, dex: dex,
                using: &rng)
        ) { error in
            XCTAssertEqual(error as? Trainer.GameError, .notOwned)
        }
        XCTAssertEqual(trainer, before, "a refused purchase changes nothing at all")
    }

    // MARK: - The roster and the team

    func testBenchingKeepsTheIndividualAndItsLevels() throws {
        var trainer = try raising("squirtle")
        trainer.credit(weightedTokens: 40_000 * XPCurve.weightedTokensPerXP, dex: dex)
        let raise = try XCTUnwrap(trainer.lead)

        XCTAssertTrue(trainer.removeFromTeam(raiseID: raise.id))
        XCTAssertNil(trainer.lead, "nothing is training")
        XCTAssertEqual(trainer.roster.count, 1, "and nothing was deleted")
        XCTAssertEqual(trainer.boxed.first?.totalXP, raise.totalXP)
        XCTAssertFalse(
            trainer.removeFromTeam(raiseID: raise.id), "benching twice is not an error")

        // Crediting with an empty team is a no-op, not a crash: coins still
        // accrue, which is correct for a busy machine with nothing to raise.
        XCTAssertTrue(trainer.credit(weightedTokens: 1e9, dex: dex).isEmpty)
        XCTAssertEqual(trainer.boxed.first?.totalXP, raise.totalXP, "the bench earns nothing")

        try trainer.addToTeam(raiseID: raise.id)
        XCTAssertEqual(trainer.lead?.id, raise.id)
        XCTAssertEqual(trainer.lead?.totalXP, raise.totalXP)
    }

    func testTheTeamIsCappedAtSix() throws {
        var trainer = try raising("pikachu")
        let pikachu = try entry("pikachu")
        for _ in 1..<Trainer.teamCapacity {
            addMember(to: &trainer, entryID: pikachu.id)
        }
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity)

        // A seventh acquisition is not refused, it lands on the bench. Refusing
        // it would mean an egg you paid for producing nothing at all.
        let seventh = addMember(to: &trainer, entryID: pikachu.id)
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity, "still six training")
        XCTAssertEqual(trainer.roster.count, Trainer.teamCapacity + 1)
        XCTAssertEqual(trainer.boxed.map(\.id), [seventh])

        XCTAssertThrowsError(try trainer.addToTeam(raiseID: seventh)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .teamFull)
        }
        XCTAssertFalse(trainer.dexOptions(entryID: pikachu.id, dex: dex).teamHasRoom)

        // Benching one is the way through, and it costs nothing.
        let benched = try XCTUnwrap(trainer.teamRaises.last).id
        XCTAssertTrue(trainer.removeFromTeam(raiseID: benched))
        XCTAssertTrue(trainer.dexOptions(entryID: pikachu.id, dex: dex).teamHasRoom)
        try trainer.addToTeam(raiseID: seventh)
        XCTAssertEqual(trainer.team.count, Trainer.teamCapacity)
    }

    func testAddingToTheTeamRefusesStrangersAndRepeats() throws {
        var trainer = try raising("squirtle")
        let raise = try XCTUnwrap(trainer.lead)

        XCTAssertThrowsError(try trainer.addToTeam(raiseID: raise.id)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .alreadyOnTeam)
        }
        let stranger = UUID()
        XCTAssertThrowsError(try trainer.addToTeam(raiseID: stranger)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .unknownIndividual(stranger))
        }
        XCTAssertEqual(trainer.team.count, 1)
    }

    // MARK: - The team gains XP together

    /// A full team of six, and a credit that is **multiplied rather than
    /// divided**: the lead takes all of it and each of the five party slots takes
    /// 0.8 of the same credit. 5.0x in total.
    ///
    /// Lapras throughout, because it never evolves, so the XP arithmetic is the
    /// only thing this test can fail on.
    func testAFullTeamAbsorbsFiveTimesOneCredit() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        for _ in 1..<Trainer.teamCapacity {
            addMember(to: &trainer, entryID: lapras.id)
        }
        let baseline = Double(XPCurve.totalXP(forLevel: 1))
        let credit = 5_000.0

        trainer.credit(weightedTokens: credit * XPCurve.weightedTokensPerXP, dex: dex)

        let gained = trainer.teamRaises.map { $0.totalXP - baseline }
        XCTAssertEqual(gained.first, credit * XPCurve.leadShare, "slot 1 takes all of it")
        for bench in gained.dropFirst() {
            XCTAssertEqual(bench, credit * XPCurve.partyShare, "and so does every party slot")
        }
        XCTAssertEqual(
            gained.reduce(0, +),
            credit * (XPCurve.leadShare + 5 * XPCurve.partyShare), accuracy: 0.000_1)
        XCTAssertEqual(gained.reduce(0, +) / credit, 5.0, accuracy: 0.000_1)
    }

    /// The ramp is per *occupied* slot, so a team of two is 1.8x rather than a
    /// jump to 5x. Nothing about the lead's own rate changes as the team fills.
    func testTheRampIsSmoothPerOccupiedSlot() throws {
        let lapras = try entry("lapras")
        let credit = 1_000.0
        let baseline = Double(XPCurve.totalXP(forLevel: 1))

        for size in 1...Trainer.teamCapacity {
            var trainer = try raising("lapras")
            for _ in 1..<size { addMember(to: &trainer, entryID: lapras.id) }
            trainer.credit(weightedTokens: credit * XPCurve.weightedTokensPerXP, dex: dex)

            let total = trainer.teamRaises.map { $0.totalXP - baseline }.reduce(0, +)
            let expected = credit * (XPCurve.leadShare + Double(size - 1) * XPCurve.partyShare)
            XCTAssertEqual(total, expected, accuracy: 0.000_1, "team of \(size)")
            XCTAssertEqual(
                trainer.lead?.totalXP, baseline + credit, "the lead's rate never moves")
        }
    }

    /// **The whole v1 economy, unchanged.** One Pokemon in the team must behave
    /// exactly as it did before any of this existed: same XP, same level, same
    /// event. Everything else in this file is measured against that.
    func testATeamOfOneBehavesExactlyAsBefore() throws {
        var trainer = try raising("bulbasaur")
        let raise = try XCTUnwrap(trainer.lead)
        let events = trainer.credit(
            weightedTokens: 25_500 * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(trainer.lead?.totalXP, 25_600)
        XCTAssertEqual(trainer.lead?.level, 16)
        XCTAssertTrue(
            events.contains(
                .levelledUp(raiseID: raise.id, entryID: try entry("ivysaur").id, to: 16)))
    }

    /// **A capped member's share is not redistributed.** Redistribution would
    /// quietly change what the lead slot means the moment it graduates. The
    /// answer is to tell the player their team is wasting a share, not to
    /// compensate for it silently.
    func testAGraduatedMemberAbsorbsNothingAndFeedsNobody() throws {
        var trainer = try raising("lapras")
        let graduate = try XCTUnwrap(trainer.lead)
        trainer.credit(weightedTokens: 1e12, dex: dex)
        XCTAssertEqual(trainer.raise(id: graduate.id)?.level, XPCurve.maxLevel)
        let ceiling = Double(XPCurve.totalXP(forLevel: XPCurve.maxLevel))

        let climber = addMember(to: &trainer, entryID: try entry("lapras").id)
        let baseline = try XCTUnwrap(trainer.raise(id: climber)).totalXP
        let credit = 2_000.0
        trainer.credit(weightedTokens: credit * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(
            trainer.raise(id: graduate.id)?.totalXP, ceiling, "capped, and clamped there")
        XCTAssertEqual(
            trainer.raise(id: climber)?.totalXP, baseline + credit * XPCurve.partyShare,
            "the party slot got its own share and not a share of the waste")
    }

    /// Six members can each be waiting on their own decision after one credit,
    /// which one active Pokemon could never produce. Each event has to say who it
    /// is about, or the player cannot be asked.
    func testTwoMembersCanHoldDistinctPendingChoices() throws {
        var trainer = try raising("eevee")
        let eevee = try entry("eevee"), wurmple = try entry("wurmple")
        let first = try XCTUnwrap(trainer.lead)
        trainer.log.append(CatchEvent(
            entryID: wurmple.id, variant: .normal, gender: .male, source: .hatch))
        let second = addMember(to: &trainer, entryID: wurmple.id)

        let events = trainer.credit(
            weightedTokens: 200_000 * XPCurve.weightedTokensPerXP, dex: dex)

        let choices = events.compactMap { event -> (UUID, Int)? in
            if case .evolutionChoice(let raiseID, let from, _) = event { (raiseID, from) } else { nil }
        }
        XCTAssertEqual(
            Set(choices.map(\.0)), [first.id, second], "one choice each, named individually")
        XCTAssertEqual(Set(choices.map(\.1)), [eevee.id, wurmple.id])
        XCTAssertEqual(trainer.teamPendingEvolutions(dex: dex).count, 2)

        // And the player can settle one without touching the other.
        _ = try trainer.evolve(second, into: 266, dex: dex)
        XCTAssertEqual(
            trainer.raise(id: second)?.entryID, 267,
            "Silcoon, then straight on to Beautifly: the chain still runs, per member")
        XCTAssertEqual(trainer.raise(id: first.id)?.entryID, eevee.id, "still waiting")
    }

    /// Milestones are written against the individual that crossed the line, so
    /// two members reaching 50 in one credit are two records and not one.
    func testMilestonesLandAgainstTheRightIndividual() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        let first = try XCTUnwrap(trainer.lead)
        let second = addMember(to: &trainer, entryID: lapras.id)

        // Enough that even the 0.8 share clears level 50 (250,000 XP).
        trainer.credit(weightedTokens: 400_000 * XPCurve.weightedTokensPerXP, dex: dex)

        let atFifty = trainer.log.milestones.filter { $0.level == 50 }
        XCTAssertEqual(Set(atFifty.map(\.raiseID)), [first.id, second])
        XCTAssertEqual(atFifty.count, 2, "two individuals, two records")
        XCTAssertEqual(trainer.log.milestone(entryID: lapras.id), 50)
    }

    // MARK: - The Exp Share

    /// **It boosts, it never splits.** With the item on, every party slot earns at
    /// the lead's rate, so a full team goes from 5.0x to 6.0x. The rejected
    /// reading, one credit divided six ways, would have made a 10,000 coin
    /// purchase a *downgrade* from the free default.
    func testTheExpShareTakesAFullTeamFromFiveToSix() throws {
        let lapras = try entry("lapras")
        let credit = 1_000.0
        let baseline = Double(XPCurve.totalXP(forLevel: 1))

        func totalGained(expShare: Bool) throws -> Double {
            var trainer = try raising("lapras")
            for _ in 1..<Trainer.teamCapacity {
                addMember(to: &trainer, entryID: lapras.id)
            }
            if expShare { try trainer.buy(.expShare, coinsEarned: Prices.expShare) }
            trainer.credit(weightedTokens: credit * XPCurve.weightedTokensPerXP, dex: dex)
            XCTAssertEqual(trainer.lead?.totalXP, baseline + credit, "the lead is unaffected")
            return trainer.teamRaises.map { $0.totalXP - baseline }.reduce(0, +)
        }

        XCTAssertEqual(try totalGained(expShare: false) / credit, 5.0, accuracy: 0.000_1)
        XCTAssertEqual(try totalGained(expShare: true) / credit, 6.0, accuracy: 0.000_1)
    }

    /// Every slot at the same rate, not just a bigger total: a bench Pokemon with
    /// the item on climbs exactly as fast as the one in front of it.
    func testWithTheExpShareEveryMemberEarnsTheSameXP() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        addMember(to: &trainer, entryID: lapras.id)
        addMember(to: &trainer, entryID: lapras.id)
        try trainer.buy(.expShare, coinsEarned: Prices.expShare)

        trainer.credit(weightedTokens: 1_000 * XPCurve.weightedTokensPerXP, dex: dex)

        XCTAssertEqual(Set(trainer.teamRaises.map(\.totalXP)).count, 1, "one figure, three slots")
    }

    /// Bought once, and it costs coins like anything else.
    func testTheExpShareIsBoughtOnceAndCostsTenThousand() throws {
        var trainer = Trainer()
        XCTAssertEqual(Trainer.ShopItem.expShare.priceInCoins, 10_000)
        XCTAssertFalse(trainer.hasExpShare)

        XCTAssertThrowsError(try trainer.buy(.expShare, coinsEarned: 9_999)) { error in
            XCTAssertEqual(
                error as? Trainer.GameError, .notEnoughCoins(needed: 10_000, have: 9_999))
        }

        try trainer.buy(.expShare, coinsEarned: 10_000)
        XCTAssertTrue(trainer.hasExpShare)
        XCTAssertTrue(trainer.expShareEnabled, "buying it turns it on")
        XCTAssertEqual(trainer.coinsSpent, 10_000)
        XCTAssertEqual(trainer.coins(earned: 10_000), 0)

        XCTAssertThrowsError(try trainer.buy(.expShare, coinsEarned: 100_000)) { error in
            XCTAssertEqual(error as? Trainer.GameError, .alreadyOwned)
        }
        XCTAssertEqual(trainer.coinsSpent, 10_000, "a refused purchase spends nothing")
    }

    /// The toggle is free, reversible, and does nothing at all until the item is
    /// owned. A throw here would only ever fire on a bug, because the control does
    /// not exist until it is bought.
    func testTheToggleIsInertUntilItIsBought() throws {
        var trainer = try raising("lapras")
        trainer.setExpShare(true)
        XCTAssertFalse(trainer.expShareEnabled, "not owned, so nothing happened")
        XCTAssertFalse(trainer.expShareActive)

        try trainer.buy(.expShare, coinsEarned: 10_000)
        XCTAssertTrue(trainer.expShareActive)

        trainer.setExpShare(false)
        XCTAssertTrue(trainer.hasExpShare, "turning it off does not sell it back")
        XCTAssertFalse(trainer.expShareActive)
        XCTAssertEqual(trainer.coinsSpent, 10_000, "and the toggle is free both ways")

        // Off means back to 0.8, not off entirely.
        let bench = addMember(to: &trainer, entryID: try entry("lapras").id)
        let baseline = Double(XPCurve.totalXP(forLevel: 1))
        trainer.credit(weightedTokens: 1_000 * XPCurve.weightedTokensPerXP, dex: dex)
        XCTAssertEqual(
            trainer.raise(id: bench)?.totalXP, baseline + 1_000 * XPCurve.partyShare)
    }

    // MARK: - Where the XP came from

    /// The plan's test: attribution across two projects sums to what was
    /// credited, so the line under a Pokemon is a real breakdown and not a
    /// second, drifting tally.
    func testProjectAttributionSumsToTheXPCredited() throws {
        var trainer = try raising("lapras")
        let lead = try XCTUnwrap(trainer.lead)
        let pokebar = "/Users/a/Code/PokeBar", other = "/Users/a/Code/hue-scenes"

        trainer.credit(
            weightedTokens: 1_000 * XPCurve.weightedTokensPerXP,
            byProject: [
                pokebar: 600 * XPCurve.weightedTokensPerXP,
                other: 400 * XPCurve.weightedTokensPerXP,
            ],
            dex: dex)

        let raised = try XCTUnwrap(trainer.raise(id: lead.id))
        XCTAssertEqual(raised.xpByProject[pokebar], 600)
        XCTAssertEqual(raised.xpByProject[other], 400)
        XCTAssertEqual(
            raised.xpByProject.values.reduce(0, +),
            raised.totalXP - Double(XPCurve.totalXP(forLevel: 1)), accuracy: 0.000_1)
    }

    /// Each member's share applies to the split exactly as it applies to the
    /// total, so the answer is at the same resolution for a bench slot.
    func testEachTeamMemberRecordsItsOwnShareOfEachProject() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        let lead = try XCTUnwrap(trainer.lead).id
        let second = addMember(to: &trainer, entryID: lapras.id)
        let project = "/Users/a/Code/PokeBar"

        trainer.credit(
            weightedTokens: 1_000 * XPCurve.weightedTokensPerXP,
            byProject: [project: 1_000 * XPCurve.weightedTokensPerXP], dex: dex)

        XCTAssertEqual(trainer.raise(id: lead)?.xpByProject[project], 1_000)
        XCTAssertEqual(
            trainer.raise(id: second)?.xpByProject[project], 1_000 * XPCurve.partyShare)
    }

    /// A member that hits the ceiling part-way through a credit must not record
    /// more project XP than it actually earned.
    func testACappedMemberAttributesOnlyWhatItGained() throws {
        var trainer = try raising("lapras")
        let lead = try XCTUnwrap(trainer.lead).id
        let project = "/Users/a/Code/PokeBar"
        trainer.credit(weightedTokens: 1e12, byProject: [project: 1e12], dex: dex)
        let atCeiling = try XCTUnwrap(trainer.raise(id: lead)).xpByProject[project]

        trainer.credit(weightedTokens: 1e9, byProject: [project: 1e9], dex: dex)

        XCTAssertEqual(trainer.raise(id: lead)?.xpByProject[project], atCeiling, "nothing more")
        XCTAssertEqual(
            try XCTUnwrap(atCeiling), 1_000_000 - 100, accuracy: 1,
            "and never more than the climb was worth")
    }

    /// Rare Candy is bought, not earned anywhere, so it attributes to nothing.
    func testRareCandyAttributesToNoProject() throws {
        var trainer = try raising("lapras")
        let lead = try XCTUnwrap(trainer.lead).id
        try trainer.buy(.rareCandy, coinsEarned: 1_000)

        try trainer.useRareCandy(on: lead, dex: dex)

        XCTAssertGreaterThan(try XCTUnwrap(trainer.raise(id: lead)).totalXP, 10_000)
        XCTAssertTrue(try XCTUnwrap(trainer.raise(id: lead)).xpByProject.isEmpty)
    }

    /// A new persisted field, so the usual rule: absent means empty, and a save
    /// written before it existed still loads.
    func testASaveWrittenBeforeProjectsStillLoads() throws {
        let json = """
            {"coinsSpent":0,"inventory":{},"hasShinyCharm":false,"dust":0,
             "log":{"events":[]},
             "roster":[{"originEntryID":25,"shiny":false,"totalXP":40100,
                        "gender":"male","id":"11111111-1111-1111-1111-111111111111",
                        "startedAt":809232069.327612,"entryID":25}],
             "team":["11111111-1111-1111-1111-111111111111"]}
            """
        let trainer = try JSONDecoder().decode(Trainer.self, from: Data(json.utf8))
        XCTAssertEqual(trainer.lead?.xpByProject, [:])
        XCTAssertEqual(trainer.lead?.totalXP, 40_100)
    }

    /// **Rare Candy feeds one Pokemon, not six.** Routing it through `credit`
    /// would hand 10,000 XP to the whole team for 250 coins, turning the game's
    /// one targeted item into the only sensible purchase in the shop.
    func testRareCandyFeedsOneMemberNotTheTeam() throws {
        var trainer = try raising("lapras")
        let lapras = try entry("lapras")
        let lead = try XCTUnwrap(trainer.lead)
        let bench = addMember(to: &trainer, entryID: lapras.id)
        let baseline = Double(XPCurve.totalXP(forLevel: 1))
        try trainer.buy(.rareCandy, coinsEarned: 1_000)

        try trainer.useRareCandy(on: leadID(trainer), dex: dex)

        XCTAssertEqual(trainer.raise(id: lead.id)?.totalXP, baseline + Prices.rareCandyXP)
        XCTAssertEqual(trainer.raise(id: bench)?.totalXP, baseline, "the bench got nothing")

        // And it can be aimed, which is what the step 4 picker will call.
        try trainer.buy(.rareCandy, coinsEarned: 1_000)
        try trainer.useRareCandy(on: bench, dex: dex)
        XCTAssertEqual(trainer.raise(id: bench)?.totalXP, baseline + Prices.rareCandyXP)
        XCTAssertEqual(trainer.count(ofItem: Trainer.rareCandySlug), 0)
    }

    /// Two individuals of one species are two individuals. Ownership is still per
    /// sprite and still the log's question, so a second Charmander fills nothing
    /// new and mints nothing.
    func testASecondIndividualOfOneSpeciesIsItsOwnRaise() throws {
        var trainer = try raising("charmander")
        let charmander = try entry("charmander")
        let first = try XCTUnwrap(trainer.lead)
        // Short of level 16, so it stays a Charmander and the collection still
        // holds exactly one sprite.
        trainer.credit(weightedTokens: 10_000 * XPCurve.weightedTokensPerXP, dex: dex)

        let second = addMember(to: &trainer, entryID: charmander.id)

        XCTAssertNotEqual(second, first.id)
        XCTAssertEqual(trainer.raise(id: second)?.level, 1)
        XCTAssertGreaterThan(try XCTUnwrap(trainer.raise(id: first.id)).level, 1)
        XCTAssertEqual(trainer.log.completion(in: dex).filled, 1, "one sprite, still")
        XCTAssertEqual(trainer.dust, 0, "and no Dust: this is not a hatch")
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
