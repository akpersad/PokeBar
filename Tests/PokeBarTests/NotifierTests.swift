import XCTest
@testable import PokeBar

/// What is worth interrupting someone for.
///
/// The editorial decision, not the delivery: `Notifier.announcement` is pure so
/// the "most events stay quiet" rule is a test rather than a hope. A menu bar app
/// that notifies on everything gets its notifications turned off, and then the
/// one that mattered does not arrive either.
final class NotifierTests: XCTestCase {

    private var dex: Pokedex!

    override func setUpWithError() throws {
        dex = try Pokedex.loadBundled()
    }

    /// A stand-in individual. Which one an event happened to does not change
    /// whether it is worth interrupting for, which is the whole subject here.
    private let anyone = UUID()

    private func announcement(_ event: GameEvent) -> (title: String, body: String)? {
        Notifier.announcement(for: event, dex: dex)
    }

    /// A full climb passes 99 level ups, and the player clicked the button that
    /// caused the hatch. Neither earns an alert.
    func testRoutineEventsAreSilent() throws {
        let caterpie = try XCTUnwrap(dex.entry(slug: "caterpie"))
        XCTAssertNil(announcement(.levelledUp(raiseID: anyone, entryID: 10, to: 42)))
        XCTAssertNil(announcement(.duplicate(entryID: caterpie.id, dust: 1)))
        XCTAssertNil(announcement(.caught(CatchEvent(
            entryID: caterpie.id, variant: .normal, gender: .male, source: .hatch))))
    }

    /// These three happen on their own, from token accrual, while the window is
    /// closed. That is the whole reason notifications exist here.
    func testPassiveEventsAnnounce() throws {
        let caterpie = try XCTUnwrap(dex.entry(slug: "caterpie"))
        let metapod = try XCTUnwrap(dex.entry(slug: "metapod"))
        let eevee = try XCTUnwrap(dex.entry(slug: "eevee"))

        XCTAssertEqual(
            announcement(.evolved(raiseID: anyone, from: caterpie.id, to: metapod.id))?.title,
            "Caterpie evolved")
        XCTAssertEqual(
            announcement(.graduated(raiseID: anyone, entryID: metapod.id))?.title, "Metapod graduated")
        let choice = announcement(.evolutionChoice(raiseID: anyone, from: eevee.id, options: [196, 197]))
        XCTAssertEqual(choice?.title, "Eevee is ready to evolve")
        XCTAssertEqual(choice?.body, "Into Espeon or Umbreon. Pick one in PokeBar.")
    }

    /// A 1-in-64 roll is loud enough to say out loud even though the player was
    /// watching. An evolution that inherits shininess is not: it was already
    /// announced when it hatched.
    func testShinyAnnouncesOnceAtTheRoll() throws {
        let caterpie = try XCTUnwrap(dex.entry(slug: "caterpie"))
        for source in [CatchSource.hatch, .reroll] {
            let event = GameEvent.caught(CatchEvent(
                entryID: caterpie.id, variant: .shiny, gender: .male, source: source))
            XCTAssertEqual(announcement(event)?.title, "Shiny Caterpie", "\(source)")
        }
        let evolved = GameEvent.caught(CatchEvent(
            entryID: caterpie.id, variant: .shiny, gender: .male,
            source: .evolution(from: 10)))
        XCTAssertNil(announcement(evolved))
        // A claimed entry arrives in its plain sprite, so this cannot happen;
        // asserted anyway, because "bought a shiny" would be the wrong story.
        let claimed = GameEvent.caught(CatchEvent(
            entryID: caterpie.id, variant: .shiny, gender: .male, source: .targetedPick))
        XCTAssertNil(announcement(claimed))
    }

    // MARK: - Grouping

    /// One credit can now evolve up to six Pokemon. Six banners for one tick is
    /// how a user ends up turning notifications off, and then the one that
    /// mattered does not arrive either.
    func testSameKindAlertsFromOneCreditAreGrouped() throws {
        let events: [GameEvent] = [
            .levelledUp(raiseID: anyone, entryID: 10, to: 16),
            .evolved(raiseID: UUID(), from: 10, to: 11),
            .evolved(raiseID: UUID(), from: 13, to: 14),
            .evolved(raiseID: UUID(), from: 1, to: 2),
        ]
        let alerts = Notifier.announcements(for: events, dex: dex)

        XCTAssertEqual(alerts.count, 1, "three evolutions, one banner")
        XCTAssertEqual(alerts[0].title, "3 Pokemon evolved")
        XCTAssertEqual(alerts[0].body, "Metapod, Kakuna and Ivysaur, all at once.")
    }

