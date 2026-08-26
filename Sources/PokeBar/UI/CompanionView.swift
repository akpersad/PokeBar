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
    /// Jump to an entry's Dex detail. Owned by `PokeBarPopover`, because moving
    /// between panes is not something a pane can do to itself.
    let onOpenDex: (Int) -> Void
    /// Jump to the PC tab, which is where the stored roster went.
    let onOpenPC: () -> Void
    let onError: (any Error) -> Void

    /// Nil means "the lead", resolved on read rather than written on appear, so a
    /// member that gets stored or promoted cannot leave a stale selection behind.
    @State private var selectedID: UUID?

    /// Measured, so the scroll area is as tall as it needs to be and no taller.
    @State private var contentHeight: CGFloat = 0

    /// A display preference, so `UserDefaults` and not `game-state.json`:
    /// nothing that can be re-derived belongs in the one file that cannot.
    @AppStorage("PokeBarHideProjectNames") private var hideProjectNames = false

    /// Re-read after a change, because `SMAppService` can answer "registered, but
    /// waiting on the user". Nil until the switch is touched.
    @State private var loginState: LoginItem.State?

    /// Where each slot card sits, in the grid's own coordinate space. Measured
    /// rather than computed, because an occupied card sizes itself to its content.
    @State private var slotFrames: [UUID: CGRect] = [:]

    /// The drag in progress: who is moving, how far, and where the cursor is.
    @State private var drag: SlotDrag?

    struct SlotDrag: Equatable {
        let id: UUID
        var translation: CGSize
        var location: CGPoint
    }

    /// The slot a drag is currently over, so the card being dropped onto says so.
    /// Without it a drag gives no feedback at all until it lands.
    private var dropTarget: UUID? {
        guard let drag else { return nil }
        return slotFrames
            .first { $0.key != drag.id && $0.value.contains(drag.location) }?
            .key
    }

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
                teamGrid
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let selected {
                            selectedDetail(
                                slot: selected.slot, raise: selected.raise, entry: selected.entry)
                            everstoneToggle(raise: selected.raise, entry: selected.entry)
                        } else {
                            emptyState
                        }
                        evolutionActions
                    }
                    .padding(.trailing, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
                }
                .frame(height: PopoverMetrics.RaisePane.height(forContent: contentHeight))
                actions
                pcPointer
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
                    // Teal only while the Exp Share is on, because that is the
                    // half of the line worth noticing. The badge that used to sit
                    // beside this said "Exp Share" a second time, so it went with
                    // the multiplier.
                    .foregroundStyle(game.trainer.expShareActive ? AnyShapeStyle(.teal) : AnyShapeStyle(.primary))
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

    // MARK: The team

    /// All six slots, always, in slot order. **Uniform cards in a 2 x 3 grid**,
    /// because the first version showed the lead as a big card and the rest as
    /// thin rows, and the rows read as neither equal members nor as clickable.
    /// Every slot now looks like every other slot, empty ones included, which is
    /// also what makes the order legible enough to rearrange.
    ///
    /// Two columns rather than three: at 312pt a third column leaves ~100pt per
    /// card, which truncates a name like "Charizard" beside a level.
    private var teamGrid: some View {
        let members = game.teamMembers
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: PopoverMetrics.TeamGrid.spacing),
                count: PopoverMetrics.TeamGrid.columns),
            spacing: PopoverMetrics.TeamGrid.spacing
        ) {
            ForEach(0..<Trainer.teamCapacity, id: \.self) { slot in
                if slot < members.count {
                    slotCard(members[slot])
                } else {
                    emptySlot(slot)
                }
            }
        }
        .coordinateSpace(.named(Self.gridSpace))
    }

    /// `nonisolated` because the geometry closure that reads it is `Sendable`, and
    /// a constant string has no business being actor-isolated anyway.
    nonisolated static let gridSpace = "pokebar.teamGrid"

    /// Reordering by hand, **without the system drag and drop**.
    ///
    /// `.draggable` and `.onDrag` both hang a real drag session off the window,
    /// and this window is a `MenuBarExtra` panel that never becomes key. Two
    /// attempts produced a card that selected fine and could not be dragged at
    /// all, with no error to say why. A plain `DragGesture` needs none of that
    /// machinery: it is a mouse-down, a translation and a mouse-up, all inside
    /// SwiftUI, so it cannot be refused by the window.
    ///
    /// The cost is that the drop target has to be worked out here rather than by
    /// AppKit, which is what `slotFrames` is for: each card reports its rectangle
    /// in the grid's coordinate space, and the drop is whichever rectangle the
    /// cursor was inside when the mouse came up.
    private func dragGesture(for raiseID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                drag = SlotDrag(
                    id: raiseID, translation: value.translation, location: value.location)
            }
            .onEnded { value in
                let target = slotFrames
                    .first { $0.key != raiseID && $0.value.contains(value.location) }?
                    .key
                drag = nil
                guard let target else { return }
                run { try game.swapSlots(raiseID, target) }
            }
    }

    /// One slot.
    ///
    /// **Not a `Button`, deliberately.** A button's press gesture wins against
    /// `.draggable`, so the first version of this card selected fine and could not
    /// be dragged at all: the drag never started. A tap gesture and a drag gesture
    /// coexist, because the drag has a movement threshold and the tap does not.
    private func slotCard(_ member: (slot: Int, raise: Raise, entry: DexEntry)) -> some View {
        let isSelected = selected?.raise.id == member.raise.id
        let isDropTarget = dropTarget == member.raise.id
        let isDragging = drag?.id == member.raise.id
        return Group {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    if member.slot == 0 {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.yellow)
                    }
                    Text(GameFormat.slotLabel(member.slot).uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                    Spacer()
                    if member.raise.shiny {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Shiny")
                    }
                }
                HStack(spacing: 6) {
                    if let dex = game.dex {
                        SpriteTile(
                            entry: member.entry, variant: member.raise.variant(in: dex),
                            dex: dex, store: store, height: 30)
                            .frame(width: 34)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.entry.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(GameFormat.level(member.raise.level))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: GameFormat.levelProgress(totalXP: member.raise.totalXP))
                    .progressViewStyle(.linear)
                    .tint(member.raise.isGraduated ? .orange : .green)
                    .scaleEffect(y: 0.7, anchor: .center)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill(isSelected: isSelected, isDropTarget: isDropTarget)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isDropTarget ? Color.accentColor
                            : (isSelected ? Color.accentColor : .clear),
                        lineWidth: isDropTarget ? 2 : 1.5))
        }
        // Hit-testable across the whole card including its gaps, or a tap between
        // the sprite and the name would land on nothing.
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
            slotFrames[member.raise.id] = $0
        }
        // The card follows the cursor, and rides above its neighbours while it
        // does. Without the lift it slides under the next card in the grid.
        .offset(isDragging ? drag?.translation ?? .zero : .zero)
        .scaleEffect(isDragging ? 1.04 : 1)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture { selectedID = member.raise.id }
        // Drag one card onto another to exchange their slots. Swap rather than
        // insert-and-shift, so dropping onto the lead promotes exactly one
        // Pokemon and demotes exactly one.
        .gesture(dragGesture(for: member.raise.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(member.entry.name), \(GameFormat.slotLabel(member.slot)), "
                + GameFormat.level(member.raise.level))
        .accessibilityHint("Select to candy, hold or send to your PC. Drag onto another slot to swap.")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // Everything the drag can do, reachable without dragging. A menu bar
        // window is an awkward place to drag inside, and this is also the only
        // route for anyone who cannot drag at all.
        .contextMenu {
            Button("Show in Dex") { onOpenDex(member.entry.id) }
            if member.slot > 0 {
                Button("Make lead") { run { try game.promoteToLead(raiseID: member.raise.id) } }
            }
            let others = game.teamMembers.filter { $0.raise.id != member.raise.id }
            if !others.isEmpty {
                Menu("Swap with") {
                    ForEach(others, id: \.raise.id) { other in
                        Button(GameFormat.swapRow(slot: other.slot, name: other.entry.name)) {
                            run { try game.swapSlots(member.raise.id, other.raise.id) }
                        }
                    }
                }
            }
            Divider()
            Button("Send to PC") { game.sendToPC(raiseID: member.raise.id) }
        }
    }

    private func fill(isSelected: Bool, isDropTarget: Bool) -> Color {
        if isDropTarget { return Color.accentColor.opacity(0.28) }
        return isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)
    }

    private func emptySlot(_ slot: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("Empty")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PopoverMetrics.TeamGrid.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityLabel("\(GameFormat.slotLabel(slot)), empty")
    }

    // MARK: The selected member

    /// The detail for whichever card is selected: the bar the grid has no room
    /// for, and the three things that have to be aimed at one Pokemon.
    private func selectedDetail(slot: Int, raise: Raise, entry: DexEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(GameFormat.slotLabel(slot)) · \(GameFormat.shareLine(slot: slot, expShare: game.trainer.expShareActive))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

            if let line = GameFormat.projectLine(raise.xpByProject, hidden: hideProjectNames) {
                // Where this one's XP came from. The eye hides the names and
                // keeps the count, for a shared screen with a client directory
                // on it; nothing stops being *recorded*, because a hole in the
                // ledger could never be backfilled.
                HStack(spacing: 4) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button {
                        hideProjectNames.toggle()
                    } label: {
                        Image(systemName: hideProjectNames ? "eye.slash" : "eye")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(hideProjectNames ? "Show project names" : "Hide project names")
                    .accessibilityLabel(
                        hideProjectNames ? "Show project names" : "Hide project names")
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                if slot > 0 {
                    Button("Make lead") {
                        run { try game.promoteToLead(raiseID: raise.id) }
                    }
                }
                // "When does this one evolve" is the question asked most often
                // about the card, and the answer is in the Dex detail. Reaching it
                // used to mean switching tab and finding the tile by hand, which
                // is what the user called more clicks than necessary.
                Button("Dex entry") { onOpenDex(entry.id) }
                Button("Send to PC") { game.sendToPC(raiseID: raise.id) }
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

    /// A pointer to the PC, which is a tab of its own now.
    ///
    /// One line rather than the six-row list that used to sit in the scroll area
    /// above. Nil when the PC is empty, because a link to an empty list is a dead
    /// end, and that is also the state a fresh install is in.
    @ViewBuilder
    private var pcPointer: some View {
        if let label = GameFormat.pcLink(total: game.boxed.count) {
            Button(label) { onOpenPC() }
                .font(.caption2)
                .buttonStyle(.link)
        }
    }

    /// Nothing being raised, but the collection is not empty: everything was
    /// stored, or graduated and set aside. Distinct from the first-run state,
    /// which gets the starter picker instead.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing being raised")
                .font(.subheadline.weight(.medium))
            Text("Bring one back from the PC tab, hatch an egg, or pick something from the Dex tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            // **A split button, not four.** The plain Egg is what gets pressed
            // hundreds of times, so it stays one click on the primary action; the
            // three higher tiers are occasional and deliberate, so they live in the
            // menu with their price and their promise on the row. Four buttons
            // across 312pt would truncate every label, and a plain `Menu` would put
            // the common case behind two clicks. The Shop carries the same ladder
            // with the pool sizes, which is where the ladder is legible.
            Menu {
                ForEach(EggTier.allCases) { tier in
                    Button(GameFormat.eggMenuRow(tier)) {
                        run { _ = try game.hatch(tier: tier) }
                    }
                    .disabled(game.coins < tier.priceInCoins)
                }
            } label: {
                Label("Hatch egg", systemImage: "oval.portrait.fill")
            } primaryAction: {
                run { _ = try game.hatch() }
            }
            .fixedSize()
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
            Text(GameFormat.coins(Prices.egg))
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
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { pet.isVisible }, set: { _ in pet.toggle() })) {
                Text("Show on the desktop")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(game.lead == nil)

            loginToggle
        }
    }

    /// Also off by default, and for the same reason: an app that adds itself to
    /// login items unasked is a bad neighbour. Nothing is lost while PokeBar is
    /// off, since cursors back-credit, so this only decides *when* the passive
    /// notifications arrive.
    @ViewBuilder
    private var loginToggle: some View {
        let state = LoginItem.state
        Toggle(isOn: Binding(
            get: { state == .on },
            set: { wanted in
                run { try LoginItem.set(wanted) }
                // Re-read rather than trust: macOS can answer "registered, but
                // the user has to allow it", and a switch that showed on while
                // the system disagreed would be a lie.
                loginState = LoginItem.state
            })
        ) {
            Text("Open at login")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(state == .unavailable)

        if let note = GameFormat.loginItemNote(loginState ?? state) {
            Text(note)
                .font(.caption2)
                .foregroundStyle(state == .needsApproval ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { onError(error) }
    }
}
