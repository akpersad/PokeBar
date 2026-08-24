import Foundation

/// The player's durable state, and every rule that changes it.
///
/// A plain `Codable` struct with no clock, no RNG and no I/O of its own: dates
/// and generators are passed in, so the whole game loop is testable without a
/// running app. `GameMonitor` is the only thing that owns one, persists it, and
/// decides what to do with the events it returns.
///
/// **Coins are earned outside this type and spent inside it.** The ledger's coin
/// total is frozen at credit time and must never be recomputed, so the trainer
/// records only what it has *spent* and derives the balance. That way a pricing
/// refresh can never reach backwards and take a purchase away.
struct Trainer: Codable, Sendable, Equatable {

    var log = CatchLog()
    /// The one Pokemon currently gaining XP. One at a time, which is the real
    /// constraint in this game.
    var active: Raise?
    var coinsSpent = 0
    /// Minted only by duplicate egg hatches. Buys choice, never volume.
    var dust = 0
    /// Item slug -> count. Evolution stones and the Linking Cord.
    var inventory: [String: Int] = [:]
    var hasShinyCharm = false

    enum GameError: Error, Equatable, CustomStringConvertible {
        case notEnoughCoins(needed: Int, have: Int)
        case notEnoughDust(needed: Int, have: Int)
        case nothingActive
        case unknownEntry(Int)
        case alreadyOwned
        case notOwned
        case missingItem(String)
        case evolutionNotAvailable
        case emptyPool

        var description: String {
            switch self {
            case .notEnoughCoins(let needed, let have): "needs \(needed) coins, have \(have)"
            case .notEnoughDust(let needed, let have): "needs \(needed) Dust, have \(have)"
            case .nothingActive: "no Pokemon is being raised"
            case .unknownEntry(let id): "no dex entry \(id)"
            case .alreadyOwned: "already in the collection"
            case .notOwned: "not in the collection yet"
            case .missingItem(let slug): "missing \(slug)"
            case .evolutionNotAvailable: "that evolution is not available"
            case .emptyPool: "the hatch pool is empty"
            }
        }
    }

    // MARK: - Balances

    /// Coins in hand. `earned` comes from the ledger and is frozen history.
    func coins(earned: Int) -> Int { max(0, earned - coinsSpent) }

    func count(ofItem slug: String) -> Int { inventory[slug] ?? 0 }

    private mutating func spend(coins amount: Int, earned: Int) throws {
        let have = coins(earned: earned)
        guard have >= amount else { throw GameError.notEnoughCoins(needed: amount, have: have) }
        coinsSpent += amount
    }

    private mutating func spend(dust amount: Int) throws {
        guard dust >= amount else { throw GameError.notEnoughDust(needed: amount, have: dust) }
        dust -= amount
    }

    // MARK: - XP

    /// Credits the tokens' worth of XP to whatever is being raised.
    ///
    /// Every weighted token grants XP here *and* mints a coin in the ledger. They
    /// are parallel derivations of the same usage, never a shared pool, so there
    /// is no allocation choice to make: you train and save at the same time.
    ///
    /// Crediting with nothing active is a no-op rather than an error. Coins still
    /// accrue, which is the correct behaviour for a machine that was busy while
    /// its last Pokemon was already graduated.
    @discardableResult
    mutating func credit(
        weightedTokens: Double, dex: Pokedex, now: Date = Date()
    ) -> [GameEvent] {
        guard weightedTokens > 0, var raise = active else { return [] }
        let before = raise.level
        let ceiling = Double(XPCurve.totalXP(forLevel: XPCurve.maxLevel))
        raise.totalXP = min(ceiling, raise.totalXP + XPCurve.xp(forWeightedTokens: weightedTokens))
        active = raise

        var events: [GameEvent] = []
        let after = raise.level
        if after > before { events.append(.levelledUp(to: after)) }
        events += resolveEvolutions(dex: dex, now: now)
        if after >= XPCurve.maxLevel && before < XPCurve.maxLevel, let entryID = active?.entryID {
            events.append(.graduated(entryID: entryID))
        }
        return events
    }

    /// 10,000 XP in one go. The most important coin sink, because it buys the
    /// scarce resource: raising time, not more eggs.
    @discardableResult
    mutating func useRareCandy(dex: Pokedex, now: Date = Date()) throws -> [GameEvent] {
        guard active != nil else { throw GameError.nothingActive }
        guard count(ofItem: Self.rareCandySlug) > 0 else {
            throw GameError.missingItem(Self.rareCandySlug)
        }
        inventory[Self.rareCandySlug] = count(ofItem: Self.rareCandySlug) - 1
        return credit(
            weightedTokens: Prices.rareCandyXP * XPCurve.weightedTokensPerXP, dex: dex, now: now)
    }

    static let rareCandySlug = "rare-candy"

    // MARK: - Evolution

