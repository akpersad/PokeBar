import SwiftUI

/// The team being raised, and everything that changes it.
///
/// Holds no logic: every string comes from `GameFormat` and every rule from
/// `Trainer`. What it decides is layout.
///
/// **The card is the selected member, and the rows are the rest.** One detail
/// view plus a list, rather than six cards, because the pane lays out in 312pt
/// and six of anything with a progress bar does not fit. The selected member's
/// row is skipped precisely because the card above *is* that row expanded, which
/// also means a team of one renders exactly what it rendered before the team
/// existed: one card, no list.
///
/// Selection is the answer to three questions at once, which is why it exists at
/// all: which Pokemon gets the Rare Candy, which one the Everstone is for, and
/// which one is being promoted. Aiming each of those separately would be three
/// controls per row.
struct CompanionView: View {
    let game: GameMonitor
    let store: SpriteStore
    let pet: FloatingPet
    let weightedTokensPerDay: Double
    let onError: (any Error) -> Void

    /// Nil means "the lead", resolved on read rather than written on appear, so a
    /// member that gets benched or promoted cannot leave a stale selection behind.
    @State private var selectedID: UUID?

    /// Measured, so the scroll area is as tall as it needs to be and no taller.
    @State private var contentHeight: CGFloat = 0

    private var selected: (slot: Int, raise: Raise, entry: DexEntry)? {
        let members = game.teamMembers
        if let selectedID, let match = members.first(where: { $0.raise.id == selectedID }) {
            return match
        }
        return members.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if game.needsStarter {
                // The first pick replaces the whole pane, including the Hatch
                // button. Offering a 300-coin random draw beside a free chosen
                // partner is a choice nobody should have to think about.
                StarterPickerView(game: game, store: store, onError: onError)
            } else {
                teamHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let selected {
                            card(slot: selected.slot, raise: selected.raise, entry: selected.entry)
                            everstoneToggle(raise: selected.raise, entry: selected.entry)
                        } else {
                            emptyState
                        }
                        evolutionActions
                        otherSlots
                        bench
                    }
                    .padding(.trailing, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
                }
                .frame(height: PopoverMetrics.RaisePane.height(forContent: contentHeight))
                actions
                if !game.recentEvents.isEmpty { feed }
                petToggle
            }
        }
    }

    // MARK: Header

    private var teamHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(GameFormat.teamSummary(
                    occupied: game.teamMembers.count, capacity: Trainer.teamCapacity,
                    expShare: game.trainer.expShareActive))
                    .font(.caption.weight(.medium))
                if game.trainer.expShareActive {
                    Label("Exp Share", systemImage: "square.stack.3d.up.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.teal)
                }
                Spacer()
            }
            if let note = GameFormat.wastedSlotNote(graduated: game.graduatedInTeam) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The selected member

    private func card(slot: Int, raise: Raise, entry: DexEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let dex = game.dex {
                    SpriteTile(
                        entry: entry, variant: raise.variant(in: dex), dex: dex, store: store,
                        height: 52)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .font(.headline)
                        if raise.shiny {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Shiny")
                        }
                    }
                    Text("\(GameFormat.level(raise.level)) · \(entry.rarity.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(GameFormat.slotLabel(slot)) · \(GameFormat.shareLine(slot: slot, expShare: game.trainer.expShareActive))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            ProgressView(value: GameFormat.levelProgress(totalXP: raise.totalXP))
                .progressViewStyle(.linear)
                .tint(.green)

            HStack {
                Text(GameFormat.xpLine(totalXP: raise.totalXP))
                Spacer()
                if let eta = GameFormat.timeToNextLevel(
                    totalXP: raise.totalXP, weightedTokensPerDay: weightedTokensPerDay) {
                    Text("next in ~\(eta)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            HStack(spacing: 10) {
                if slot > 0 {
                    Button("Make lead") {
                        run { try game.promoteToLead(raiseID: raise.id) }
                    }
                }
                Button("Bench") { game.bench(raiseID: raise.id) }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.name), \(GameFormat.slotLabel(slot)), \(GameFormat.level(raise.level)), "
                + GameFormat.xpLine(totalXP: raise.totalXP))
    }

    /// The Everstone: the games' item for keeping a Pokemon as it is.
    ///
    /// Shown only for a line that evolves on its own, because on a Pikachu or an
    /// Eevee it would promise to prevent something that never happens unasked.
    @ViewBuilder
    private func everstoneToggle(raise: Raise, entry: DexEntry) -> some View {
        if entry.evolutions.contains(where: { $0.item == nil }) {
            VStack(alignment: .leading, spacing: 1) {
                Toggle(isOn: Binding(
                    get: { raise.everstone },
                    set: { game.setEverstone($0, on: raise.id) })
                ) {
                    Text("Everstone")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Text(raise.everstone
                     ? "Holding \(entry.name) as it is. Take it off and any evolution it has passed happens at once."
                     : "Hold to stop \(entry.name) evolving. Nothing is lost by waiting.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Buttons for evolutions that are ready, **across the whole team**.
    ///
    /// A list rather than the selected member's, because one credit can leave
    /// several members waiting at once and a decision hidden behind a selection is
    /// one nobody knows they are holding up. Item edges appear here because a
    /// stone is a thing you choose to use, and branching level edges because the
    /// choice is the player's: Eevee has three at level 36.
    @ViewBuilder
    private var evolutionActions: some View {
        let pending = game.teamPendingEvolutions
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to evolve")
                    .font(.caption.weight(.medium))
                ForEach(pending, id: \.raise.id) { member in
                    ForEach(member.options, id: \.target.id) { pair in
                        Button {
                            run { try game.evolve(member.raise.id, into: pair.target.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle.fill")
                                Text("\(member.entry.name) to \(pair.target.name)")
                                Text(GameFormat.requirement(pair.edge))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    // MARK: The rest of the team

    /// Every slot except the one the card is showing. Tap to bring it into the
    /// card, which is also how it becomes the target for the Rare Candy and the
    /// Everstone.
    @ViewBuilder
    private var otherSlots: some View {
        let others = game.teamMembers.filter { $0.raise.id != selected?.raise.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(others, id: \.raise.id) { member in
                    memberRow(slot: member.slot, raise: member.raise, entry: member.entry)
                }
            }
        }
    }

    private func memberRow(slot: Int, raise: Raise, entry: DexEntry) -> some View {
        Button {
            selectedID = raise.id
        } label: {
            HStack(spacing: 8) {
                if let dex = game.dex {
                    SpriteTile(
                        entry: entry, variant: raise.variant(in: dex), dex: dex, store: store,
                        height: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(entry.name)
                            .font(.caption.weight(.medium))
                        if raise.shiny {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Shiny")
                        }
                    }
                    Text("\(GameFormat.slotLabel(slot)) · \(GameFormat.level(raise.level)) · \(GameFormat.shareLine(slot: slot, expShare: game.trainer.expShareActive))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ProgressView(value: GameFormat.levelProgress(totalXP: raise.totalXP))
                    .progressViewStyle(.linear)
                    .tint(raise.isGraduated ? .orange : .green)
                    .frame(width: 44)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(entry.name), \(GameFormat.slotLabel(slot)), \(GameFormat.level(raise.level))")
        .accessibilityHint("Select to raise, candy or hold")
    }

    /// Everyone not currently training, best first. **The screen the roster
    /// exists for**: nothing is ever deleted, so bringing a level 47 Charizard
    /// back is one click and it resumes exactly where it stopped.
    @ViewBuilder
    private var bench: some View {
        let members = game.benchMembers
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("BENCH")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                Text("Levels are kept forever. Bring one back and it carries on from where it stopped.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(members.prefix(GameFormat.benchRowLimit), id: \.raise.id) { member in
                    benchRow(raise: member.raise, entry: member.entry)
                }
                if let note = GameFormat.benchOverflowNote(total: members.count) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func benchRow(raise: Raise, entry: DexEntry) -> some View {
        HStack(spacing: 8) {
            if let dex = game.dex {
                SpriteTile(
                    entry: entry, variant: raise.variant(in: dex), dex: dex, store: store,
                    height: 22)
            }
            Text(entry.name)
                .font(.caption)
            if raise.shiny {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Shiny")
            }
            Text(GameFormat.level(raise.level))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Raise") {
                run { try game.resume(raiseID: raise.id) }
            }
            .font(.caption)
            .buttonStyle(.link)
            .disabled(game.teamMembers.count >= Trainer.teamCapacity)
        }
    }

    /// Nothing being raised, but the collection is not empty: everything was
    /// benched, or graduated and set aside. Distinct from the first-run state,
    /// which gets the starter picker instead.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing being raised")
                .font(.subheadline.weight(.medium))
            Text("Bring one back from the bench, hatch an egg, or pick something from the Dex tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                run { _ = try game.hatch() }
            } label: {
                Label("Hatch egg", systemImage: "oval.portrait.fill")
            }
            .disabled(game.coins < Prices.egg)

            if game.trainer.count(ofItem: Trainer.rareCandySlug) > 0 {
                Button {
                    // Aimed at the card, never at "whoever is in front": with six
                    // members an unaimed candy is a choice made for the player.
                    if let target = selected?.raise.id {
                        run { try game.useRareCandy(on: target) }
                    }
                } label: {
                    Label(
                        "Rare Candy (\(game.trainer.count(ofItem: Trainer.rareCandySlug)))",
                        systemImage: "capsule.fill")
                }
                .disabled(selected == nil)
                .help(GameFormat.rareCandyTarget(selected?.entry.name))
            }
            Spacer()
            Text("\(Prices.egg) coins")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .controlSize(.small)
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(game.recentEvents.prefix(4).enumerated()), id: \.offset) { _, event in
                if let dex = game.dex {
                    Text(GameFormat.describe(event, dex: dex))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The desktop companion. Off by default: an always-on-top window is a thing
    /// a user asks for, not one that appears. Follows the lead, like the menu bar.
    private var petToggle: some View {
        Toggle(isOn: Binding(get: { pet.isVisible }, set: { _ in pet.toggle() })) {
            Text("Show on the desktop")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(game.lead == nil)
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { onError(error) }
    }
}
