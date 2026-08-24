import Foundation

/// Every Pokemon ever obtained, in the order it was obtained, and nothing else.
///
/// The same shape as `UsageLedger`: append-only, with the views derived rather
/// than stored. A `Set<Int>` of caught ids answers exactly one question and loses
/// everything else; a per-species record needs a migration for every question
/// nobody thought of yet. The log answers "what did I catch in July", "what is my
/// actual shiny rate" and "how long between duplicates" without changing what is
/// written to disk. See DECISIONS.md.
///
/// Only `events` is persisted. The slot index is rebuilt on decode, deliberately:
/// two copies of the same fact on disk is two things that can disagree, and this
/// one is cheap to derive.
struct CatchLog: Codable, Sendable, Equatable {

    private(set) var events: [CatchEvent] = []

    /// Which of the 2,368 ownable sprites have been filled.
    private(set) var filledSlots: Set<VariantSlot> = []

    init(events: [CatchEvent] = []) {
        self.events = events
        self.filledSlots = Set(events.map(\.slot))
    }

    private enum CodingKeys: String, CodingKey { case events }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(events: try container.decode([CatchEvent].self, forKey: .events))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(events, forKey: .events)
    }

    // MARK: - Writing

    /// Appends, and reports whether this filled a slot that was empty.
    ///
    /// The return value is the duplicate test, and it is deliberately answered
    /// here rather than by the caller: "already owned" means *this exact sprite*,
    /// not this species, so a shiny Pikachu is new even when Pikachu is not.
    @discardableResult
    mutating func append(_ event: CatchEvent) -> Bool {
        let isNew = filledSlots.insert(event.slot).inserted
        events.append(event)
        return isNew
    }

    // MARK: - Derived views

    func owns(_ slot: VariantSlot) -> Bool { filledSlots.contains(slot) }

    func owns(entryID: Int, variant: SpriteVariant = .normal) -> Bool {
        filledSlots.contains(VariantSlot(entryID: entryID, variant: variant))
    }

    /// Entries seen in any variant. This is the "seen it" count, and it is a
    /// different number from filled slots.
    var seenEntryIDs: Set<Int> { Set(filledSlots.map(\.entryID)) }

    /// Slots filled against slots that exist. The completion figure.
    ///
    /// Takes the dex because what exists is a property of the sprite files, not
    /// of the log: 979 entries have two variants, 102 have four, and two have
    /// one.
    func completion(in dex: Pokedex) -> (filled: Int, total: Int) {
        let total = dex.entries.reduce(0) { $0 + $1.ownableVariants.count }
        return (filledSlots.count, total)
    }

    func firstCaught(entryID: Int) -> Date? {
        events.first { $0.entryID == entryID }?.date
    }

    func events(forEntry entryID: Int) -> [CatchEvent] {
        events.filter { $0.entryID == entryID }
    }

    /// Shinies against egg hatches, which is the only denominator that means
    /// anything: evolutions inherit their shininess and targeted picks are not
    /// rolled at all, so counting them would quietly dilute the rate.
    var shinyRate: (shinies: Int, hatches: Int) {
        let hatches = events.filter { $0.source == .hatch }
        return (hatches.filter(\.variant.shiny).count, hatches.count)
    }

    /// Catches bucketed by local day, the same way usage totals are, so a "caught
    /// today" readout cannot disagree with a "used today" one.
    func events(onDay day: String, calendar: Calendar = .current) -> [CatchEvent] {
        events.filter { ClaudeUsageParser.localDayKey($0.date, calendar: calendar) == day }
    }
}
