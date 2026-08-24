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
    var active: Raise? { trainer.active }
    var log: CatchLog { trainer.log }

    /// The entry being raised, resolved. Nil before the first hatch.
    var activeEntry: DexEntry? {
        guard let dex, let active else { return nil }
        return dex.entry(id: active.entryID)
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
        if let active, let entry = dex.entry(id: active.entryID) {
            return (entry, active.variant(in: dex))
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

    /// Evolutions the player could take right now, including ones waiting on a
    /// choice. What the popover offers as buttons.
    var pendingEvolutions: [(edge: Evolution, target: DexEntry)] {
        guard let dex else { return [] }
        return trainer.pendingEvolutions(dex: dex)
    }

    /// Settles notification permission once the player has something to raise.
    ///
    /// Called from the status item, which is the one view alive for the whole run,
    /// so this does not depend on the popover ever being opened.
    func prepareNotifications() async {
        guard trainer.active != nil else { return }
        await notifier.requestIfNeeded()
    }

    // MARK: - Writing

    /// Credits XP against the same tokens that minted coins.
    ///
    /// Called from the usage loop on every scan that added anything. A quiet
    /// minute credits nothing and writes nothing.
    func credit(weightedTokens: Double, coinsEarned: Int) {
        self.coinsEarned = coinsEarned
        guard let dex, weightedTokens > 0 else { return }
        record(trainer.credit(weightedTokens: weightedTokens, dex: dex))
        persist()
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

    func useRareCandy() throws {
        guard let dex else { return }
        record(try trainer.useRareCandy(dex: dex))
        persist()
    }

    func evolveActive(into targetID: Int) throws {
        guard let dex else { return }
        record(try trainer.evolveActive(into: targetID, dex: dex))
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

    func setActive(entryID: Int, shiny: Bool = false, gender: Gender? = nil) throws {
        guard let dex else { return }
        try trainer.setActive(entryID: entryID, shiny: shiny, gender: gender, dex: dex)
        persist()
    }

    private func record(_ events: [GameEvent]) {
        guard !events.isEmpty else { return }
        recentEvents = (events.reversed() + recentEvents).prefix(20).map(\.self)
        // Fire and forget. Most events are silent by design, and a notification
        // that fails to post must never stop a hatch from being recorded.
        if let dex {
            Task { [notifier] in await notifier.post(events, dex: dex) }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(Trainer.self, from: data)
        else { return }
        trainer = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(trainer) else { return }
        // Atomic, for the same reason the usage ledger is: a torn write here
        // loses the collection, and there is no way to re-derive it.
        try? data.write(to: stateURL, options: .atomic)
    }
}
