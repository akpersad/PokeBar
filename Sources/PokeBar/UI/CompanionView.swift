import SwiftUI

/// The Pokemon currently being raised, and the two buttons that change it.
///
/// Holds no logic: every string comes from `GameFormat` and every rule from
/// `Trainer`. What it decides is layout.
struct CompanionView: View {
    let game: GameMonitor
    let store: SpriteStore
    let pet: FloatingPet
    let weightedTokensPerDay: Double
    let onError: (any Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = game.activeEntry, let raise = game.active {
                card(entry: entry, raise: raise)
                evolutionActions
            } else {
                emptyState
            }
            actions
            if !game.recentEvents.isEmpty { feed }
            petToggle
        }
    }


    // MARK: Active

    private func card(entry: DexEntry, raise: Raise) -> some View {
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.name), \(GameFormat.level(raise.level)), "
                + GameFormat.xpLine(totalXP: raise.totalXP))
    }

    /// Buttons for evolutions that are ready. Item edges appear here because a
    /// stone is a thing you choose to use, and branching level edges appear here
    /// because the choice is the player's: Eevee has three at level 36.
    @ViewBuilder
    private var evolutionActions: some View {
        let ready = game.pendingEvolutions
        if !ready.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to evolve")
                    .font(.caption.weight(.medium))
                ForEach(ready, id: \.target.id) { pair in
                    Button {
                        run { try game.evolveActive(into: pair.target.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text(pair.target.name)
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Pokemon yet")
                .font(.subheadline.weight(.medium))
            Text("Hatch an egg to start raising one. It gains XP from the same tokens that earn coins, so training and saving happen at once.")
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
                    run { try game.useRareCandy() }
                } label: {
                    Label(
                        "Rare Candy (\(game.trainer.count(ofItem: Trainer.rareCandySlug)))",
                        systemImage: "capsule.fill")
                }
                .disabled(game.active == nil)
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
    /// a user asks for, not one that appears.
    private var petToggle: some View {
        Toggle(isOn: Binding(get: { pet.isVisible }, set: { _ in pet.toggle() })) {
            Text("Show on the desktop")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(game.active == nil)
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { onError(error) }
    }
}
