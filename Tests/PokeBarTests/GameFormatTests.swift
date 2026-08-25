import XCTest
@testable import PokeBar

/// Where the game UI's behaviour is pinned.
///
/// Views hold no logic in this project, so everything they render comes through
/// here and is asserted here. A fact decided inside a view body cannot be tested
/// in this toolchain.
final class GameFormatTests: XCTestCase {

    private var dex: Pokedex!

    override func setUpWithError() throws {
        dex = try Pokedex.loadBundled()
    }

    // MARK: Levels

    func testXPLineShowsProgressWithinTheLevel() {
        // Level 10 is 10,000 total; the next is 12,100.
        XCTAssertEqual(GameFormat.xpLine(totalXP: 10_000), "0 / 2,100 XP")
        XCTAssertEqual(GameFormat.xpLine(totalXP: 11_000), "1,000 / 2,100 XP")
    }

    func testXPLineAtTheCeilingSaysGraduated() {
        XCTAssertEqual(GameFormat.xpLine(totalXP: 1_000_000), "Graduated at level 100")
        XCTAssertEqual(GameFormat.levelProgress(totalXP: 1_000_000), 1)
    }

    func testLevelProgressStaysInRange() {
        for xp in stride(from: 0.0, through: 1_200_000, by: 4_321) {
            let fraction = GameFormat.levelProgress(totalXP: xp)
            XCTAssertTrue((0...1).contains(fraction), "\(xp) -> \(fraction)")
        }
    }

    /// A fresh install has no rate to project from, and "level 2 in 40 years" is
    /// worse than saying nothing.
    func testTimeToNextLevelIsNilWithoutARate() {
        XCTAssertNil(GameFormat.timeToNextLevel(totalXP: 100, weightedTokensPerDay: 0))
        XCTAssertNil(
            GameFormat.timeToNextLevel(totalXP: 1_000_000, weightedTokensPerDay: 1e8),
            "nothing comes after level 100")
    }

    /// At this machine's measured throughput the first level takes minutes and
    /// the last takes about two hours, which is the shape the curve was chosen
    /// for.
    func testTimeToNextLevelAtMeasuredThroughput() {
        let perDay = 108_000_000.0
        XCTAssertEqual(GameFormat.timeToNextLevel(totalXP: 100, weightedTokensPerDay: perDay), "2 min")
        XCTAssertEqual(
            GameFormat.timeToNextLevel(
                totalXP: Double(XPCurve.totalXP(forLevel: 99)), weightedTokensPerDay: perDay),
            "2.2 h")
    }

    func testDurationRoundsCoarsely() {
        XCTAssertEqual(GameFormat.duration(days: 0), "any moment")
        XCTAssertEqual(GameFormat.duration(days: 1.0 / 24 / 60 * 4), "4 min")
        XCTAssertEqual(GameFormat.duration(days: 0.25), "6.0 h")
        XCTAssertEqual(GameFormat.duration(days: 2.5), "2.5 days")
        XCTAssertEqual(GameFormat.duration(days: 12), "12 days")
        XCTAssertEqual(GameFormat.duration(days: 400), "over a month")
    }

    // MARK: Collection

    /// Floored, never rounded. A dex that reads 100% with an entry missing is a
    /// bug the player can see from across the room.
    func testCompletionPercentIsFloored() {
        XCTAssertEqual(GameFormat.completion(1_082, of: 1_083, noun: "seen"),
                       "1,082 of 1,083 seen (99%)")
        XCTAssertEqual(GameFormat.completion(1_083, of: 1_083, noun: "seen"),
                       "1,083 of 1,083 seen (100%)")
        XCTAssertEqual(GameFormat.completion(0, of: 0, noun: "seen"), "Nothing yet")
    }