    /// Grouped per kind, never across kinds: "5 updates" tells the player
    /// nothing. Three kinds is therefore the ceiling for one credit.
    func testKindsAreGroupedSeparatelyAndCapTheBanners() throws {
        let eevee = try XCTUnwrap(dex.entry(slug: "eevee"))
        let wurmple = try XCTUnwrap(dex.entry(slug: "wurmple"))
        let events: [GameEvent] = [
            .evolved(raiseID: UUID(), from: 10, to: 11),
            .evolved(raiseID: UUID(), from: 13, to: 14),
            .graduated(raiseID: UUID(), entryID: 1),
            .graduated(raiseID: UUID(), entryID: 4),
            .evolutionChoice(raiseID: UUID(), from: eevee.id, options: [196, 197]),
            .evolutionChoice(raiseID: UUID(), from: wurmple.id, options: [267, 269]),
        ]
        let alerts = Notifier.announcements(for: events, dex: dex)

        XCTAssertEqual(alerts.map(\.title), [
            "2 Pokemon evolved", "2 Pokemon graduated", "2 Pokemon are ready to evolve",
        ])
        XCTAssertEqual(alerts[1].body, "Bulbasaur and Charmander all reached level 100.")
        XCTAssertEqual(alerts[2].body, "Eevee and Wurmple are each waiting on a choice.")
    }

    /// A batch of one is not a batch. The team must not change how the ordinary
    /// case reads, which is still by far the most common one.
    func testABatchOfOneReadsExactlyAsBefore() throws {
        let single: [GameEvent] = [.evolved(raiseID: anyone, from: 10, to: 11)]
        XCTAssertEqual(
            Notifier.announcements(for: single, dex: dex).map(\.title),
            [try XCTUnwrap(announcement(single[0])).title])
        XCTAssertEqual(
            Notifier.announcements(for: single, dex: dex).first?.body,
            "It is now Metapod.")
    }

    /// A shiny is never grouped and never suppressed: it comes from a hatch or a
    /// re-roll, which are single clicks, so a batch cannot hold two.
    func testAShinyKeepsItsOwnBannerAlongsideAGroup() throws {
        let events: [GameEvent] = [
            .evolved(raiseID: UUID(), from: 10, to: 11),
            .evolved(raiseID: UUID(), from: 13, to: 14),
            .caught(CatchEvent(entryID: 25, variant: .shiny, gender: .male, source: .hatch)),
        ]
        let alerts = Notifier.announcements(for: events, dex: dex)
        XCTAssertEqual(alerts.map(\.title), ["2 Pokemon evolved", "Shiny Pikachu"])
    }

    func testSilentEventsStaySilentInABatch() throws {
        let events: [GameEvent] = [
            .levelledUp(raiseID: anyone, entryID: 10, to: 2),
            .levelledUp(raiseID: UUID(), entryID: 10, to: 30),
            .duplicate(entryID: 10, dust: 3),
        ]
        XCTAssertTrue(Notifier.announcements(for: events, dex: dex).isEmpty)
    }

    func testTheNameListReadsLikeEnglish() {
        XCTAssertEqual(Notifier.list([]), "")
        XCTAssertEqual(Notifier.list(["Pikachu"]), "Pikachu")
        XCTAssertEqual(Notifier.list(["Pikachu", "Eevee"]), "Pikachu and Eevee")
        XCTAssertEqual(
            Notifier.list(["Pikachu", "Eevee", "Snorlax"]), "Pikachu, Eevee and Snorlax")
    }

    func testNoEmDashesInAlerts() throws {
        let eevee = try XCTUnwrap(dex.entry(slug: "eevee"))
        let events: [GameEvent] = [
            .evolved(raiseID: anyone, from: 1, to: 2),
            .graduated(raiseID: anyone, entryID: 1),
            .evolutionChoice(raiseID: anyone, from: eevee.id, options: [196, 197, 700]),
            .caught(CatchEvent(entryID: 1, variant: .shiny, gender: .male, source: .hatch)),
        ]
        let grouped: [GameEvent] = events + [
            .evolved(raiseID: UUID(), from: 4, to: 5),
            .graduated(raiseID: UUID(), entryID: 7),
            .evolutionChoice(raiseID: UUID(), from: 265, options: [266, 268]),
        ]
        let copy = events.compactMap(announcement).flatMap { [$0.title, $0.body] }
            + Notifier.announcements(for: grouped, dex: dex).flatMap { [$0.title, $0.body] }
        for text in copy {
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("\u{2013}"), text)
        }
    }
}