    /// Fires every evolution the current level has unlocked, in a chain.
    ///
    /// Only edges that need **no item** fire on their own, which is the games'
    /// behaviour and also the only safe rule: a stone is a thing you choose to
    /// use. Where several item-free edges are satisfied at once the choice is the
    /// player's and nothing fires. That is not an edge case worth glossing over:
    /// Eevee has three at level 36, Wurmple two at 7, Tyrogue three at 20.
    ///
    /// Loops because one credit can cross several thresholds. A Rare Candy at
    /// level 5 takes a Caterpie past both 7 and 10.
    private mutating func resolveEvolutions(dex: Pokedex, now: Date) -> [GameEvent] {
        var events: [GameEvent] = []
        while let raise = active, let entry = dex.entry(id: raise.entryID) {
            let ready = entry.evolutions.filter {
                $0.item == nil && raise.level >= $0.minLevel
            }
            guard let edge = ready.first, ready.count == 1 else {
                if ready.count > 1 {
                    events.append(
                        .evolutionChoice(from: entry.id, options: ready.map(\.to)))
                }
                break
            }
            guard let event = apply(edge: edge, to: entry, dex: dex, now: now) else { break }
            events += event
        }
        return events
    }

    /// Applies one edge to the active Pokemon: swaps its entry, logs the new form
    /// as a catch, and keeps its shininess and sex.
    ///
    /// Shininess carrying over is the point: evolving a shiny Charmander is how
    /// the shiny Charizard slot gets filled, and there is no other way to fill it.
    private mutating func apply(
        edge: Evolution, to entry: DexEntry, dex: Pokedex, now: Date
    ) -> [GameEvent]? {
        guard var raise = active, let target = dex.entry(id: edge.to) else { return nil }
        raise.entryID = target.id
        active = raise

        let event = CatchEvent(
            entryID: target.id,
            variant: raise.gender.spriteVariant(shiny: raise.shiny, for: target),
            gender: raise.gender, date: now, source: .evolution(from: entry.id))
        // An evolution into something already owned pays no Dust. Dust is minted
        // by eggs, and an evolution is not a roll: the target was determined the
        // moment the edge was taken.
        log.append(event)
        return [.evolved(from: entry.id, to: target.id), .caught(event)]
    }

    /// Edges the player could take right now by spending an item they hold, plus
    /// the ones a choice is pending on. What the UI offers as buttons.
    func pendingEvolutions(dex: Pokedex) -> [(edge: Evolution, target: DexEntry)] {
        guard let raise = active, let entry = dex.entry(id: raise.entryID) else { return [] }
        return dex.availableEvolutions(
            of: entry, atLevel: raise.level, items: Set(inventory.filter { $0.value > 0 }.keys))
    }

    /// Takes an evolution the player chose, consuming its item if it needs one.
    @discardableResult
    mutating func evolveActive(
        into targetID: Int, dex: Pokedex, now: Date = Date()
    ) throws -> [GameEvent] {
        guard let raise = active else { throw GameError.nothingActive }
        guard let entry = dex.entry(id: raise.entryID) else {
            throw GameError.unknownEntry(raise.entryID)
        }
        guard let edge = entry.evolutions.first(where: { $0.to == targetID }),
              raise.level >= edge.minLevel
        else { throw GameError.evolutionNotAvailable }
        if let item = edge.item {
            guard count(ofItem: item) > 0 else { throw GameError.missingItem(item) }
            inventory[item] = count(ofItem: item) - 1
        }
        var events = apply(edge: edge, to: entry, dex: dex, now: now) ?? []
        // A stone can leave the new form immediately eligible for a level edge it
        // already passed.
        events += resolveEvolutions(dex: dex, now: now)
        return events
    }

    // MARK: - Hatching

    /// Buys an egg and opens it.
    ///
    /// A duplicate is judged on the *sprite*, not the species, so a shiny Pikachu
    /// is new even when Pikachu is not. Duplicates mint Dust scaled on the raw
    /// capture rate, which is what funds the guaranteed path: random draws alone
    /// need a median 110,218 hatches to see every hatchable entry once.
    @discardableResult
    mutating func hatch(
        coinsEarned: Int, dex: Pokedex, using rng: inout some RandomNumberGenerator,
        now: Date = Date()
    ) throws -> [GameEvent] {
        try spend(coins: Prices.egg, earned: coinsEarned)
        guard let entry = HatchRoll.draw(from: dex.hatchable, using: &rng) else {
            throw GameError.emptyPool
        }
        return obtain(entry, source: .hatch, dex: dex, using: &rng, now: now)
    }

    /// Rolls the variant, logs it, pays Dust if it filled nothing, and starts
    /// raising it if nothing else is.
    private mutating func obtain(
        _ entry: DexEntry, source: CatchSource, dex: Pokedex,
        using rng: inout some RandomNumberGenerator, now: Date
    ) -> [GameEvent] {
        let shiny = HatchRoll.isShiny(charm: hasShinyCharm, using: &rng)
        let gender = HatchRoll.gender(for: entry, using: &rng)
        let event = CatchEvent(
            entryID: entry.id, variant: gender.spriteVariant(shiny: shiny, for: entry),
            gender: gender, date: now, source: source)
        let isNew = log.append(event)

        var events: [GameEvent] = [.caught(event)]
        if !isNew {
            // Only eggs mint Dust. A re-roll that pays out would be an exploit
            // rather than a mechanic: a legendary re-roll costs 25 Dust and its
            // duplicate is worth 85, so it would print money on the rarest
            // entries, which are exactly the ones the price is protecting.
            if source == .hatch {
                let paid = Prices.dust(forCaptureRate: entry.captureRate)
                dust += paid
                events.append(.duplicate(entryID: entry.id, dust: paid))
            } else {
                events.append(.duplicate(entryID: entry.id, dust: 0))
            }
        }
        if active == nil {
            active = Raise(entryID: entry.id, shiny: shiny, gender: gender, startedAt: now)
        }
        return events
    }

