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

    /// Every individual ever raised, oldest first, levels intact.
    ///
    /// **Append-only.** Nothing here is ever deleted, the same rule the two logs
    /// follow: benching changes `team`, not this. That is the point of the type
    /// existing at all. v1 held a single `active: Raise?` and threw it away on a
    /// switch, and losing a week of Charizard for trying a Pikachu is the thing
    /// the user asked to have back (DECISIONS.md).
    ///
    /// Identity is `Raise.id`, never a `VariantSlot`: a `Raise` mutates its own
    /// `entryID` as it evolves, so a slot-keyed store would have to be rekeyed on
    /// every evolution. Two Charmander raised separately are two rows here with
    /// two levels, which is what "my progress on this one" means; what the
    /// *collection* owns stays the log's question, per sprite.
    var roster: [Raise] = []

    /// Who is gaining XP, in order, by `Raise.id`. Slot 1 is the lead, and is
    /// what the status item draws.
    ///
    /// Only slot 1 earns anything today. Distributing one credit across the whole
    /// team is step 2 of PLAN-v2.md; the cap is here now so the save format does
    /// not have to change again when it lands.
    ///
    /// The one part of the save that can be internally inconsistent, because it
    /// is a list of references. It is sanitised on decode rather than checked at
    /// every use site.
    var team: [UUID] = []

    /// Six, as the games do it.
    static let teamCapacity = 6

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
        case notStartingOut
        case teamFull
        case alreadyOnTeam
        case unknownIndividual(UUID)

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
            case .notStartingOut: "the first pick has already been made"
            case .teamFull: "the team is full at \(Trainer.teamCapacity)"
            case .alreadyOnTeam: "already on the team"
            case .unknownIndividual(let id): "no individual \(id)"
            }
        }
    }

    // MARK: - Balances

    /// Coins in hand. `earned` comes from the ledger and is frozen history.
    func coins(earned: Int) -> Int { max(0, earned - coinsSpent) }

    func count(ofItem slug: String) -> Int { inventory[slug] ?? 0 }

    // MARK: - The roster and the team

    /// Team slot 1: the lead, and the only member gaining XP until step 2.
    var lead: Raise? { team.first.flatMap(raise(id:)) }

    /// v1's name for the lead, kept because the popover and the status item still
    /// speak in one Pokemon. Step 4 gives the team a UI and takes this with it.
    var active: Raise? { lead }

    func raise(id: UUID) -> Raise? { roster.first { $0.id == id } }

    /// The team, resolved and in slot order.
    var teamRaises: [Raise] { team.compactMap(raise(id:)) }

    /// Everyone in the roster who is not currently training. Nothing has been
    /// lost: this is where a benched Charizard waits, at the level it reached.
    var benched: [Raise] { roster.filter { !team.contains($0.id) } }

    private func index(of raiseID: UUID) -> Int? {
        roster.firstIndex { $0.id == raiseID }
    }

    private mutating func spend(coins amount: Int, earned: Int) throws {
        let have = coins(earned: earned)
        guard have >= amount else { throw GameError.notEnoughCoins(needed: amount, have: have) }
        coinsSpent += amount
    }

    private mutating func spend(dust amount: Int) throws {
        guard dust >= amount else { throw GameError.notEnoughDust(needed: amount, have: dust) }
        dust -= amount
    }

    /// The levels the Dex marks, lowest first.
    ///
    /// Halfway and done. Both are *display* thresholds and nothing else keys off
    /// them: no notification, no reward, no rule. That is deliberate, because the
    /// open question is still whether level 100 should pay out at all, and adding
    /// a second payout before answering the first would make it harder to answer.
    ///
    /// 50 rather than any other number because the curve is quadratic:
    /// `totalXP(50)` is 250,000 of the 1,000,000 a full climb costs, so the
    /// silver ring lands at a quarter of the work, not half of it. It marks the
    /// halfway point in *levels*, which is what the player watches.
    static let milestoneLevels = [50, XPCurve.maxLevel]

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
        guard weightedTokens > 0, let leadID = team.first else { return [] }
        // Slot 1 only, and at the full rate: identical to v1. Handing the same
        // credit to slots 2 to 6 as well is step 2, and it calls `grant` once per
        // member rather than changing anything below it.
        return grant(
            xp: XPCurve.xp(forWeightedTokens: weightedTokens), to: leadID, dex: dex, now: now)
    }

    /// One individual's share of a credit: XP, then evolutions, then marks.
    ///
    /// Split out of `credit` because the pipeline is per individual and the
    /// distribution is not, so step 2 can hand out six shares without touching
    /// any of the rules. Everything here is scoped to `raiseID`, including the
    /// milestone it records.
    @discardableResult
    private mutating func grant(
        xp: Double, to raiseID: UUID, dex: Pokedex, now: Date
    ) -> [GameEvent] {
        guard let index = index(of: raiseID) else { return [] }
        let before = roster[index].level
        let ceiling = Double(XPCurve.totalXP(forLevel: XPCurve.maxLevel))
        roster[index].totalXP = min(ceiling, roster[index].totalXP + xp)
        let after = roster[index].level

        var events: [GameEvent] = []
        if after > before { events.append(.levelledUp(to: after)) }
        events += resolveEvolutions(of: raiseID, dex: dex, now: now)
        // Read the roster again rather than reusing a copy from above: an
        // evolution resolved just now may have changed what this individual is,
        // and it reaches the mark as whatever it is now.
        //
        // Every level crossed, not just the highest. One credit can clear both
        // marks at once (a Rare Candy, or a quiet hour on a busy machine), and
        // the log should say it passed 50 rather than silently skipping it. Same
        // reason `resolveEvolutions` loops.
        if let climber = raise(id: raiseID) {
            for level in Self.milestoneLevels where before < level && after >= level {
                if let entry = dex.entry(id: climber.entryID) {
                    log.recordMilestone(
                        MilestoneEvent(
                            entryID: climber.entryID,
                            variant: climber.gender.spriteVariant(
                                shiny: climber.shiny, for: entry),
                            raiseID: climber.id,
                            level: level,
                            date: now))
                }
                if level >= XPCurve.maxLevel {
                    events.append(.graduated(entryID: climber.entryID))
                }
            }
        }
        return events
    }

    /// 10,000 XP in one go. The most important coin sink, because it buys the
    /// scarce resource: raising time, not more eggs.
    @discardableResult
    mutating func useRareCandy(dex: Pokedex, now: Date = Date()) throws -> [GameEvent] {
        guard lead != nil else { throw GameError.nothingActive }
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
    /// behaviour and also the only safe rule: a stone is a thing you choose to use.
    ///
    /// **An entry that branches never auto-evolves, even when only one branch is
    /// currently satisfied.** The narrower rule, "fire when exactly one branch is
    /// *ready*", looks equivalent and silently locks targets out. Two entries prove
    /// it: Nincada offers Ninjask at 20 and Shedinja at 36, and Dartrix offers
    /// Decidueye at 34 and Hisuian Decidueye at 36. Under the narrower rule the
    /// earlier edge fires the moment it is reached, the individual stops being a
    /// Dartrix, and the level-36 target can never be reached by raising at all.
    /// Both remained reachable on paper, because the *graph* still contains the
    /// edge, which is exactly why the generator's reachability assertion did not
    /// catch this and a test had to.
    ///
    /// So: one item-free edge in total means it fires; more than one means the
    /// choice is the player's and it waits. Eevee has three at level 36, Wurmple
    /// two at 7, Tyrogue three at 20, and now Nincada and Dartrix wait too.
    ///
    /// Loops because one credit can cross several thresholds. A Rare Candy at
    /// level 5 takes a Caterpie past both 7 and 10.
    private mutating func resolveEvolutions(
        of raiseID: UUID, dex: Pokedex, now: Date
    ) -> [GameEvent] {
        var events: [GameEvent] = []
        while let raise = raise(id: raiseID), !raise.everstone,
              let entry = dex.entry(id: raise.entryID)
        {
            let itemFree = entry.evolutions.filter { $0.item == nil }
            let ready = itemFree.filter { raise.level >= $0.minLevel }
            guard itemFree.count == 1, let edge = ready.first else {
                if !ready.isEmpty, itemFree.count > 1 {
                    events.append(
                        .evolutionChoice(from: entry.id, options: ready.map(\.to)))
                }
                break
            }
            guard let event = apply(edge: edge, to: entry, of: raiseID, dex: dex, now: now)
            else { break }
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
        edge: Evolution, to entry: DexEntry, of raiseID: UUID, dex: Pokedex, now: Date
    ) -> [GameEvent]? {
        guard let index = index(of: raiseID), let target = dex.entry(id: edge.to) else {
            return nil
        }
        let raise = roster[index]
        roster[index].entryID = target.id

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

    /// Puts an Everstone on the active Pokemon, or takes it off.
    ///
    /// Taking it off resolves immediately, and that is the whole design: a hold
    /// **queues** evolutions rather than cancelling them. A Caterpie held past 7
    /// and 10 becomes a Butterfree the moment the stone comes off, in order, so
    /// nothing is ever lost by waiting and there is no point of no return.
    @discardableResult
    mutating func setEverstone(_ held: Bool, dex: Pokedex, now: Date = Date()) -> [GameEvent] {
        guard let leadID = team.first else { return [] }
        return setEverstone(held, of: leadID, dex: dex, now: now)
    }

    /// The same, for one named individual. A benched Pokemon keeps the stone it
    /// was holding, because it is that Pokemon's item and not the trainer's.
    @discardableResult
    mutating func setEverstone(
        _ held: Bool, of raiseID: UUID, dex: Pokedex, now: Date = Date()
    ) -> [GameEvent] {
        guard let index = index(of: raiseID), roster[index].everstone != held else { return [] }
        roster[index].everstone = held
        return held ? [] : resolveEvolutions(of: raiseID, dex: dex, now: now)
    }

    /// Edges the player could take right now by spending an item they hold, plus
    /// the ones a choice is pending on. What the UI offers as buttons.
    func pendingEvolutions(dex: Pokedex) -> [(edge: Evolution, target: DexEntry)] {
        guard let raise = lead, let entry = dex.entry(id: raise.entryID) else { return [] }
        return dex.availableEvolutions(
            of: entry, atLevel: raise.level, items: Set(inventory.filter { $0.value > 0 }.keys))
    }

    /// Takes an evolution the player chose, consuming its item if it needs one.
    @discardableResult
    mutating func evolveActive(
        into targetID: Int, dex: Pokedex, now: Date = Date()
    ) throws -> [GameEvent] {
        guard let raise = lead else { throw GameError.nothingActive }
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
        var events = apply(edge: edge, to: entry, of: raise.id, dex: dex, now: now) ?? []
        // A stone can leave the new form immediately eligible for a level edge it
        // already passed.
        events += resolveEvolutions(of: raise.id, dex: dex, now: now)
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
        // Nothing that acquires a Pokemon disturbs a raise in progress: it starts
        // one only when nothing is training. That is what makes a shiny hunt
        // usable, because the point is to keep fishing while the current one
        // climbs.
        if team.isEmpty {
            beginRaising(entryID: entry.id, shiny: shiny, gender: gender, now: now)
        }
        return events
    }

    /// The free first pick, from the 27 starters.
    ///
    /// Exists because the first thirty seconds decide whether anyone comes back,
    /// and a weighted draw over 570 entries is overwhelmingly likely to open with
    /// something nobody asked for. Choosing your own first partner is how every
    /// one of these games starts, and it costs the economy nothing: one entry out
    /// of 1,083, on a curve where the constraint is raising time.
    ///
    /// Once only, and the guard is an empty log rather than a flag: "have I ever
    /// caught anything" is a question the log already answers, and a separate
    /// boolean could disagree with it.
    ///
    /// The variant is still rolled. A shiny starter at 1/64 is a better story than
    /// a guaranteed plain one, and it costs nothing to allow.
    @discardableResult
    mutating func chooseStarter(
        entryID: Int, dex: Pokedex, using rng: inout some RandomNumberGenerator,
        now: Date = Date()
    ) throws -> [GameEvent] {
        guard log.events.isEmpty else { throw GameError.notStartingOut }
        guard let entry = dex.entry(id: entryID),
              Pokedex.starterIDs.contains(entryID)
        else { throw GameError.unknownEntry(entryID) }
        return obtain(entry, source: .starter, dex: dex, using: &rng, now: now)
    }

    /// Whether the first pick is still to be made. Drives the empty state.
    var needsStarter: Bool { log.events.isEmpty }

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
        if team.isEmpty {
            beginRaising(entryID: entry.id, shiny: false, gender: gender, now: now)
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

    /// Appends a new individual and puts it straight on the team.
    ///
    /// Takes no view on ownership or capacity: every caller has already answered
    /// those, and the two acquisition paths have no capacity question because they
    /// only reach here when the team is empty.
    @discardableResult
    private mutating func beginRaising(
        entryID: Int, shiny: Bool, gender: Gender, now: Date
    ) -> UUID {
        let raise = Raise(entryID: entryID, shiny: shiny, gender: gender, startedAt: now)
        roster.append(raise)
        team.append(raise.id)
        return raise.id
    }

    /// Validates that the player owns the sprite being asked for, and resolves
    /// the sex. Shared by the two ways of starting, so neither can drift.
    private func ownedVariant(
        entryID: Int, shiny: Bool, gender: Gender?, dex: Pokedex
    ) throws -> Gender {
        guard let entry = dex.entry(id: entryID) else { throw GameError.unknownEntry(entryID) }
        let sex = gender ?? HatchRoll.canonicalGender(for: entry)
        guard log.owns(VariantSlot(
            entryID: entryID, variant: sex.spriteVariant(shiny: shiny, for: entry)))
        else { throw GameError.notOwned }
        return sex
    }

    /// Puts an individual already in the roster back to work, **at the level it
    /// stopped at**.
    ///
    /// This is the verb v1 could not say. `setActive(entryID:)` took a species and
    /// could only ever mean "start a fresh one", so "bring my Charizard back" and
    /// "start a second Charmander" were the same call and the first one was
    /// impossible.
    mutating func addToTeam(raiseID: UUID) throws {
        guard raise(id: raiseID) != nil else { throw GameError.unknownIndividual(raiseID) }
        guard !team.contains(raiseID) else { throw GameError.alreadyOnTeam }
        guard team.count < Self.teamCapacity else { throw GameError.teamFull }
        team.append(raiseID)
    }

    /// Benches an individual without deleting it. It keeps its level, its XP and
    /// the stone it was holding, and can be brought back by `addToTeam`.
    @discardableResult
    mutating func removeFromTeam(raiseID: UUID) -> Bool {
        guard let slot = team.firstIndex(of: raiseID) else { return false }
        team.remove(at: slot)
        return true
    }

    /// Starts a brand new individual of an entry the player owns, at level 1.
    ///
    /// Free and ungated on purpose. With 570 hatchable entries drawn at random,
    /// hatching something you do not care about is the common case rather than
    /// the exception, and a level gate punishes the player for the game's own
    /// randomness. It no longer costs anything either: whatever was training keeps
    /// its levels on the bench.
    @discardableResult
    mutating func startRaising(
        entryID: Int, shiny: Bool = false, gender: Gender? = nil, dex: Pokedex,
        now: Date = Date()
    ) throws -> UUID {
        let sex = try ownedVariant(entryID: entryID, shiny: shiny, gender: gender, dex: dex)
        guard team.count < Self.teamCapacity else { throw GameError.teamFull }
        return beginRaising(entryID: entryID, shiny: shiny, gender: sex, now: now)
    }

    /// Makes one individual of an entry the whole team: v1's switch, minus the
    /// loss. **Resumes rather than restarts** where it can.
    ///
    /// The popover offers exactly one "raise this one" button per entry, so this
    /// is the only switch the UI can currently express, and it has to answer
    /// "which individual" on the player's behalf. It answers it the way the player
    /// means it: the **highest-level** individual of that exact sprite, because
    /// "raise Charizard" said in front of a level 40 Charizard is not a request
    /// for a new level 1 one. Nothing else in the roster is touched.
    ///
    /// Transitional in one respect only: it clears the other slots. Step 4 of
    /// PLAN-v2.md gives the team six slots and its own controls, and then callers
    /// use `addToTeam` and `startRaising` directly and this goes away.
    @discardableResult
    mutating func switchTo(
        entryID: Int, shiny: Bool = false, gender: Gender? = nil, dex: Pokedex,
        now: Date = Date()
    ) throws -> UUID {
        // Throws before anything mutates. A refused switch that had already
        // emptied the team would be the worst kind of bug here: silent, and it
        // stops XP accruing.
        let sex = try ownedVariant(entryID: entryID, shiny: shiny, gender: gender, dex: dex)
        let resumable = roster
            .filter { $0.entryID == entryID && $0.shiny == shiny && $0.gender == sex }
            .max { $0.totalXP < $1.totalXP }

        team.removeAll()
        guard let resumable else {
            return beginRaising(entryID: entryID, shiny: shiny, gender: sex, now: now)
        }
        team.append(resumable.id)
        return resumable.id
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

    // MARK: - Persistence

    private enum CodingKeys: String, CodingKey {
        case log, roster, team, coinsSpent, dust, inventory, hasShinyCharm
        /// v1's single individual. **Read forever, never written**, the pattern
        /// `CatchLog` already uses for `graduations`.
        case active
    }

    init() {}

    /// Hand-written for invariant 23, and for the migration off `active`.
    ///
    /// The new keys use `decodeIfPresent` with a default, because the synthesized
    /// decoder throws on a missing key even where the property has one, and
    /// `GameMonitor` cannot tell "no save yet" from "save I could not read".
    ///
    /// **The old keys stay required, deliberately.** Making every field optional
    /// looks like the safer move and is the opposite: a save that decoded to a
    /// brand new empty trainer would never be quarantined, and the next `persist`
    /// would write it over the real one. Every save ever written carries these
    /// five, so a file missing them is not a save.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        log = try c.decode(CatchLog.self, forKey: .log)
        coinsSpent = try c.decode(Int.self, forKey: .coinsSpent)
        dust = try c.decode(Int.self, forKey: .dust)
        inventory = try c.decode([String: Int].self, forKey: .inventory)
        hasShinyCharm = try c.decode(Bool.self, forKey: .hasShinyCharm)

        if let saved = try c.decodeIfPresent([Raise].self, forKey: .roster) {
            roster = saved
            team = try c.decodeIfPresent([UUID].self, forKey: .team) ?? []
        } else if let legacy = try c.decodeIfPresent(Raise.self, forKey: .active) {
            // A v1 save: one individual, and it goes on the team at its own level
            // with its XP intact. This is the whole reason the key is still read.
            roster = [legacy]
            team = [legacy.id]
        }

        // The team is a list of references, so it is the one thing in the save
        // that can contradict itself. Sanitised here rather than guarded at every
        // use site, the same way the slot index is rebuilt on decode.
        var seen = Set<UUID>()
        let known = Set(roster.map(\.id))
        team = team
            .filter { known.contains($0) && seen.insert($0).inserted }
            .prefix(Self.teamCapacity)
            .map(\.self)
    }

    /// Writes the current shape only. `active` is never encoded: read the old
    /// key, write the new one, never both.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(log, forKey: .log)
        try c.encode(roster, forKey: .roster)
        try c.encode(team, forKey: .team)
        try c.encode(coinsSpent, forKey: .coinsSpent)
        try c.encode(dust, forKey: .dust)
        try c.encode(inventory, forKey: .inventory)
        try c.encode(hasShinyCharm, forKey: .hasShinyCharm)
    }

    // MARK: - Shop, continued

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
