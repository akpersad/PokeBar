import Foundation

/// Display logic for the game panes.
///
/// Every string and every fraction the game views render comes from here, for the
/// same reason the usage panes go through `UsageFormat`: a fact asserted inside a
/// view body cannot be tested in this toolchain, so nothing is decided in one.
enum GameFormat {

    // MARK: Levels

    static func level(_ level: Int) -> String { "Level \(level)" }

    /// Progress within the current level, as a fraction for a bar.
    static func levelProgress(totalXP: Double) -> Double {
        let (_, into, span) = XPCurve.progress(totalXP: totalXP)
        guard span > 0 else { return 1 }
        return min(1, max(0, into / span))
    }

    /// "4,120 / 6,100 XP", or the graduation line at the ceiling.
    static func xpLine(totalXP: Double) -> String {
        let (level, into, span) = XPCurve.progress(totalXP: totalXP)
        guard level < XPCurve.maxLevel else { return "Graduated at level 100" }
        return "\(UsageFormat.groupedInt(Int(into))) / \(UsageFormat.groupedInt(Int(span))) XP"
    }

    /// Roughly how long the next level will take at the rate recently observed.
    ///
    /// Returns nil rather than a guess when there is no rate to project from, so
    /// a fresh install does not claim a Pokemon is 40 years from level 2.
    static func timeToNextLevel(totalXP: Double, weightedTokensPerDay: Double) -> String? {
        let (level, into, span) = XPCurve.progress(totalXP: totalXP)
        guard level < XPCurve.maxLevel, weightedTokensPerDay > 0 else { return nil }
        let perDay = XPCurve.xp(forWeightedTokens: weightedTokensPerDay)
        guard perDay > 0 else { return nil }
        return duration(days: (span - into) / perDay)
    }

