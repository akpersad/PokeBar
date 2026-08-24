import Foundation

/// One filled slot in the collection: an entry plus which of its sprites.
///
/// Completion is defined over these, and there are 2,368 of them rather than
/// 1,083 x 4, because a variant is ownable only if its sprite file exists.
struct VariantSlot: Codable, Sendable, Hashable {
    let entryID: Int
    let variant: SpriteVariant
}

/// Where a Pokemon came from. Recorded because the log is the only record, and
/// "what is my actual shiny rate" is a question about eggs, not about evolutions
/// the game handed you.
enum CatchSource: Codable, Sendable, Hashable {
    /// An egg, drawn from the hatchable pool. The only source that mints Dust.
    case hatch
    /// The active Pokemon crossed a threshold. Carries what it evolved from.
    case evolution(from: Int)
    /// Bought outright with Dust. The path that makes completion reachable.
    case targetedPick
    /// A paid re-hatch of a species already owned, for a variant not yet owned.
    case reroll
    /// A paid, guaranteed second individual of a base-form species already owned.
    /// Distinct from `reroll` because the two are bought for different reasons and
    /// at different prices, and the log is the only place that can still say which.
    case another
    /// The free first pick. Exists once per collection, and is a distinct source
    /// rather than a `hatch` because "what did my first egg give me" and "who did
    /// I start with" are different questions and the log should answer both.
    case starter
}

/// One catch, appended and never rewritten.
///
/// The per-species view is derived from these rather than stored, which is the
/// same bet `UsageLedger` makes and it pays off for the same reason: a boolean
/// set answers one question and loses everything else, a per-species struct needs
/// a migration for every question nobody thought of yet, and a log can answer
/// "what did I catch in July", "what is my actual shiny rate" and "how long
/// between duplicates" without changing the stored shape. See DECISIONS.md.
struct CatchEvent: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let entryID: Int
    let variant: SpriteVariant
    /// Recorded on every event even though it usually fills no slot. In an
    /// append-only log it costs nothing, and it keeps "I hatched a female
    /// Bulbasaur" answerable.
    let gender: Gender
    let date: Date
    let source: CatchSource

    init(
        id: UUID = UUID(), entryID: Int, variant: SpriteVariant, gender: Gender,
        date: Date = Date(), source: CatchSource
    ) {
        self.id = id
        self.entryID = entryID
        self.variant = variant
        self.gender = gender
        self.date = date
        self.source = source
    }

    var slot: VariantSlot { VariantSlot(entryID: entryID, variant: variant) }
}

/// One individual crossing a level worth marking, appended and never rewritten.
///
/// Separate from `CatchEvent` because it records a different fact about a
/// different thing: a catch is a sprite arriving in the collection, a milestone
/// is an individual getting somewhere. It has to be recorded *somewhere* because
/// nothing else in the game remembers it *as a fact about a sprite*: the roster
/// keeps this individual's level, but the Dex ring is per sprite and belongs to
/// the form it was at the time, which a live level cannot answer once it evolves
/// again. When this was written the roster did not exist either, and switching
/// erased "that one made it" outright.
///
/// Carries the level rather than being a graduation flag. Level 50 and level 100
/// are the same kind of fact at different heights, and a boolean would have
/// needed a second list the first time a second height mattered. It did, one
/// request later.
struct MilestoneEvent: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    /// The entry it *was* at that level, which is the evolved form rather than
    /// whatever came out of the egg. A Charizard got there; a Charmander did not.
    let entryID: Int
    let variant: SpriteVariant
    /// Which individual did it. Two Pikachu each raised the whole way are two
    /// milestones, and the log should be able to say so.
    let raiseID: UUID
    /// The level crossed. One of `Trainer.milestoneLevels`.
    let level: Int
    let date: Date

    init(
        id: UUID = UUID(), entryID: Int, variant: SpriteVariant, raiseID: UUID,
        level: Int, date: Date = Date()
    ) {
        self.id = id
        self.entryID = entryID
        self.variant = variant
        self.raiseID = raiseID
        self.level = level
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, variant, raiseID, level, date
    }

    /// Hand-written for the reason invariant 23 exists. The first shipped shape
    /// of this record had no `level` at all, because the only milestone was
    /// graduation; anything written then is a level 100 record.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.entryID = try c.decode(Int.self, forKey: .entryID)
        self.variant = try c.decode(SpriteVariant.self, forKey: .variant)
        self.raiseID = try c.decode(UUID.self, forKey: .raiseID)
        self.level = try c.decodeIfPresent(Int.self, forKey: .level) ?? XPCurve.maxLevel
        self.date = try c.decode(Date.self, forKey: .date)
    }

    var slot: VariantSlot { VariantSlot(entryID: entryID, variant: variant) }

    var isGraduation: Bool { level >= XPCurve.maxLevel }
}

