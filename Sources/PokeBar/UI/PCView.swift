import SwiftUI

/// Your PC: every individual ever raised that is not currently on the team.
///
/// **Its own tab, not a box under the Raise pane.** It shipped inside that pane's
/// clamped scroll area, below the Everstone caption and above the Hatch button,
/// and the user read it as an appendix to the team rather than as a place. It is
/// also the only list in the app that grows without limit, since the roster is
/// append-only and every switch adds to it, so sharing 250pt with the team forced
/// a six-row cap and an overflow note. A cap on the one list whose whole point is
/// that nothing was ever lost is the wrong trade, and here there is no cap.
///
/// Holds no logic. Order comes from `GameMonitor.boxMembers`, best first, because
/// "bring back my strongest" is the question this list exists to answer.
struct PCView: View {
    let game: GameMonitor
    let store: SpriteStore
    /// Jump to an entry's Dex detail. Owned by `PokeBarPopover`, because it is a
    /// move between panes.
    let onOpenDex: (Int) -> Void
    let onError: (any Error) -> Void

    /// Measured, so an empty PC is not 300pt of nothing.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let members = game.boxMembers
        return VStack(alignment: .leading, spacing: 8) {
            header(total: members.count)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if members.isEmpty {
                        Text(GameFormat.pcEmpty)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(members, id: \.raise.id) { member in
                            row(raise: member.raise, entry: member.entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
            }
            .frame(height: PopoverMetrics.PCPane.height(forContent: contentHeight))
        }
    }

    @ViewBuilder
    private func header(total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(GameFormat.pcSummary(total: total))
                .font(.caption.weight(.medium))
            Text(GameFormat.pcExplainer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if total > 0,
               let refusal = GameFormat.pcRefusal(
                teamOccupied: game.teamMembers.count, capacity: Trainer.teamCapacity)
            {
                Text(refusal)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One stored individual. The Dex link is the same jump the Raise pane offers,
    /// on the row where "when does this one evolve" is most often asked.
    private func row(raise: Raise, entry: DexEntry) -> some View {
        HStack(spacing: 8) {
            if let dex = game.dex {
                SpriteTile(
                    entry: entry, variant: raise.variant(in: dex), dex: dex, store: store,
                    height: 24)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.caption)
                        .lineLimit(1)
                    if raise.shiny {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Shiny")
                    }
                }
                Text(GameFormat.level(raise.level))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Button("Dex") { onOpenDex(entry.id) }
                .font(.caption)
                .buttonStyle(.link)
            Button("Raise") {
                do { try game.resume(raiseID: raise.id) } catch { onError(error) }
            }
            .font(.caption)
            .buttonStyle(.link)
            .disabled(game.teamMembers.count >= Trainer.teamCapacity)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Dex") { onOpenDex(entry.id) }
            Button("Add to team") {
                do { try game.resume(raiseID: raise.id) } catch { onError(error) }
            }
            .disabled(game.teamMembers.count >= Trainer.teamCapacity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(GameFormat.level(raise.level))")
    }
}
