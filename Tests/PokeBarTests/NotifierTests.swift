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

    private func announcement(_ event: GameEvent) -> (title: String, body: String)? {
        Notifier.announcement(for: event, dex: dex)
    }

    /// A full climb passes 99 level ups, and the player clicked the button that
    /// caused the hatch. Neither earns an alert.
    func testRoutineEventsAreSilent() throws {
        let caterpie = try XCTUnwrap(dex.entry(slug: "caterpie"))
        XCTAssertNil(announcement(.levelledUp(to: 42)))
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
            announcement(.evolved(from: caterpie.id, to: metapod.id))?.title,
            "Caterpie evolved")
        XCTAssertEqual(
            announcement(.graduated(entryID: metapod.id))?.title, "Metapod graduated")
        let choice = announcement(.evolutionChoice(from: eevee.id, options: [196, 197]))
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

    func testNoEmDashesInAlerts() throws {
        let eevee = try XCTUnwrap(dex.entry(slug: "eevee"))
        let events: [GameEvent] = [
            .evolved(from: 1, to: 2),
            .graduated(entryID: 1),
            .evolutionChoice(from: eevee.id, options: [196, 197, 700]),
            .caught(CatchEvent(entryID: 1, variant: .shiny, gender: .male, source: .hatch)),
        ]
        for text in events.compactMap(announcement).flatMap({ [$0.title, $0.body] }) {
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("\u{2013}"), text)
        }
    }
}