    /// Names an entry and buys it outright, in its plain sprite.
    ///
    /// This is the only reason the dex is completable at all. Weighted random
    /// draws are the coupon-collector problem with an 85x spread, and no price
    /// tuning fixes that; luck handles the bulk and only this closes the tail.
    /// Shiny and female slots are deliberately *not* purchasable here, because
    /// then nothing would be left to hunt: those come from `reroll`.
    @discardableResult
    mutating func targetedPick(
        entryID: Int, dex: Pokedex, now: Date = Date()
    ) throws -> [GameEvent] {
        guard let entry = dex.entry(id: entryID) else { throw GameError.unknownEntry(entryID) }
        let gender = HatchRoll.canonicalGender(for: entry)
        let variant = gender.spriteVariant(shiny: false, for: entry)
        guard !log.owns(VariantSlot(entryID: entryID, variant: variant)) else {
            throw GameError.alreadyOwned
        }
        try spend(dust: Prices.targetedPick(entry.rarity))

        let event = CatchEvent(
            entryID: entry.id, variant: variant, gender: gender, date: now,
            source: .targetedPick)
        log.append(event)
        if active == nil {
            active = Raise(entryID: entry.id, shiny: false, gender: gender, startedAt: now)
        }
        return [.caught(event)]
    }

    /// Hatches a species you already own again, for a shot at a variant you do
    /// not. This is the shiny hunt, and it is the same mechanism as the targeted
    /// pick aimed at one species instead of the whole pool.
    @discardableResult
    mutating func reroll(
        entryID: Int, dex: Pokedex, using rng: inout some RandomNumberGenerator,
        now: Date = Date()
    ) throws -> [GameEvent] {
        guard let entry = dex.entry(id: entryID) else { throw GameError.unknownEntry(entryID) }
        guard log.seenEntryIDs.contains(entryID) else { throw GameError.notOwned }
        try spend(dust: Prices.reroll(entry.rarity))
        return obtain(entry, source: .reroll, dex: dex, using: &rng, now: now)
    }

    // MARK: - Switching

    /// Starts raising something already in the collection, from level 1.
    ///
    /// Free and ungated on purpose. With 570 hatchable entries drawn at random,
    /// hatching something you do not care about is the common case rather than
    /// the exception, and a level gate punishes the player for the game's own
    /// randomness. The cost is already built in and needs no rule: the current
    /// individual's levels are abandoned. Nothing is lost from the collection,
    /// only from the individual.
    mutating func setActive(
        entryID: Int, shiny: Bool = false, gender: Gender? = nil, dex: Pokedex,
        now: Date = Date()
    ) throws {
        guard let entry = dex.entry(id: entryID) else { throw GameError.unknownEntry(entryID) }
        let sex = gender ?? HatchRoll.canonicalGender(for: entry)
        guard log.owns(VariantSlot(
            entryID: entryID, variant: sex.spriteVariant(shiny: shiny, for: entry)))
        else { throw GameError.notOwned }
        active = Raise(entryID: entryID, shiny: shiny, gender: sex, startedAt: now)
    }

    // MARK: - Shop

    /// One purchasable line. Stones are generated from the dex rather than listed
    /// here, because the manifest already knows which 23 exist and a hand-written
    /// list would drift from it.
    /// One purchasable line. An egg is not one of them: an egg is opened the
    /// moment it is paid for, so `hatch` charges for it directly and there is
    /// never an unopened egg to hold.
    enum ShopItem: Equatable, Sendable {
        case rareCandy
        case item(slug: String, name: String)
        case shinyCharm

        var priceInCoins: Int {
            switch self {
            case .rareCandy: Prices.rareCandy
            case .item(let slug, _): slug == "linking-cord" ? Prices.linkingCord
                                                            : Prices.evolutionStone
            case .shinyCharm: Prices.shinyCharm
            }
        }
    }

    /// Buys an item into the inventory.
    mutating func buy(_ item: ShopItem, coinsEarned: Int) throws {
        switch item {
        case .shinyCharm:
            guard !hasShinyCharm else { throw GameError.alreadyOwned }
            try spend(coins: item.priceInCoins, earned: coinsEarned)
            hasShinyCharm = true
        case .rareCandy:
            try spend(coins: item.priceInCoins, earned: coinsEarned)
            inventory[Self.rareCandySlug, default: 0] += 1
        case .item(let slug, _):
            try spend(coins: item.priceInCoins, earned: coinsEarned)
            inventory[slug, default: 0] += 1
        }
    }
}