    /// Coarse and honest. Hours below a day, then days, then "over a month",
    /// because a projection from one day's usage does not deserve more precision
    /// than that.
    static func duration(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "any moment" }
        if days < 1 / 24.0 {
            let minutes = max(1, Int((days * 24 * 60).rounded()))
            return "\(minutes) min"
        }
        if days < 1 {
            let hours = days * 24
            return hours < 9.95 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
        }
        if days < 31 {
            return days < 9.95 ? String(format: "%.1f days", days) : "\(Int(days.rounded())) days"
        }
        return "over a month"
    }

    // MARK: The team

    /// "Team 3 of 6 · 2.6x XP". The multiplier is there because "why is a team
    /// worth having" deserves a number rather than a paragraph.
    static func teamSummary(occupied: Int, capacity: Int, expShare: Bool) -> String {
        let rate = XPCurve.teamMultiplier(occupiedSlots: occupied, expShare: expShare)
        return "Team \(occupied) of \(capacity) · \(multiplier(rate)) XP"
    }

    /// "2.6x", and "5x" rather than "5.0x": a trailing zero on a round number
    /// reads like false precision.
    static func multiplier(_ rate: Double) -> String {
        let rounded = (rate * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))x" : String(format: "%.1fx", rounded)
    }

    /// Slot 1 is the only one that means anything, so it gets a name and the rest
    /// get numbers.
    static func slotLabel(_ slot: Int) -> String {
        slot == 0 ? "Lead" : "Slot \(slot + 1)"
    }

    /// What one bench slot is currently earning, for the caption under a row.
    static func shareLine(slot: Int, expShare: Bool) -> String {
        let share = XPCurve.share(forSlot: slot, expShare: expShare)
        return share >= XPCurve.leadShare
            ? "Full XP" : "\(Int((share * 100).rounded()))% XP"
    }

    /// A graduated Pokemon in the team is wasting a share, and its share is
    /// deliberately not redistributed, so the player has to be told rather than
    /// quietly compensated. Nil when there is nothing to say.
    static func wastedSlotNote(graduated: Int) -> String? {
        guard graduated > 0 else { return nil }
        let subject = graduated == 1
            ? "1 graduated Pokemon is" : "\(graduated) graduated Pokemon are"
        return "\(subject) taking a team slot and earning nothing. Bench to free the share."
    }

    /// What the Dex button will do, said before it is pressed.
    static func raiseActionTitle(_ action: Trainer.RaiseAction) -> String {
        switch action {
        case .resume(_, let level): "Resume at level \(level)"
        case .startNew: "Raise a new one"
        case .alreadyRaising: "On your team"
        case .teamFull: "Team is full"
        case .notOwned: "Not caught yet"
        }
    }

    /// Whether that button should be pressable. The two refusals are states, not
    /// errors: the player is being told why, not stopped with a message.
    static func canRaise(_ action: Trainer.RaiseAction) -> Bool {
        switch action {
        case .resume, .startNew: true
        case .alreadyRaising, .teamFull, .notOwned: false
        }
    }

    /// How many bench rows the Raise pane draws before it summarises.
    ///
    /// The bench grows without limit, because nothing is ever deleted and every
    /// switch adds to it. Six is one screen's worth and matches the team it feeds.
    static let benchRowLimit = 6

    /// "Showing the 6 furthest along of 23." Nil when everything is on screen: a
    /// count that says "of 4" under exactly 4 rows is noise.
    static func benchOverflowNote(total: Int) -> String? {
        guard total > benchRowLimit else { return nil }
        return "Showing the \(benchRowLimit) furthest along of \(total)."
    }

    /// The Rare Candy is always aimed, so the button says at whom.
    static func rareCandyTarget(_ name: String?) -> String {
        guard let name else { return "Select a Pokemon to use it on." }
        return "\(UsageFormat.groupedInt(Int(Prices.rareCandyXP))) XP for \(name)."
    }

    /// The Exp Share, in the shop. Nil `enabled` means it is not owned yet, so
    /// the line has to sell it rather than describe a switch.
    ///
    /// The figures are derived, never typed in, so turning the bench dial in
    /// `XPCurve` cannot leave the shop advertising the old rate.
    static func expShareDetail(enabled: Bool?) -> String {
        let full = multiplier(XPCurve.teamMultiplier(occupiedSlots: Trainer.teamCapacity))
        let boosted = multiplier(
            XPCurve.teamMultiplier(occupiedSlots: Trainer.teamCapacity, expShare: true))
        switch enabled {
        case nil:
            return "Every Pokemon on the bench earns at the lead's rate. A full team goes from \(full) XP to \(boosted) XP, forever."
        case true:
            return "On. Every slot earns the lead's rate, so a full team is \(boosted) XP."
        case false:
            return "Off. Bench slots are back to \(multiplier(XPCurve.benchShare)) each, so a full team is \(full) XP."
        }
    }

    // MARK: Collection

    /// "412 of 1,083 seen (38%)". Percentages are floored, never rounded up: a
    /// dex that reads 100% with an entry missing is a bug the player can see.
    static func completion(_ filled: Int, of total: Int, noun: String) -> String {
        guard total > 0 else { return "Nothing yet" }
        let percent = Int(Double(filled) / Double(total) * 100)
        return "\(UsageFormat.groupedInt(filled)) of \(UsageFormat.groupedInt(total)) \(noun) (\(percent)%)"
    }

    static func completionFraction(_ filled: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(filled) / Double(total))
    }

    /// "1 in 58" over real hatches, or the advertised rate before there are
    /// enough hatches for an observed one to mean anything.
    static func shinyRate(shinies: Int, hatches: Int, charm: Bool) -> String {
        let advertised = charm ? Prices.shinyOddsWithCharm : Prices.shinyOdds
        guard hatches >= 50, shinies > 0 else { return "1 in \(advertised)" }
        return "1 in \(Int((Double(hatches) / Double(shinies)).rounded()))"
    }

    // MARK: Evolution

    /// What an edge asks for, in one phrase.
    ///
    /// Substituted edges say so. There is no honest way to model friendship or a
    /// tower of darkness in a token counter, and a dex that quietly invents rules
    /// is worse than one that admits which rules it had to invent.
    static func requirement(_ edge: Evolution) -> String {
        switch edge.trigger {
        case .level: "Level \(edge.minLevel)"
        case .item: edge.itemName ?? "An item"
        case .trade: "\(edge.itemName ?? "Linking Cord"), in place of a trade"
        case .substituted: "Level \(edge.minLevel), standing in for the real trigger"
        }
    }

    // MARK: Events

    /// One line for the activity feed. `dex` resolves ids to names, so a feed
    /// never shows a number the player has no way to read.
    static func describe(_ event: GameEvent, dex: Pokedex) -> String {
        func name(_ id: Int) -> String { dex.entry(id: id)?.name ?? "#\(id)" }
        switch event {
        case .caught(let catchEvent):
            let shiny = catchEvent.variant.shiny ? "Shiny " : ""
            switch catchEvent.source {
            case .hatch: return "Hatched \(shiny)\(name(catchEvent.entryID))"
            case .evolution: return "Registered \(shiny)\(name(catchEvent.entryID))"
            case .targetedPick: return "Claimed \(name(catchEvent.entryID))"
            case .reroll: return "Re-rolled into \(shiny)\(name(catchEvent.entryID))"
            case .starter: return "Chose \(shiny)\(name(catchEvent.entryID)) to start"
            }
        case .duplicate(let entryID, let dust):
            return dust > 0
                ? "Duplicate \(name(entryID)), traded for \(dust) Dust"
                : "Duplicate \(name(entryID))"
        // The feed names the species, which is what the player recognises, so the
        // `raiseID` these carry is for pairing an event with a team slot rather
        // than for reading out.
        case .levelledUp(_, let level):
            return "Reached level \(level)"
        case .evolved(_, let from, let to):
            return "\(name(from)) evolved into \(name(to))"
        case .evolutionChoice(_, let from, let options):
            let names = options.map(name).joined(separator: " or ")
            return "\(name(from)) is ready to evolve into \(names)"
        case .graduated(_, let entryID):
            return "\(name(entryID)) graduated at level 100"
        }
    }

    // MARK: Currency

    /// The Dex tile's screen-reader label. A milestone is drawn as a coloured
    /// ring, and a ring is exactly the kind of thing a screen reader cannot see,
    /// so it has to be said out loud instead.
    static func dexTileLabel(name: String, id: Int, seen: Bool, milestone: Int?) -> String {
        guard seen else { return "Number \(id), not caught" }
        guard let milestone else { return name }
        return "\(name), reached level \(milestone)"
    }

    /// The detail pane's milestone line.
    ///
    /// Graduations are counted rather than flattened to a boolean, because
    /// raising a second one the whole way is a real thing to have done. The
    /// halfway mark is not counted: it is a waypoint, and tallying waypoints
    /// reads like a scoreboard for something nobody is competing at.
    static func milestoneLine(level: Int, count: Int) -> String {
        guard level >= XPCurve.maxLevel else {
            return "Reached level \(level), halfway to graduation"
        }
        switch count {
        case ..<2: return "Reached level \(level)"
        case 2: return "Reached level \(level) twice"
        default: return "Reached level \(level), \(UsageFormat.groupedInt(count)) times"
        }
    }

    static func coins(_ amount: Int) -> String {
        "\(UsageFormat.groupedInt(amount)) \(amount == 1 ? "coin" : "coins")"
    }

    static func dust(_ amount: Int) -> String { "\(UsageFormat.groupedInt(amount)) Dust" }

    /// Why a purchase is refused, in the player's terms rather than the model's.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? Trainer.GameError else { return "That did not work." }
        switch error {
        case .notEnoughCoins(let needed, let have):
            return "Needs \(coins(needed)). You have \(coins(have))."
        case .notEnoughDust(let needed, let have):
            return "Needs \(dust(needed)). You have \(dust(have))."
        case .nothingActive: return "Nothing is being raised yet."
        case .notStartingOut: return "You have already chosen a first partner."
        case .unknownEntry: return "That Pokemon is not in the dex."
        case .alreadyOwned: return "Already in the collection."
        case .notOwned: return "Not in the collection yet."
        case .missingItem(let slug): return "You do not have a \(itemName(slug))."
        case .evolutionNotAvailable: return "That evolution is not available yet."
        case .emptyPool: return "There is nothing left to hatch."
        case .teamFull:
            return "Your team is full at \(Trainer.teamCapacity). Bench one first."
        case .alreadyOnTeam: return "That one is already on your team."
        case .unknownIndividual: return "That one is no longer in your roster."
        }
    }

    /// Title-cases a slug for the cases where no display name was carried, which
    /// is only ever Rare Candy: every evolution item's name comes from the dex.
    static func itemName(_ slug: String) -> String {
        slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }
}
