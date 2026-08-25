import Foundation
import Observation

/// The game half of what the UI binds to: one `Trainer`, persisted, plus the
/// coin balance the ledger earned.
///
/// Deliberately thin. Every rule lives in `Trainer`, which has no clock, no RNG
/// and no disk, so this type is only wiring: it owns the state, saves it, and
/// turns a throwing mutation into something a button can call. Anything worth a
/// test belongs on the other side of that line.
///
/// **Coins are earned in `UsageMonitor` and spent here.** The split matters:
/// the ledger's coin total is frozen at credit time and is never recomputed, so
/// a pricing refresh cannot reach backwards and unspend a purchase.
@MainActor
@Observable
final class GameMonitor {

    private(set) var trainer = Trainer()

    /// Lifetime coins from the ledger. Pushed by `UsageMonitor` rather than read,
    /// so this type never has to know how coins are derived.
    var coinsEarned = 0

    /// The most recent things worth telling the player about, newest first.
    /// Capped, because this is a feed and not a second copy of the catch log.
    private(set) var recentEvents: [GameEvent] = []

    /// Non-nil for every real launch. Optional only because a dex that fails to
    /// load must not take the usage engine down with it, which is the same
    /// concession `SpriteAnimator` makes.
    let dex: Pokedex?

    private let stateURL: URL
    private var rng = SystemRandomNumberGenerator()
    private let notifier = Notifier()

    init(dex: Pokedex? = try? Pokedex.loadBundled(), stateURL: URL = GameMonitor.defaultStateURL()) {
        self.dex = dex
        self.stateURL = stateURL
        // Before `load()`, never after. The point is to hold a copy of the save
        // as it stood before this run touched it, so a bad write later in the
        // launch has something to be recovered from.
        SaveBackup(stateURL: stateURL).capture()
        load()
    }

