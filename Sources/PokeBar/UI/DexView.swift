import SwiftUI

/// The collection: 1,083 tiles, with a detail pane behind each one.
///
/// Unseen entries draw a glyph rather than a greyed sprite, for two reasons that
/// happen to agree. It keeps the dex a thing you fill in rather than a catalogue
/// you already have, and it means browsing does not pull 2,368 sprite files for
/// Pokemon that have never been caught. Nothing is prefetched anywhere else
/// either.
struct DexView: View {
    let game: GameMonitor
    let store: SpriteStore
    let onError: (any Error) -> Void

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selected: DexEntry?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case caught = "Caught"
        case missing = "Missing"
        var id: String { rawValue }
    }

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Detail replaces the grid in place rather than opening a sheet. A
            // MenuBarExtra window is not a window a sheet can safely hang off:
            // it closes on focus loss, which is exactly what presenting one does.
            if let entry = selected {
                DexDetailView(entry: entry, game: game, store: store, onError: onError) {
                    selected = nil
                }
            } else {
                summary
                controls
                grid
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let seen = game.entriesSeen
        let slots = game.completion
        return VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: GameFormat.completionFraction(seen.seen, of: seen.total))
                .tint(.red)
            HStack {
                Text(GameFormat.completion(seen.seen, of: seen.total, noun: "seen"))
                Spacer()
                Text(GameFormat.completion(slots.filled, of: slots.total, noun: "sprites"))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
        }
        .controlSize(.small)
    }

    // MARK: Grid

    private var entries: [DexEntry] {
        guard let dex = game.dex else { return [] }
        let seen = game.log.seenEntryIDs
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return dex.entries.filter { entry in
            switch filter {
            case .all: break
            case .caught: if !seen.contains(entry.id) { return false }
            case .missing: if seen.contains(entry.id) { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.name.lowercased().contains(needle)
                || entry.slug.contains(needle)
                || String(entry.id) == needle
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(entries) { entry in
                    tile(entry)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 240)
    }

    private func tile(_ entry: DexEntry) -> some View {
        let seen = game.log.seenEntryIDs.contains(entry.id)
        let milestone = game.log.milestone(entryID: entry.id)
        return Button {
            selected = entry
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(seen ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
                if seen, let dex = game.dex {
                    SpriteTile(entry: entry, dex: dex, store: store, height: 34)
                } else {
                    Image(systemName: "questionmark")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(height: 44)
            .overlay {
                if let milestone { MilestoneRing(level: milestone) }
            }
            .overlay(alignment: .topTrailing) {
                if game.log.owns(entryID: entry.id, variant: .shiny) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 7))
                        .foregroundStyle(.yellow)
                        .padding(2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            GameFormat.dexTileLabel(
                name: entry.name, id: entry.id, seen: seen, milestone: milestone))
    }
}

/// The milestone mark on a Dex tile: silver at level 50, gold at 100.
///
/// A ring rather than a corner badge. The top trailing corner already belongs to
/// the shiny sparkle, and a milestone is a property of the whole tile rather than
/// a detail hung off it: at 44pt across a grid of 1,083, a border reads at a
/// glance where a 7pt glyph does not.
///
/// Only the highest mark is ever drawn, so gold replaces silver rather than
/// stacking with it. Everything at 100 passed 50 on the way, and two rings would
/// say the same thing twice.
struct MilestoneRing: View {
    let level: Int
    var cornerRadius: CGFloat = 7

    /// Gold and silver, warm-to-cool within each so the ring reads as metal
    /// rather than as a flat selection border.
    private var colors: [Color] {
        level >= XPCurve.maxLevel
            ? [
                Color(red: 1.00, green: 0.86, blue: 0.38),
                Color(red: 0.94, green: 0.56, blue: 0.15),
            ]
            : [
                Color(red: 0.93, green: 0.94, blue: 0.96),
                Color(red: 0.58, green: 0.61, blue: 0.66),
            ]
    }

    private var glow: Color {
        level >= XPCurve.maxLevel ? .yellow : Color(white: 0.85)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5)
            .shadow(color: glow.opacity(level >= XPCurve.maxLevel ? 0.5 : 0.35), radius: 3)
    }
}

/// The per-sprite counterpart of the ring, for the detail pane's variant row.
struct MilestoneBadge: View {
    let level: Int

    var body: some View {
        Image(systemName: level >= XPCurve.maxLevel ? "trophy.fill" : "circle.lefthalf.filled")
            .font(.system(size: 8))
            .foregroundStyle(level >= XPCurve.maxLevel ? Color.yellow : Color(white: 0.82))
    }
}

/// One entry, everything known about it, and what can be done with it.
struct DexDetailView: View {
    let entry: DexEntry
    let game: GameMonitor
    let store: SpriteStore
    let onError: (any Error) -> Void
    let dismiss: () -> Void

    private var seen: Bool { game.log.seenEntryIDs.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            variants
            if !entry.evolutions.isEmpty {
                Divider()
                evolutions
            }
            Divider()
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if seen, let dex = game.dex {
                SpriteTile(entry: entry, dex: dex, store: store, height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text("#\(entry.id) · \(entry.rarity.label) · Gen \(entry.generation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    game.dex.map { $0.isEvolutionGated(entry) }
                        == true ? "Evolve into it. Eggs never produce one."
                        : "Can hatch from an egg."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if let milestone = game.log.milestone(entryID: entry.id) {
                    Label(
                        GameFormat.milestoneLine(
                            level: milestone,
                            count: game.log.milestoneCount(
                                entryID: entry.id, level: milestone)),
                        systemImage: milestone >= XPCurve.maxLevel
                            ? "trophy.fill" : "circle.lefthalf.filled")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(
                            milestone >= XPCurve.maxLevel ? Color.yellow : Color(white: 0.82))
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .controlSize(.small)
        }
    }

    /// The slots this entry actually has, filled or not. One, two or four; the
    /// four-variant case is 102 entries, and showing four everywhere would invent
    /// 981 tiles nobody can fill.
    private var variants: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VARIANTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(entry.ownableVariants, id: \.self) { variant in
                    let owned = game.log.owns(entryID: entry.id, variant: variant)
                    VStack(spacing: 2) {
                        if owned, let dex = game.dex {
                            SpriteTile(
                                entry: entry, variant: variant, dex: dex, store: store, height: 36)
                                .overlay(alignment: .topTrailing) {
                                    if let reached = game.log.milestone(
                                        entryID: entry.id, variant: variant) {
                                        MilestoneBadge(level: reached)
                                    }
                                }
                        } else {
                            Image(systemName: "questionmark")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .frame(height: 36)
                        }
                        Text(label(variant))
                            .font(.system(size: 8))
                            .foregroundStyle(owned ? .secondary : .tertiary)
                    }
                    .frame(width: 54)
                }
                Spacer()
            }
        }
    }

    private func label(_ variant: SpriteVariant) -> String {
        switch (variant.shiny, variant.female) {
        case (false, false): "Normal"
        case (true, false): "Shiny"
        case (false, true): "Female"
        case (true, true): "Shiny female"
        }
    }

    private var evolutions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVOLVES INTO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(entry.evolutions, id: \.to) { edge in
                HStack(spacing: 6) {
                    Text(game.dex?.entry(id: edge.to)?.name ?? "#\(edge.to)")
                        .font(.caption)
                    Spacer()
                    Text(GameFormat.requirement(edge))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if seen {
                HStack(spacing: 8) {
                    Button("Raise this one") {
                        run { try game.setActive(entryID: entry.id) }
                    }
                    .disabled(game.active?.entryID == entry.id)

                    Button("Re-roll for \(Prices.reroll(entry.rarity)) Dust") {
                        run { try game.reroll(entryID: entry.id) }
                    }
                    .disabled(game.dust < Prices.reroll(entry.rarity))
                }
                .controlSize(.small)
                Text("Re-rolling hatches this species again for a shot at a variant you do not have. It is how shinies are hunted, and it does not disturb what you are raising.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Claim for \(Prices.targetedPick(entry.rarity)) Dust") {
                    run { try game.targetedPick(entryID: entry.id) }
                }
                .controlSize(.small)
                .disabled(game.dust < Prices.targetedPick(entry.rarity))
                Text("Dust comes from duplicate hatches. Claiming is the only way to finish the dex: random draws alone would take a median 110,218 hatches.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch {
            onError(error)
        }
    }
}
