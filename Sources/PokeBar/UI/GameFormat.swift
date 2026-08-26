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

    /// "Team 3 of 6", and "Team 6 of 6 · Exp Share is on" when it is.
    ///
    /// **No multiplier.** This shipped as "Team 6 of 6 · 5x XP" and the figure was
    /// caught on screen meaning nothing: 5x against *what* is not a question a
    /// header can answer, since the only baseline is a team of one and nobody runs
    /// one on purpose. What a slot actually earns is stated where it can be acted
    /// on, by `shareLine` under the selected card. The Exp Share stays because it
    /// is genuinely a state, it is off by default, and this is the only place that
    /// says which way it is set.
    static func teamSummary(occupied: Int, capacity: Int, expShare: Bool) -> String {
        let team = "Team \(occupied) of \(capacity)"
        return expShare ? "\(team) · Exp Share is on" : team
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

    /// One row of the swap menu: "Slot 3, Pineco".
    static func swapRow(slot: Int, name: String) -> String {
        "\(slotLabel(slot)), \(name)"
    }

    /// What one party slot is currently earning, for the caption under a row.
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
        return "\(subject) taking a team slot and earning nothing. Send it to your PC to free the share."
    }

    // MARK: The Dex offers

    /// "Add to team", or why it is off. Nil when there is nobody to add, which is
    /// the case where the button should not be drawn at all rather than drawn
    /// dead: a disabled control with no explanation is worse than no control.
    static func addToTeamTitle(_ options: Trainer.DexOptions) -> String? {
        guard !options.resumable.isEmpty else { return nil }
        return options.boxedTotal == 1
            ? "Add to team" : "Add to team (\(options.boxedTotal) in your PC)"
    }

    /// Why "Add to team" is disabled, or nil when it is not.
    static func addToTeamRefusal(_ options: Trainer.DexOptions) -> String? {
        guard !options.resumable.isEmpty, !options.teamHasRoom else { return nil }
        return "Your team is full at \(Trainer.teamCapacity). Send one to your PC first."
    }

    /// One stored individual, as a menu row: "Shiny, level 47".
    static func candidateRow(_ candidate: Trainer.Candidate) -> String {
        "\(variantLabel(candidate.variant)), level \(candidate.level)"
    }

    static func variantLabel(_ variant: SpriteVariant) -> String {
        switch (variant.shiny, variant.female) {
        case (false, false): "Normal"
        case (true, false): "Shiny"
        case (false, true): "Female"
        case (true, true): "Shiny female"
        }
    }

    /// How many of this entry are already training, for the line under the button.
    static func onTeamNote(_ options: Trainer.DexOptions) -> String? {
        switch options.onTeam {
        case 0: nil
        case 1: "One is on your team."
        default: "\(options.onTeam) of these are on your team."
        }
    }

    /// The two ways to pay for another one.
    static func hatchAnotherCoinsRow(_ price: Trainer.DexOptions.Price) -> String {
        "\(UsageFormat.groupedInt(price.coins)) coins"
    }

    static func hatchAnotherDustRow(_ price: Trainer.DexOptions.Price) -> String {
        "\(UsageFormat.groupedInt(price.dust)) Dust"
    }

    /// What the coins actually buy: a fresh egg, not a copy.
    ///
    /// The first version read "a second one of this exact species", which is true
    /// and reads as an expensive photocopy of the Pokemon already on the team. The
    /// draw is the opposite: `Trainer.obtain` rolls shiny and gender again for
    /// every acquisition, so the one in the egg can be a variant this collection
    /// does not have yet. Say that, and name the species so the button above it
    /// cannot be misread as "another of whatever I last hatched".
    /// Once every sprite of an entry is collected the roll can no longer surprise
    /// anyone, so the note stops promising that it might. The offer itself stays,
    /// because a graduated individual earns nothing (invariant 32) and a new level
    /// 1 is how a slot goes back to being worth something.
    static func hatchAnotherNote(name: String, missingVariants: Int) -> String {
        guard missingVariants > 0 else {
            return "You have every \(name) sprite already. A fresh egg is a new level 1 to raise, "
                + "not a new tile in the Dex."
        }
        return "A fresh \(name) egg, rolled again for shiny and gender, so it can hatch as a "
            + "variant you do not have. It starts at level 1."
    }

    /// Why an evolved form cannot be bought, naming what to buy instead. This is
    /// the line that answers "there is a button on Charmeleon and there should
    /// not be": a Charmeleon is a Charmander that grew.
    static func comesFromLine(baseFormName: String) -> String {
        "Only \(baseFormName) can be hatched. This one is reached by raising it."
    }

    // MARK: Eggs

    /// One row of the hatch menu: "Great Egg · 800 coins · rare and above".
    ///
    /// The promise is on the row rather than in a legend somewhere, because the
    /// menu is where the choice is made and a tier nobody can tell apart from the
    /// one below it is not a choice.
    static func eggMenuRow(_ tier: EggTier) -> String {
        "\(tier.displayName) · \(coins(tier.priceInCoins)) · \(tier.promise)"
    }

    /// The shop's line under an egg: "266 of 570 entries, rare and above."
    ///
    /// Pool sizes are passed in from the dex, never typed here, so a new
    /// generation moves this copy on its own. Same rule as `expShareDetail`.
    static func eggPoolLine(_ tier: EggTier, pool: Int, total: Int) -> String {
        guard tier != .egg else {
            return "All \(UsageFormat.groupedInt(pool)) entries an egg can produce."
        }
        return "\(UsageFormat.groupedInt(pool)) of \(UsageFormat.groupedInt(total)) entries, "
            + "\(tier.promise)."
    }

    /// The hatch button's title: "Hatch Egg", "Hatch Master Egg".
    ///
    /// **It names the tier, which is the failsafe.** Choosing from the menu no
    /// longer buys anything, so the button is the only thing that spends coins and
    /// it has to say what it is about to spend them on.
    static func hatchButton(_ tier: EggTier) -> String { "Hatch \(tier.displayName)" }

    /// The line under the hatch button: "20,000 coins. 22 of 570 entries, always a
    /// mythical."
    ///
    /// Price first, because that is the thing the second click is confirming.
    static func eggSelectionNote(_ tier: EggTier, pool: Int, total: Int) -> String {
        "\(coins(tier.priceInCoins)). \(eggPoolLine(tier, pool: pool, total: total))"
    }

    /// What the four eggs have in common, said once above the ladder.
    static let eggSectionNote =
        "Every egg opens the moment it is bought. A higher tier draws from a "
        + "smaller pool and costs more. Nothing else changes: the same shiny odds, "
        + "and a duplicate still pays Dust."

    // MARK: Your PC

    /// "23 waiting, best first", or the singular.
    ///
    /// **The whole PC is on screen now**, which is what moving it out of the Raise
    /// pane bought. It used to draw six rows and summarise the rest, because it
    /// was sharing a 250pt scroll area with the team, the selected card and the
    /// Everstone. A cap that hid a level 90 Charizard behind "showing the 6
    /// furthest along of 23" was the wrong trade for a list whose entire purpose
    /// is that nothing in it was ever lost.
    static func pcSummary(total: Int) -> String {
        total == 1 ? "1 waiting" : "\(total) waiting, best first"
    }

    /// The line under the count. Says the one thing the PC is for.
    static let pcExplainer =
        "Everything you have ever raised waits here, levels kept forever. "
        + "Bring one back and it carries on from where it stopped."

    /// Nothing stored yet, which is a fresh install or a player who has never
    /// filled the team. Not an error, so it reads as a description.
    static let pcEmpty =
        "Nothing in your PC. Anything you send off the team, or hatch with a full "
        + "team, waits here at the level it reached."

    /// Why the Raise button on a PC row is refused. Nil when it is not.
    static func pcRefusal(teamOccupied: Int, capacity: Int) -> String? {
        guard teamOccupied >= capacity else { return nil }
        return "The team is full at \(capacity). Send one off a slot to bring another back."
    }

    /// The pointer the Raise pane keeps now that the PC lives elsewhere. Nil when
    /// the PC is empty, because a link to an empty list is a dead end.
    static func pcLink(total: Int) -> String? {
        guard total > 0 else { return nil }
        return total == 1 ? "1 waiting in your PC" : "\(total) waiting in your PC"
    }

    /// The Rare Candy is always aimed, so the button says at whom.
    static func rareCandyTarget(_ name: String?) -> String {
        guard let name else { return "Select a Pokemon to use it on." }
        return "\(UsageFormat.groupedInt(Int(Prices.rareCandyXP))) XP for \(name)."
    }

    /// The Exp Share, in the shop. Nil `enabled` means it is not owned yet, so
    /// the line has to sell it rather than describe a switch.
    ///
    /// The figures are derived, never typed in, so turning the party dial in
    /// `XPCurve` cannot leave the shop advertising the old rate.
    static func expShareDetail(enabled: Bool?) -> String {
        let full = multiplier(XPCurve.teamMultiplier(occupiedSlots: Trainer.teamCapacity))
        let boosted = multiplier(
            XPCurve.teamMultiplier(occupiedSlots: Trainer.teamCapacity, expShare: true))
        switch enabled {
        case nil:
            return "Every other Pokemon on your team earns at the lead's rate. A full team goes from \(full) XP to \(boosted) XP, forever."
        case true:
            return "On. Every slot earns the lead's rate, so a full team is \(boosted) XP."
        case false:
            return "Off. Bench slots are back to \(multiplier(XPCurve.partyShare)) each, so a full team is \(full) XP."
        }
    }

    // MARK: Celebrations

    /// "Shiny Pineco!" The exclamation mark is earned by a 1 in 64 roll and by
    /// nothing else, so it is the one place this app raises its voice.
    static func celebrationTitle(_ celebration: Celebration, name: String) -> String {
        if celebration.variant.shiny { return "Shiny \(name)!" }
        switch celebration.source {
        case .starter: return "\(name) joins you"
        case .hatch: return "Hatched \(name)"
        case .another: return "Another \(name)"
        case .reroll: return "Re-rolled \(name)"
        case .targetedPick: return "Claimed \(name)"
        case .evolution: return name
        }
    }

    /// What actually happened, in one line: the collection, the payout, and where
    /// it went. Every clause is a fact the player would otherwise have to go
    /// looking for.
    static func celebrationSubtitle(_ celebration: Celebration) -> String {
        var parts: [String] = []
        parts.append(celebration.isNew ? "New to the dex." : "You already had this one.")
        if celebration.dust > 0 {
            parts.append("Traded the duplicate for \(dust(celebration.dust)).")
        }
        if let slot = celebration.slot {
            parts.append(slot == 0
                ? "It is your lead now."
                : "It joins your team in \(slotLabel(slot).lowercased()).")
        } else {
            parts.append("Your team is full, so it is waiting in your PC.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Projects

    /// "Raised on PokeBar 62%, hue-scenes 38%". Nil when nothing is attributed,
    /// which is a fresh individual or one fed only Rare Candy.
    ///
    /// `hidden` drops the names and keeps the count. **Recording is never
    /// toggled, only display**: a switch that stopped collecting would leave
    /// permanent holes, because the ledger credits each turn exactly once and
    /// cursors do not rewind. What the switch is actually for is a shared screen
    /// with a client's directory name on it.
    static func projectLine(_ xpByProject: [String: Double], hidden: Bool) -> String? {
        let attributed = xpByProject.filter { $0.value > 0 }
        let total = attributed.values.reduce(0, +)
        guard !attributed.isEmpty, total > 0 else { return nil }
        if hidden {
            return attributed.count == 1
                ? "Raised on 1 project" : "Raised across \(attributed.count) projects"
        }
        let ranked = attributed.sorted { $0.value > $1.value }
        let shown = ranked.prefix(projectsShown).map { key, value in
            "\(Project.displayName(key)) \(Int((value / total * 100).rounded()))%"
        }
        let rest = ranked.count - shown.count
        return "Raised on " + shown.joined(separator: ", ")
            + (rest > 0 ? " and \(rest) more" : "")
    }

    /// Two names is what fits on one line at 312pt, and the tail of a long list
    /// is noise anyway: the question is "mostly where", not "everywhere".
    static let projectsShown = 2

    /// The line under the "Open at login" switch. Nil when there is nothing
    /// useful to add, which is the ordinary off state.
    static func loginItemNote(_ state: LoginItem.State) -> String? {
        switch state {
        case .on: "PokeBar starts with your Mac, so evolutions arrive when they happen."
        case .off: nil
        case .needsApproval:
            "macOS is waiting for you to allow it. Open System Settings, then General, then Login Items."
        case .unavailable: "Only available when running the built app."
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
            case .another: return "Hatched another \(shiny)\(name(catchEvent.entryID))"
            case .starter: return "Chose \(shiny)\(name(catchEvent.entryID)) to start"
            }
        case .duplicate(let entryID, let dust):
            return dust > 0
                ? "Duplicate \(name(entryID)), traded for \(dust) Dust"
                : "Duplicate \(name(entryID))"
        // The feed names the species, which is what the player recognises, so the
        // `raiseID` these carry is for pairing an event with a team slot rather
        // than for reading out.
        case .levelledUp(_, let entryID, let level):
            return "\(name(entryID)) reached level \(level)"
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
            return "Your team is full at \(Trainer.teamCapacity). Send one to your PC first."
        case .alreadyOnTeam: return "That one is already on your team."
        case .unknownIndividual: return "That one is no longer in your roster."
        case .notABaseForm: return "Only the first form of a line can be hatched."
        }
    }

    /// Title-cases a slug for the cases where no display name was carried, which
    /// is only ever Rare Candy: every evolution item's name comes from the dex.
    static func itemName(_ slug: String) -> String {
        slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }
}