/// One individual being raised, whether it is on the team or in the PC.
///
/// **Levels belong to the individual and are never lost.** It lives in
/// `Trainer.roster`, which is append-only, and `Trainer.team` decides who is
/// currently earning XP; switching away is free and costs nothing at all. v1 held
/// exactly one of these and threw it away on a switch, treating the lost levels as
/// the price, and that is the half of the decision the user reversed: a week of
/// Charizard should survive an afternoon of Pikachu (DECISIONS.md).
///
/// Identified by `id`, not by what it is: two Charmander raised separately are two
/// of these with two levels, and this one's `entryID` changes under it as it
/// evolves. Raising time is still the real constraint on throughput, which is why
/// the useful sinks buy time or certainty rather than more eggs.
struct Raise: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    /// The entry it is *now*. Changes as it evolves.
    var entryID: Int
    /// What came out of the egg. Kept so the log can answer "how far did this
    /// one get" after three evolutions.
    let originEntryID: Int
    let shiny: Bool
    let gender: Gender
    /// Total XP including the level-1 baseline of 100. See `XPCurve`.
    var totalXP: Double
    let startedAt: Date

    /// Holding an Everstone: this individual does not evolve on its own.
    ///
    /// The games' item, doing the games' job. Per individual rather than per
    /// player, because it is a thing this Pokemon is holding: switching to
    /// another one starts it without.
    ///
    /// It blocks only *automatic* evolution. Pressing an evolve button while
    /// holding one is an unambiguous instruction and overrides it, which is also
    /// how a stone behaves in the games.
    var everstone: Bool

    init(
        id: UUID = UUID(), entryID: Int, originEntryID: Int? = nil, shiny: Bool,
        gender: Gender, totalXP: Double = Double(XPCurve.totalXP(forLevel: 1)),
        startedAt: Date = Date(), everstone: Bool = false
    ) {
        self.id = id
        self.entryID = entryID
        self.originEntryID = originEntryID ?? entryID
        self.shiny = shiny
        self.gender = gender
        self.totalXP = totalXP
        self.startedAt = startedAt
        self.everstone = everstone
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, originEntryID, shiny, gender, totalXP, startedAt, everstone
    }

    /// Hand-written so a **new field cannot destroy a saved game**.
    ///
    /// The synthesized decoder throws on a missing key even when the property has
    /// a default, and `GameMonitor` cannot distinguish "no save yet" from "save I
    /// failed to read" without help. Adding `everstone` to the synthesized version
    /// would therefore have made every existing collection unreadable, and the
    /// collection is the one thing in this app that cannot be re-derived from
    /// anything: the usage ledger can be rebuilt by rescanning, a Pokemon caught
    /// last week cannot.
    ///
    /// Every field added from here on wants `decodeIfPresent` and a default, for
    /// the same reason.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        entryID = try container.decode(Int.self, forKey: .entryID)
        originEntryID = try container.decode(Int.self, forKey: .originEntryID)
        shiny = try container.decode(Bool.self, forKey: .shiny)
        gender = try container.decode(Gender.self, forKey: .gender)
        totalXP = try container.decode(Double.self, forKey: .totalXP)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        everstone = try container.decodeIfPresent(Bool.self, forKey: .everstone) ?? false
    }

    var level: Int { XPCurve.level(forTotalXP: totalXP) }
    var isGraduated: Bool { level >= XPCurve.maxLevel }

    /// The sprite to draw for this individual, given what its current entry has.
    func variant(in dex: Pokedex) -> SpriteVariant {
        guard let entry = dex.entry(id: entryID) else { return SpriteVariant(shiny: shiny) }
        return gender.spriteVariant(shiny: shiny, for: entry)
    }
}

