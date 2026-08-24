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
            GameFormat.describe(.evolved(from: pikachu.id, to: raichu.id), dex: dex),
            "Pikachu evolved into Raichu")
        XCTAssertEqual(
            GameFormat.describe(.duplicate(entryID: pikachu.id, dust: 3), dex: dex),
            "Duplicate Pikachu, traded for 3 Dust")
        XCTAssertEqual(
            GameFormat.describe(.duplicate(entryID: pikachu.id, dust: 0), dex: dex),
            "Duplicate Pikachu")
        XCTAssertEqual(
            GameFormat.describe(.graduated(entryID: raichu.id), dex: dex),
            "Raichu graduated at level 100")
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
        ]
        strings += [
            GameFormat.describe(.evolutionChoice(from: pikachu.id, options: [26]), dex: dex),
            GameFormat.describe(.levelledUp(to: 5), dex: dex),
        ]
        strings += dex.entries.prefix(200).flatMap(\.evolutions).map(GameFormat.requirement)
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