    /// Before there are enough hatches for an observed rate to mean anything, the
    /// advertised one is the honest answer.
    func testShinyRateFallsBackToTheAdvertisedOdds() {
        XCTAssertEqual(GameFormat.shinyRate(shinies: 0, hatches: 3, charm: false), "1 in 64")
        XCTAssertEqual(GameFormat.shinyRate(shinies: 0, hatches: 3, charm: true), "1 in 48")
        XCTAssertEqual(GameFormat.shinyRate(shinies: 2, hatches: 116, charm: false), "1 in 58")
    }

    // MARK: Evolution

    /// Substituted edges must say so. A dex that quietly invents rules is worse
    /// than one that admits which rules it had to invent.
    func testRequirementNamesTheSubstitutions() throws {
        let bulbasaur = try XCTUnwrap(dex.entry(slug: "bulbasaur"))
        XCTAssertEqual(GameFormat.requirement(bulbasaur.evolutions[0]), "Level 16")

        let pikachu = try XCTUnwrap(dex.entry(slug: "pikachu"))
        XCTAssertEqual(GameFormat.requirement(pikachu.evolutions[0]), "Thunder Stone")

        let eevee = try XCTUnwrap(dex.entry(slug: "eevee"))
        let sylveon = try XCTUnwrap(dex.entry(slug: "sylveon"))
        let edge = try XCTUnwrap(eevee.evolutions.first { $0.to == sylveon.id })
        XCTAssertEqual(
            GameFormat.requirement(edge), "Level 36, standing in for the real trigger")

        let haunter = try XCTUnwrap(dex.entry(slug: "haunter"))
        XCTAssertEqual(
            GameFormat.requirement(haunter.evolutions[0]), "Linking Cord, in place of a trade")
    }

    /// Every edge in the dex must produce a phrase, not a fallback. 513 of them.
    func testEveryEdgeHasARequirementPhrase() {
        for entry in dex.entries {
            for edge in entry.evolutions {
                let text = GameFormat.requirement(edge)
                XCTAssertFalse(text.isEmpty, entry.slug)
                XCTAssertFalse(text.contains("An item"), "\(entry.slug) lost its item name")
            }
        }
    }

    // MARK: Events

    func testEventLinesNameThingsRatherThanIDs() throws {
        let pikachu = try XCTUnwrap(dex.entry(slug: "pikachu"))
        let raichu = try XCTUnwrap(dex.entry(slug: "raichu"))

        let hatched = GameEvent.caught(CatchEvent(
            entryID: pikachu.id, variant: .shiny, gender: .male, source: .hatch))
        XCTAssertEqual(GameFormat.describe(hatched, dex: dex), "Hatched Shiny Pikachu")

        XCTAssertEqual(
            GameFormat.describe(.evolved(raiseID: UUID(), from: pikachu.id, to: raichu.id), dex: dex),
            "Pikachu evolved into Raichu")
        XCTAssertEqual(
            GameFormat.describe(.duplicate(entryID: pikachu.id, dust: 3), dex: dex),
            "Duplicate Pikachu, traded for 3 Dust")
        XCTAssertEqual(
            GameFormat.describe(.duplicate(entryID: pikachu.id, dust: 0), dex: dex),
            "Duplicate Pikachu")
        XCTAssertEqual(
            GameFormat.describe(.graduated(raiseID: UUID(), entryID: raichu.id), dex: dex),
            "Raichu graduated at level 100")
        // A level up has to say *who*. With six of them training, "Reached level
        // 21" is a line about nobody.
        XCTAssertEqual(
            GameFormat.describe(
                .levelledUp(raiseID: UUID(), entryID: pikachu.id, to: 21), dex: dex),
            "Pikachu reached level 21")
    }