/// Something worth telling the player about. Returned rather than posted, so the
/// game logic stays testable and the notification decision lives at the edge.
enum GameEvent: Sendable, Equatable {
    /// The four cases below name the individual they happened to. One credit now
    /// reaches up to six of them at once, so "it levelled up" is not a fact until
    /// you know *which one*, and the `raiseID` is what lets a caller pair an event
    /// with a team slot.
    case levelledUp(raiseID: UUID, to: Int)
    case evolved(raiseID: UUID, from: Int, to: Int)
    /// Several edges are satisfied at once and the choice is the player's, which
    /// is the honest answer for Eevee at level 36 and for Wurmple at 7. Six
    /// members can be waiting on six different choices at the same time.
    case evolutionChoice(raiseID: UUID, from: Int, options: [Int])
    case graduated(raiseID: UUID, entryID: Int)
    case caught(CatchEvent)
    /// A hatch that filled no new slot. Pays Dust instead.
    case duplicate(entryID: Int, dust: Int)
}

/// A thing worth stopping to look at, derived from what a click just produced.
///
/// **The popover celebrates what you clicked; the notifier announces what
/// happened while you were not looking.** They are the two halves of one rule and
/// neither should do the other's job: a banner for a button you just pressed
/// arrives second and reads as noise, and a hatch that only writes a line into a
/// four-row feed is how a player misses the thing they spent 300 coins on.
///
/// Evolutions are deliberately not celebrated here. They fire on their own from
/// token accrual, often while the window is shut, which is exactly the set the
/// notifier already covers.
struct Celebration: Equatable, Identifiable, Sendable {
    let id: UUID
    let entryID: Int
    let variant: SpriteVariant
    let source: CatchSource
    /// Whether this filled a sprite slot the collection did not have.
    let isNew: Bool
    /// Dust paid for a duplicate. Only ever non-zero for an egg.
    let dust: Int
    /// Which team slot it went into, or nil when the team was full and it went
    /// the PC instead.
    let slot: Int?

    init(
        id: UUID = UUID(), entryID: Int, variant: SpriteVariant, source: CatchSource,
        isNew: Bool, dust: Int, slot: Int?
    ) {
        self.id = id
        self.entryID = entryID
        self.variant = variant
        self.source = source
        self.isNew = isNew
        self.dust = dust
        self.slot = slot
    }
}

/// Every price in the game, in one place, so the economy can be read at a glance
/// and tuned without hunting through call sites.
///
/// Two currencies, and the split is the point. **Coins accrue passively** from
/// token usage at ~1,080/day and buy volume: eggs, candy, stones, the charm.
/// **Dust is minted only by duplicate hatches** and buys choice: the targeted
/// pick and the targeted re-roll. They never substitute for each other, so a
/// quiet week cannot be bought out of and a lucky one cannot be idled through.
///
/// Values are v1 and expected to move once the loop has been played. The one
/// flagged as most likely wrong is the pick price. See DECISIONS.md.
enum Prices {

    // MARK: Coins

    /// ~6.7 h of usage. Cheap on purpose: eggs must never be the bottleneck,
    /// because raising time already is.
    static let egg = 300
    /// 10,000 XP. 1 coin of accrual is worth 200 XP, so this is a 5x markup and
    /// a luxury. Naturally strong early (+4.1 levels at L10) and weak late
    /// (+0.6 at L90), like the games.
    static let rareCandy = 250
    static let rareCandyXP: Double = 10_000
    /// 23 distinct stones, gating 69 edges.
    static let evolutionStone = 400
    /// Gates the 26 trade edges.
    static let linkingCord = 400
    /// ~28 days of accrual. Passive and permanent, so it should be a genuine
    /// commitment rather than an early purchase.
    static let shinyCharm = 30_000
    /// Every party slot earns at the lead's rate: a full team goes from 5.0x to
    /// 6.0x. ~9 days of accrual.
    ///
    /// **10,000 rather than 5,000.** It is passive and permanent, which is the
    /// class the Shiny Charm is priced in at 30,000. At 5,000 it is 4.6 days for a
    /// permanent +20% team XP, which is bought on sight and never thought about
    /// again. At 10,000 it competes with 33 eggs, and a third of the charm reads
    /// correctly against it.
    static let expShare = 10_000