    static func defaultStateURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("game-state.json")
    }

    // MARK: - Reading

    var coins: Int { trainer.coins(earned: coinsEarned) }
    var dust: Int { trainer.dust }
    var log: CatchLog { trainer.log }

    /// Team slot 1. What the status item and the desktop pet draw, and the only
    /// member on the full XP share.
    var lead: Raise? { trainer.lead }

    /// Every individual ever raised, and the ones not currently training. Nothing
    /// here is ever deleted, which is what makes the PC list possible.
    var roster: [Raise] { trainer.roster }
    var boxed: [Raise] { trainer.boxed }

    /// The team in slot order, each resolved to what it is right now.
    var teamMembers: [(slot: Int, raise: Raise, entry: DexEntry)] {
        guard let dex else { return [] }
        return trainer.teamRaises.enumerated().compactMap { slot, raise in
            guard let entry = dex.entry(id: raise.entryID) else { return nil }
            return (slot, raise, entry)
        }
    }

    /// The PC, resolved, **best first**. "Bring back my strongest" is the
    /// question this list exists to answer.
    var boxMembers: [(raise: Raise, entry: DexEntry)] {
        guard let dex else { return [] }
        return trainer.boxed
            .sorted { $0.totalXP > $1.totalXP }
            .compactMap { raise in
                guard let entry = dex.entry(id: raise.entryID) else { return nil }
                return (raise, entry)
            }
    }

    /// Members in the team that have graduated and are therefore earning nothing.
    /// Surfaced rather than compensated for, per invariant 32.
    var graduatedInTeam: Int { trainer.teamRaises.filter(\.isGraduated).count }

    /// The lead entry, resolved. Nil before the first hatch.
    var leadEntry: DexEntry? {
        guard let dex, let lead else { return nil }
        return dex.entry(id: lead.entryID)
    }

    /// What the status item should draw: the active Pokemon, or the daily
    /// placeholder pick until there is one.
    ///
    /// This is the seam Phase 3 left on purpose. `Pokedex.featured(on:)` stays as
    /// the empty-collection fallback rather than being deleted, because a brand
    /// new install has nothing to show and an empty menu bar is worse than a
    /// stranger.
    func statusItem(on date: Date = Date()) -> (entry: DexEntry, variant: SpriteVariant)? {
        guard let dex else { return nil }
        if let lead, let entry = dex.entry(id: lead.entryID) {
            return (entry, lead.variant(in: dex))
        }
        guard let featured = dex.featured(on: date) else { return nil }
        return (featured, .normal)
    }

    var completion: (filled: Int, total: Int) {
        guard let dex else { return (0, 0) }
        return trainer.log.completion(in: dex)
    }

    /// Entries seen in any variant, against the 1,083 that exist. The headline
    /// dex figure, and a different number from filled slots.
    var entriesSeen: (seen: Int, total: Int) {
        (trainer.log.seenEntryIDs.count, dex?.count ?? 0)
    }

    func canAfford(_ item: Trainer.ShopItem) -> Bool { coins >= item.priceInCoins }

    /// The ring an entry's Dex tile draws. Goes through `Trainer`, never through
    /// `log` directly, because the log alone cannot see a Dragonite that is level
    /// 60 without ever having crossed 50 as one.
    func milestone(entryID: Int) -> Int? { trainer.milestone(entryID: entryID) }

    func milestone(entryID: Int, variant: SpriteVariant) -> Int? {
        guard let dex else { return nil }
        return trainer.milestone(entryID: entryID, variant: variant, dex: dex)
    }

    func milestoneCount(entryID: Int, level: Int) -> Int {
        trainer.milestoneCount(entryID: entryID, level: level)
    }

    /// Every team member with an evolution waiting, in slot order, resolved.
    ///
    /// A list rather than a single prompt, because one credit can leave several
    /// members waiting on the player at once and hiding five of them behind a
    /// selection would mean a decision nobody knows they are holding up.
    var teamPendingEvolutions: [(raise: Raise, entry: DexEntry, options: [(edge: Evolution, target: DexEntry)])] {
        guard let dex else { return [] }
        return trainer.teamPendingEvolutions(dex: dex).compactMap { pending in
            guard let raise = trainer.raise(id: pending.raiseID),
                  let entry = dex.entry(id: raise.entryID)
            else { return nil }
            return (raise, entry, pending.options)
        }
    }

    /// What the Dex detail pane can offer for one entry: who can come back off the
    /// PC, and whether another can be bought.
    func dexOptions(entryID: Int) -> Trainer.DexOptions {
        guard let dex else { return Trainer.DexOptions() }
        return trainer.dexOptions(entryID: entryID, dex: dex)
    }

    /// The bottom of a line, for the copy that explains why an evolved form
    /// cannot be hatched.
    func entry(id: Int) -> DexEntry? { dex?.entry(id: id) }

    /// Settles notification permission once the player has something to raise.
    ///
    /// Called from the status item, which is the one view alive for the whole run,
    /// so this does not depend on the popover ever being opened.
    func prepareNotifications() async {
        guard trainer.lead != nil else { return }
        await notifier.requestIfNeeded()
    }

    // MARK: - Writing

    /// Credits XP against the same tokens that minted coins.
    ///
    /// Called from the usage loop on every scan that added anything. A quiet
    /// minute credits nothing and writes nothing.
    func credit(
        weightedTokens: Double, byProject: [String: Double] = [:], coinsEarned: Int
    ) {
        self.coinsEarned = coinsEarned
        guard let dex, weightedTokens > 0 else { return }
        record(trainer.credit(weightedTokens: weightedTokens, byProject: byProject, dex: dex))
        persist()
    }

    /// Whether the player has yet to make their first pick.
    var needsStarter: Bool { trainer.needsStarter }

    @discardableResult
    func chooseStarter(entryID: Int) throws -> [GameEvent] {
        guard let dex else { return [] }
        let events = try trainer.chooseStarter(entryID: entryID, dex: dex, using: &rng)
        record(events)
        persist()
        return events
    }

    /// Buys and opens an egg. The whole loop starts here.
    @discardableResult
    func hatch() throws -> [GameEvent] {
        guard let dex else { return [] }
        let events = try trainer.hatch(coinsEarned: coinsEarned, dex: dex, using: &rng)
        record(events)
        persist()
        return events
    }

    func buy(_ item: Trainer.ShopItem) throws {
        try trainer.buy(item, coinsEarned: coinsEarned)
        persist()
    }

    func useRareCandy(on raiseID: UUID) throws {
        guard let dex else { return }
        record(try trainer.useRareCandy(on: raiseID, dex: dex))
        persist()
    }

    func evolve(_ raiseID: UUID, into targetID: Int) throws {
        guard let dex else { return }
        record(try trainer.evolve(raiseID, into: targetID, dex: dex))
        persist()
    }

    func targetedPick(entryID: Int) throws {
        guard let dex else { return }
        record(try trainer.targetedPick(entryID: entryID, dex: dex))
        persist()
    }

    func reroll(entryID: Int) throws {
        guard let dex else { return }
        record(try trainer.reroll(entryID: entryID, dex: dex, using: &rng))
        persist()
    }

    /// Switches the Exp Share on or off. Silently does nothing until it is bought.
    func setExpShare(_ enabled: Bool) {
        trainer.setExpShare(enabled)
        persist()
    }

    func setEverstone(_ held: Bool, on raiseID: UUID) {
        guard let dex else { return }
        record(trainer.setEverstone(held, of: raiseID, dex: dex))
        persist()
    }

    /// Buys another individual of a base-form species already in the collection.
    @discardableResult
    func hatchAnother(entryID: Int, paying payment: Trainer.Payment) throws -> [GameEvent] {
        guard let dex else { return [] }
        let events = try trainer.hatchAnother(
            entryID: entryID, paying: payment, coinsEarned: coinsEarned, dex: dex, using: &rng)
        record(events)
        persist()
        return events
    }

    /// Exchanges two team slots. What a drag from one card onto another means.
    func swapSlots(_ one: UUID, _ other: UUID) throws {
        try trainer.swapSlots(one, other)
        persist()
    }

    /// Brings an individual back out of the PC, at its stored level.
    func resume(raiseID: UUID) throws {
        try trainer.addToTeam(raiseID: raiseID)
        persist()
    }

    /// Sends an individual to the PC. Nothing it earned is lost.
    func sendToPC(raiseID: UUID) {
        guard trainer.removeFromTeam(raiseID: raiseID) else { return }
        persist()
    }

    /// Moves a member to slot 1: the full XP share, and the menu bar.
    func promoteToLead(raiseID: UUID) throws {
        try trainer.promoteToLead(raiseID: raiseID)
        persist()
    }

    /// The last thing worth stopping to look at, or nil once dismissed.
    private(set) var celebration: Celebration?

    func dismissCelebration() { celebration = nil }

    /// Turns an acquisition into something the popover can put on screen.
    ///
    /// Read *after* the trainer has been mutated, because "which slot did it go
    /// into" is a question about the team as it now stands. `roster.last` is the
    /// individual this acquisition created: every path appends one, and it lands
    /// in the PC rather than on the team only when all six slots were taken.
    private func celebrate(_ events: [GameEvent]) {
        guard let caught = events.compactMap({ event -> CatchEvent? in
            if case .caught(let catchEvent) = event { catchEvent } else { nil }
        }).last else { return }
        // Evolutions announce themselves through the notifier, because they happen
        // on their own while the window is shut.
        if case .evolution = caught.source { return }

        let dust = events.compactMap { event -> Int? in
            if case .duplicate(_, let paid) = event { paid } else { nil }
        }.last ?? 0
        let duplicate = events.contains { if case .duplicate = $0 { true } else { false } }
        let newcomer = trainer.roster.last
        celebration = Celebration(
            entryID: caught.entryID,
            variant: caught.variant,
            source: caught.source,
            isNew: !duplicate,
            dust: dust,
            slot: newcomer.flatMap { trainer.team.firstIndex(of: $0.id) })
    }

    private func record(_ events: [GameEvent]) {
        guard !events.isEmpty else { return }
        recentEvents = (events.reversed() + recentEvents).prefix(20).map(\.self)
        celebrate(events)
        // Fire and forget. Most events are silent by design, and a notification
        // that fails to post must never stop a hatch from being recorded.
        if let dex {
            Task { [notifier] in await notifier.post(events, dex: dex) }
        }
    }

    // MARK: - Persistence

    /// Restores the collection, and **refuses to quietly start over**.
    ///
    /// The obvious version, `try? decode` falling through to an empty `Trainer`,
    /// cannot tell "no save yet" from "save I could not read", and the next
    /// `persist()` writes the empty one straight over the real one. Every schema
    /// change would then be one field away from deleting a collection that
    /// nothing can rebuild: the usage ledger can be recovered by rescanning
    /// `~/.claude`, a Pokemon caught last week cannot.
    ///
    /// So an unreadable save is copied aside before anything overwrites it, and
    /// the reason is printed rather than swallowed.
    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        do {
            trainer = try JSONDecoder().decode(Trainer.self, from: data)
        } catch {
            let quarantine = stateURL.deletingPathExtension()
                .appendingPathExtension("unreadable.json")
            try? data.write(to: quarantine, options: .atomic)
            print("PokeBar: could not read \(stateURL.lastPathComponent): \(error)")
            print("PokeBar: the previous contents are at \(quarantine.path)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(trainer) else { return }
        // Atomic, for the same reason the usage ledger is: a torn write here
        // loses the collection, and there is no way to re-derive it.
        try? data.write(to: stateURL, options: .atomic)
    }
}