    func testDexTileLabelSaysOutLoudWhatTheRingShows() {
        XCTAssertEqual(
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: true, milestone: 100),
            "Lapras, reached level 100")
        XCTAssertEqual(
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: true, milestone: 50),
            "Lapras, reached level 50")
        XCTAssertEqual(
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: true, milestone: nil),
            "Lapras")
        XCTAssertEqual(
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: false, milestone: nil),
            "Number 131, not caught")
    }

    func testMilestoneLineCountsGraduationsAndNotWaypoints() {
        XCTAssertEqual(GameFormat.milestoneLine(level: 100, count: 1), "Reached level 100")
        XCTAssertEqual(GameFormat.milestoneLine(level: 100, count: 2), "Reached level 100 twice")
        XCTAssertEqual(
            GameFormat.milestoneLine(level: 100, count: 3), "Reached level 100, 3 times")
        XCTAssertEqual(
            GameFormat.milestoneLine(level: 50, count: 1),
            "Reached level 50, halfway to graduation")
        XCTAssertEqual(
            GameFormat.milestoneLine(level: 50, count: 4),
            "Reached level 50, halfway to graduation",
            "waypoints are not tallied")
    }

    // MARK: The team

    func testTeamSummaryCarriesTheMultiplier() {
        XCTAssertEqual(GameFormat.teamSummary(occupied: 1, capacity: 6, expShare: false),
                       "Team 1 of 6 · 1x XP")
        XCTAssertEqual(GameFormat.teamSummary(occupied: 2, capacity: 6, expShare: false),
                       "Team 2 of 6 · 1.8x XP")
        XCTAssertEqual(GameFormat.teamSummary(occupied: 6, capacity: 6, expShare: false),
                       "Team 6 of 6 · 5x XP")
        XCTAssertEqual(GameFormat.teamSummary(occupied: 6, capacity: 6, expShare: true),
                       "Team 6 of 6 · 6x XP")
        XCTAssertEqual(GameFormat.teamSummary(occupied: 0, capacity: 6, expShare: false),
                       "Team 0 of 6 · 0x XP")
    }

    /// A trailing zero on a round number reads like false precision.
    func testMultiplierDropsAPointlessDecimal() {
        XCTAssertEqual(GameFormat.multiplier(5.0), "5x")
        XCTAssertEqual(GameFormat.multiplier(2.6), "2.6x")
        XCTAssertEqual(GameFormat.multiplier(1.7999999), "1.8x")
        XCTAssertEqual(GameFormat.multiplier(0.8), "0.8x")
    }

    /// Slot 1 is the only one that means anything, so it is the only one with a
    /// name rather than a number.
    func testSlotLabelsAndShares() {
        XCTAssertEqual(GameFormat.slotLabel(0), "Lead")
        XCTAssertEqual(GameFormat.slotLabel(1), "Slot 2")
        XCTAssertEqual(GameFormat.slotLabel(5), "Slot 6")
        XCTAssertEqual(GameFormat.shareLine(slot: 0, expShare: false), "Full XP")
        XCTAssertEqual(GameFormat.shareLine(slot: 3, expShare: false), "80% XP")
        XCTAssertEqual(GameFormat.shareLine(slot: 3, expShare: true), "Full XP")
    }

    /// A graduated member's share is deliberately not redistributed, so the
    /// player has to be told rather than quietly compensated.
    func testTheWastedSlotNoteOnlyAppearsWhenThereIsWaste() {
        XCTAssertNil(GameFormat.wastedSlotNote(graduated: 0))
        XCTAssertEqual(
            GameFormat.wastedSlotNote(graduated: 1),
            "1 graduated Pokemon is taking a team slot and earning nothing. Send it to your PC to free the share.")
        XCTAssertTrue(
            try XCTUnwrap(GameFormat.wastedSlotNote(graduated: 3)).hasPrefix("3 graduated Pokemon are"))
    }

    /// The Dex offers only what exists. No button at all when there is nobody to
    /// bring back, because a disabled control with no explanation is worse than
    /// no control.
    func testAddToTeamOnlyAppearsWhenSomebodyCanCome() {
        var options = Trainer.DexOptions()
        XCTAssertNil(GameFormat.addToTeamTitle(options), "nothing benched, no button")

        options.resumable = [Trainer.Candidate(id: UUID(), level: 47, variant: .normal)]
        options.boxedTotal = 1
        XCTAssertEqual(GameFormat.addToTeamTitle(options), "Add to team")
        XCTAssertNil(GameFormat.addToTeamRefusal(options))

        options.resumable.append(
            Trainer.Candidate(id: UUID(), level: 12, variant: .shiny))
        options.boxedTotal = 2
        XCTAssertEqual(GameFormat.addToTeamTitle(options), "Add to team (2 in your PC)")

        // The menu is capped but the count is not: it says how many are really
        // there, and shows the six worth choosing between.
        options.boxedTotal = 20
        XCTAssertEqual(GameFormat.addToTeamTitle(options), "Add to team (20 in your PC)")

        options.teamHasRoom = false
        XCTAssertEqual(
            GameFormat.addToTeamRefusal(options),
            "Your team is full at 6. Send one to your PC first.")
    }

    /// The swap menu is the drag's twin, and a menu bar window is an awkward
    /// place to drag inside.
    func testSwapRowsNameTheSlotAndOccupant() {
        XCTAssertEqual(GameFormat.swapRow(slot: 0, name: "Charizard"), "Lead, Charizard")
        XCTAssertEqual(GameFormat.swapRow(slot: 2, name: "Pineco"), "Slot 3, Pineco")
    }

    func testCandidateRowsNameTheVariantAndLevel() {
        XCTAssertEqual(
            GameFormat.candidateRow(
                Trainer.Candidate(id: UUID(), level: 47, variant: .normal)),
            "Normal, level 47")
        XCTAssertEqual(
            GameFormat.candidateRow(
                Trainer.Candidate(id: UUID(), level: 5, variant: .shiny)),
            "Shiny, level 5")
    }

    func testOnTeamNoteCountsWhatIsAlreadyTraining() {
        var options = Trainer.DexOptions()
        XCTAssertNil(GameFormat.onTeamNote(options))
        options.onTeam = 1
        XCTAssertEqual(GameFormat.onTeamNote(options), "One is on your team.")
        options.onTeam = 3
        XCTAssertEqual(GameFormat.onTeamNote(options), "3 of these are on your team.")
    }

    /// The line that answers "why is there a Hatch another button on Charmeleon":
    /// there is not, and this says what to do instead.
    func testTheEvolvedFormExplainsItself() {
        XCTAssertEqual(
            GameFormat.comesFromLine(baseFormName: "Charmander"),
            "Only Charmander can be hatched. This one is reached by raising it.")
        let price = Trainer.DexOptions.Price(coins: 3_000, dust: 25)
        XCTAssertEqual(GameFormat.hatchAnotherCoinsRow(price), "3,000 coins")
        XCTAssertEqual(GameFormat.hatchAnotherDustRow(price), "25 Dust")
    }

    /// The note under "Hatch another" has to say that the egg is rolled again,
    /// because the roll is the whole reason to buy one: `Trainer.obtain` calls
    /// `HatchRoll` for shiny and gender on every acquisition. Copy that describes
    /// it as "a second one of this exact species" is what shipped first, and it
    /// reads as an expensive duplicate.
    func testHatchAnotherNoteSellsTheFreshRollAndNamesTheSpecies() {
        let note = GameFormat.hatchAnotherNote(name: "Servine", missingVariants: 2)
        XCTAssertTrue(note.contains("Servine"))
        XCTAssertTrue(note.contains("shiny"))
        XCTAssertTrue(note.contains("gender"))
        XCTAssertTrue(note.contains("level 1"))
    }

    /// The same note must stop promising a new variant once there are none left,
    /// or it is selling something the roll cannot deliver. The offer stays, so the
    /// line has to name the reason that survives: a fresh level 1 to raise.
    func testHatchAnotherNoteStopsPromisingVariantsOnceTheEntryIsComplete() {
        let note = GameFormat.hatchAnotherNote(name: "Servine", missingVariants: 0)
        XCTAssertTrue(note.contains("every Servine sprite"))
        XCTAssertFalse(note.contains("variant you do not have"))
        XCTAssertTrue(note.contains("level 1"))
    }

    // MARK: Projects

    /// The point of the whole feature: "what was this one raised on".
    func testProjectLineRanksByShare() {
        let xp = [
            "/Users/a/Code/PokeBar": 620.0,
            "/Users/a/Code/hue-scenes": 380.0,
        ]
        XCTAssertEqual(
            GameFormat.projectLine(xp, hidden: false),
            "Raised on PokeBar 62%, hue-scenes 38%")
    }

    /// `hue-scenes` is the case that rules out decoding the encoded directory
    /// name: `-Users-a-Code-hue-scenes` cannot say whether that is one directory
    /// or two. The path is read from the log instead, and the last component is
    /// the name.
    func testProjectNamesComeFromThePathNotFromGuessing() {
        XCTAssertEqual(Project.displayName("/Users/a/Code/hue-scenes"), "hue-scenes")
        XCTAssertEqual(Project.displayName("/Users/a/Code/PokeBar"), "PokeBar")
        XCTAssertEqual(Project.displayName(Project.unknown), "Unknown")
        XCTAssertEqual(Project.displayName(""), "Unknown")
        XCTAssertEqual(
            Project.displayName("/Users/someone", home: "/Users/someone"), "Home",
            "a session started in the home directory is not a project called someone")
    }

    /// Two names is what fits; the rest is a count.
    func testProjectLineTailIsCounted() {
        let xp = ["/a/one": 5.0, "/a/two": 4.0, "/a/three": 3.0, "/a/four": 2.0]
        let line = try? XCTUnwrap(GameFormat.projectLine(xp, hidden: false))
        XCTAssertEqual(line, "Raised on one 36%, two 29% and 2 more")
    }

    /// The switch hides names, never the fact that there were projects, and
    /// never anything about recording.
    func testHidingKeepsTheCountAndDropsTheNames() {
        let xp = ["/work/client-secret-thing": 10.0, "/home/mine": 5.0]
        XCTAssertEqual(GameFormat.projectLine(xp, hidden: true), "Raised across 2 projects")
        XCTAssertEqual(
            GameFormat.projectLine(["/work/one": 1.0], hidden: true), "Raised on 1 project")
        XCTAssertFalse(
            try XCTUnwrap(GameFormat.projectLine(xp, hidden: true)).contains("client"))
    }

    func testNothingAttributedShowsNoLine() {
        XCTAssertNil(GameFormat.projectLine([:], hidden: false))
        XCTAssertNil(GameFormat.projectLine(["/a/b": 0], hidden: false), "zero is not a project")
    }

    /// The login switch says what it did, including the case a user cannot fix
    /// from inside the app.
    func testLoginItemCopy() {
        XCTAssertNil(GameFormat.loginItemNote(.off), "the ordinary case says nothing")
        XCTAssertEqual(
            GameFormat.loginItemNote(.on),
            "PokeBar starts with your Mac, so evolutions arrive when they happen.")
        XCTAssertTrue(
            try XCTUnwrap(GameFormat.loginItemNote(.needsApproval)).contains("System Settings"))
        XCTAssertNotNil(GameFormat.loginItemNote(.unavailable))
    }

    // MARK: Celebrations

    /// A 300 coin egg used to announce itself as one grey line in a four-row
    /// feed, under the button that bought it.
    func testCelebrationSaysWhatHappenedAndWhereItWent() {
        let hatched = Celebration(
            entryID: 204, variant: .normal, source: .hatch, isNew: true, dust: 0, slot: 1)
        XCTAssertEqual(GameFormat.celebrationTitle(hatched, name: "Pineco"), "Hatched Pineco")
        XCTAssertEqual(
            GameFormat.celebrationSubtitle(hatched),
            "New to the dex. It joins your team in slot 2.")

        let duplicate = Celebration(
            entryID: 10, variant: .normal, source: .hatch, isNew: false, dust: 3, slot: 0)
        XCTAssertEqual(
            GameFormat.celebrationSubtitle(duplicate),
            "You already had this one. Traded the duplicate for 3 Dust. It is your lead now.")

        let benched = Celebration(
            entryID: 10, variant: .normal, source: .another, isNew: false, dust: 0, slot: nil)
        XCTAssertEqual(GameFormat.celebrationTitle(benched, name: "Caterpie"), "Another Caterpie")
        XCTAssertTrue(
            GameFormat.celebrationSubtitle(benched).hasSuffix(
                "Your team is full, so it is waiting in your PC."))
    }

    /// The one place this app raises its voice, and it has to be earned.
    func testOnlyAShinyGetsAnExclamationMark() {
        let plain = Celebration(
            entryID: 25, variant: .normal, source: .hatch, isNew: true, dust: 0, slot: 0)
        let shiny = Celebration(
            entryID: 25, variant: .shiny, source: .hatch, isNew: true, dust: 0, slot: 0)
        XCTAssertEqual(GameFormat.celebrationTitle(plain, name: "Pikachu"), "Hatched Pikachu")
        XCTAssertEqual(GameFormat.celebrationTitle(shiny, name: "Pikachu"), "Shiny Pikachu!")

        for source: CatchSource in [.starter, .targetedPick, .reroll, .another] {
            let event = Celebration(
                entryID: 25, variant: .normal, source: source, isNew: true, dust: 0, slot: 0)
            XCTAssertFalse(
                GameFormat.celebrationTitle(event, name: "Pikachu").hasSuffix("!"), "\(source)")
        }
    }

    /// The bench grows without limit because nothing is ever deleted, so the pane
    /// summarises past one screen. A count under exactly as many rows is noise.
    func testBenchOverflowNoteOnlyAppearsWhenSomethingIsHidden() {
        XCTAssertNil(GameFormat.pcOverflowNote(total: 1))
        XCTAssertNil(GameFormat.pcOverflowNote(total: GameFormat.pcRowLimit))
        XCTAssertEqual(
            GameFormat.pcOverflowNote(total: 23), "Showing the 6 furthest along of 23.")
    }

    func testRareCandyAlwaysNamesItsTarget() {
        XCTAssertEqual(
            GameFormat.rareCandyTarget("Charizard"), "10,000 XP for Charizard.")
        XCTAssertEqual(
            GameFormat.rareCandyTarget(nil), "Select a Pokemon to use it on.")
    }

    /// The shop line is derived from the curve, so turning the bench dial cannot
    /// leave it advertising the old rate.
    func testExpShareCopyIsDerivedFromTheCurve() {
        XCTAssertEqual(
            GameFormat.expShareDetail(enabled: nil),
            "Every other Pokemon on your team earns at the lead's rate. A full team goes from 5x XP to 6x XP, forever.")
        XCTAssertEqual(
            GameFormat.expShareDetail(enabled: true),
            "On. Every slot earns the lead's rate, so a full team is 6x XP.")
        XCTAssertEqual(
            GameFormat.expShareDetail(enabled: false),
            "Off. Bench slots are back to 0.8x each, so a full team is 5x XP.")
    }

    /// Every user-facing string in this project avoids em dashes, including the
    /// ones assembled at runtime.
    func testNoEmDashesInGeneratedCopy() throws {
        let pikachu = try XCTUnwrap(dex.entry(slug: "pikachu"))
        var strings = [
            GameFormat.xpLine(totalXP: 5_000),
            GameFormat.completion(3, of: 10, noun: "seen"),
            GameFormat.shinyRate(shinies: 1, hatches: 60, charm: false),
            GameFormat.describe(Trainer.GameError.notEnoughDust(needed: 5, have: 1)),
            GameFormat.describe(Trainer.GameError.missingItem("thunder-stone")),
            GameFormat.duration(days: 3),
            GameFormat.milestoneLine(level: 100, count: 1),
            GameFormat.milestoneLine(level: 100, count: 2),
            GameFormat.milestoneLine(level: 100, count: 7),
            GameFormat.milestoneLine(level: 50, count: 1),
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: true, milestone: 100),
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: true, milestone: 50),
            GameFormat.dexTileLabel(name: "Lapras", id: 131, seen: false, milestone: nil),
        ]
        strings += [
            GameFormat.describe(.evolutionChoice(raiseID: UUID(), from: pikachu.id, options: [26]), dex: dex),
            GameFormat.describe(.levelledUp(raiseID: UUID(), entryID: 25, to: 5), dex: dex),
        ]
        strings += dex.entries.prefix(200).flatMap(\.evolutions).map(GameFormat.requirement)
        strings += [
            GameFormat.teamSummary(occupied: 3, capacity: 6, expShare: true),
            GameFormat.slotLabel(2),
            GameFormat.shareLine(slot: 1, expShare: false),
            GameFormat.wastedSlotNote(graduated: 2) ?? "",
            GameFormat.addToTeamTitle(
                Trainer.DexOptions(
                    resumable: [Trainer.Candidate(id: UUID(), level: 9, variant: .shiny)]))
                ?? "",
            GameFormat.comesFromLine(baseFormName: "Charmander"),
            GameFormat.hatchAnotherNote(name: "Charmander", missingVariants: 1),
            GameFormat.hatchAnotherNote(name: "Charmander", missingVariants: 0),
            GameFormat.candidateRow(Trainer.Candidate(id: UUID(), level: 9, variant: .shiny)),
            GameFormat.onTeamNote(Trainer.DexOptions(onTeam: 2)) ?? "",
            GameFormat.celebrationTitle(
                Celebration(
                    entryID: 25, variant: .shiny, source: .hatch, isNew: true, dust: 2, slot: 1),
                name: "Pikachu"),
            GameFormat.celebrationSubtitle(
                Celebration(
                    entryID: 25, variant: .shiny, source: .hatch, isNew: false, dust: 2,
                    slot: nil)),
            GameFormat.describe(Trainer.GameError.notABaseForm(5)),
            GameFormat.pcOverflowNote(total: 40) ?? "",
            GameFormat.rareCandyTarget("Lapras"),
            GameFormat.rareCandyTarget(nil),
            GameFormat.expShareDetail(enabled: nil),
            GameFormat.expShareDetail(enabled: true),
            GameFormat.expShareDetail(enabled: false),
            GameFormat.describe(Trainer.GameError.teamFull),
            GameFormat.describe(Trainer.GameError.alreadyOnTeam),
            GameFormat.describe(Trainer.GameError.unknownIndividual(UUID())),
        ]
        for text in strings {
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("\u{2013}"), text)
        }
    }

    // MARK: Errors

    func testErrorsReadInThePlayersTerms() {
        XCTAssertEqual(
            GameFormat.describe(Trainer.GameError.notEnoughCoins(needed: 300, have: 12)),
            "Needs 300 coins. You have 12 coins.")
        XCTAssertEqual(
            GameFormat.describe(Trainer.GameError.notEnoughCoins(needed: 1, have: 0)),
            "Needs 1 coin. You have 0 coins.")
        XCTAssertEqual(
            GameFormat.describe(Trainer.GameError.missingItem("thunder-stone")),
            "You do not have a Thunder Stone.")
        XCTAssertEqual(GameFormat.describe(Trainer.GameError.alreadyOwned),
                       "Already in the collection.")
    }

    // MARK: Shop stock

    /// The shop's evolution stock is derived from the manifest, not hand-listed,
    /// so it cannot drift from the edges it exists to unlock.
    func testEvolutionItemsAre24LinesSortedByName() {
        let items = dex.evolutionItems
        XCTAssertEqual(items.count, 24)
        XCTAssertEqual(items.map(\.name), items.map(\.name).sorted())
        XCTAssertTrue(items.contains { $0.slug == "linking-cord" && $0.name == "Linking Cord" })
        XCTAssertTrue(items.contains { $0.slug == "thunder-stone" && $0.name == "Thunder Stone" })
    }
}
