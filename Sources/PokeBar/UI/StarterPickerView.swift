import SwiftUI

/// The first thirty seconds: choose a partner from the 27 starters.
///
/// This is the one place in the app that shows sprites for Pokemon nobody owns,
/// and the exception is the whole point. Everywhere else an unseen entry draws a
/// glyph, because the dex is a thing you fill in. Here the choice *is* the
/// content, so 27 sprites are worth fetching.
///
/// It replaces the empty state rather than sitting beside a Hatch button. Opening
/// with a weighted draw over 570 entries means the first Pokemon is overwhelmingly
/// likely to be one nobody asked for, which is a poor first impression of a game
/// whose whole hook is attachment to one creature.
struct StarterPickerView: View {
    let game: GameMonitor
    let store: SpriteStore
    let onError: (any Error) -> Void

    @State private var selected: Int?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose your first partner")
                    .font(.subheadline.weight(.medium))
                Text("Free, and only once. It gains XP from the same tokens that earn coins, so training and saving happen at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 4) {
                    ForEach(game.dex?.starters ?? []) { entry in
                        tile(entry)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 168)

            footer
        }
    }

    private func tile(_ entry: DexEntry) -> some View {
        Button {
            selected = selected == entry.id ? nil : entry.id
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected == entry.id
                          ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
                if let dex = game.dex {
                    SpriteTile(entry: entry, dex: dex, store: store, height: 34)
                }
            }
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        selected == entry.id ? Color.accentColor : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(selected == entry.id ? [.isSelected] : [])
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if let selected, let entry = game.dex?.entry(id: selected) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                    Text("Generation \(entry.generation) · \(chainText(entry))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose \(entry.name)") {
                    do {
                        try game.chooseStarter(entryID: entry.id)
                    } catch {
                        onError(error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Pick one to see what it becomes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    /// What it grows into, which is the thing actually being chosen: the starter
    /// is 14 hours of climbing away from its second stage.
    ///
    /// Branches are named rather than hidden. Three starter lines fork at their
    /// second stage into a Hisuian form (Cyndaquil, Oshawott and Rowlet), and
    /// showing only the first edge would quietly misrepresent three of the
    /// twenty-seven choices on offer.
    private func chainText(_ entry: DexEntry) -> String {
        guard let dex = game.dex else { return "" }
        var stages: [String] = []
        var current = entry
        while !current.evolutions.isEmpty, stages.count < 2 {
            let targets = current.evolutions.compactMap { dex.entry(id: $0.to) }
            guard let next = targets.first else { break }
            stages.append(targets.map(\.name).joined(separator: " or "))
            current = next
        }
        return stages.isEmpty ? "Does not evolve" : "Becomes " + stages.joined(separator: ", then ")
    }
}