    /// Coins to hatch another of a base-form species already in the collection.
    ///
    /// **Flat, and deliberately not scaled by band**, unlike everything Dust buys.
    /// Nothing else priced in coins scales (egg 300, candy 250, stone 400), and
    /// the flat figure creates the useful shape: Dust is the cheap path for a
    /// common and coins are the escape hatch for a legendary, so the two
    /// currencies curve differently and the choice is real.
    ///
    /// 3,000 is ~2.8 days of accrual at this machine's ~1,080 coins/day, or 10
    /// eggs. An egg already fills a team slot for 300, so this is the price of
    /// *choosing which species*, and it has to sit well above an egg or the random
    /// draw stops being the way the game is played. Filling five party slots this
    /// way is ~14 days, the same order as the Exp Share.
    ///
    /// It cannot be farmed: the team caps at 6, so there is no reason to buy more
    /// than a handful ever. That self-limit is what makes a merely-steep price
    /// safe rather than needing a cooldown.
    static let hatchAnotherCoins = 3_000

    // MARK: Dust

    /// What a duplicate pays, on the raw capture rate rather than the band: 1 for
    /// a Caterpie, 6 at the median, 85 for a capture-rate-3 legendary. Expected
    /// yield is **1.97 Dust per duplicate**, because the weighting that makes
    /// rare things rare also makes them rare in the duplicate stream.
    static func dust(forCaptureRate captureRate: Int) -> Int {
        max(1, Int((255.0 / Double(max(captureRate, 1))).rounded()))
    }

    /// Dust to name an entry and be given it.
    ///
    /// Priced on the *band*, not on the raw rate, which is the opposite of the
    /// hatch weighting and deliberately so. The raw rate spans 85x, and pricing
    /// on it would put a legendary at ~85 days of duplicates against a common's
    /// one. The band compresses that to a shape a player can hold in their head,
    /// and a price is a thing you read rather than a weight you sample.
    ///
    /// Against the measured ~7 Dust/day: a common is a day and a half, a rare
    /// (the median band, 493 of 1,083 entries) about a week, a legendary about
    /// five. Deliberately generous for v1: it is easier to make this harsher once
    /// the loop is playable than to find out a year in that completion was never
    /// reachable.
    static func targetedPick(_ rarity: Rarity) -> Int {
        switch rarity {
        case .common: 10
        case .uncommon: 20
        case .rare: 50
        case .epic: 100
        case .legendary: 250
        case .mythical: 300
        }
    }

    /// Dust to hatch another of a base-form species already owned, guaranteed.
    ///
    /// **Half a targeted pick**, which is the ordering that makes the three Dust
    /// prices read as one scale: a pick (100%) gives a sprite the collection does
    /// not have *and* something to raise; this (50%) gives only something to
    /// raise; a re-roll (10%) gives only a chance at a variant. 5 Dust for a
    /// common, 25 at the median band, 150 for a mythical.
    ///
    /// At the measured ~7 Dust/day a common is under a day and a legendary is
    /// nearly three weeks, which is why the coin path exists beside it.
    static func hatchAnother(_ rarity: Rarity) -> Int {
        max(1, targetedPick(rarity) / 2)
    }

    /// Dust to hatch a species you already own again, for a shot at a variant you
    /// do not. A tenth of the pick, so a 1/64 shiny hunt on a rare species is
    /// ~320 Dust: a long project rather than an afternoon, which is what a shiny
    /// should be.
    static func reroll(_ rarity: Rarity) -> Int {
        max(1, targetedPick(rarity) / 10)
    }

    // MARK: Odds

    /// Upstream's rates, kept. The mainline 1/4096 would mean never seeing a
    /// shiny in a desktop app's lifetime, which upstream says in as many words
    /// and which holds here.
    static let shinyOdds = 64
    static let shinyOddsWithCharm = 48
}
