import SwiftUI

/// The always-visible status item.
///
/// Shows coins rather than tokens: coins are the game currency and the reason the
/// app exists, and the restored ledger publishes them before the cold scan starts,
/// so a relaunch shows a real number immediately instead of a zero that climbs.
/// Compact formatting keeps the item's width stable as the figure grows.
struct MenuBarLabel: View {
    let monitor: UsageMonitor
    let game: GameMonitor
    let sprite: SpriteAnimator
    /// Updated from here rather than from the popover, because the pet has to
    /// follow the active Pokemon whether or not the window has ever been opened.
    let pet: FloatingPet

    var body: some View {
        HStack(spacing: 3) {
            // The sprite is the icon whenever one has resolved. A symbol still
            // covers the states where showing a Pokemon would be misleading, and
            // the cold-cache case where no sprite has arrived yet.
            if let frame = sprite.frame, symbol == nil {
                // No frame modifier on purpose. The decoder already produced this
                // image at exactly its display size, height-constrained with width
                // free, so the intrinsic size is the right size. Forcing a square
                // frame here is what made wide species render short: Glaceon's
                // 76x54 canvas in an 18pt square box only fills 12.79pt of a 22pt
                // menu bar.
                Image(decorative: frame, scale: 2)
            } else if let symbol {
                Image(systemName: symbol)
            } else {
                // Offline on a cold cache: hold the space so the coin count does
                // not shift sideways when the sprite lands.
                Image(systemName: "smallcircle.filled.circle")
            }
            Text(UsageFormat.compactTokens(game.coins))
        }
        .accessibilityLabel(accessibilityText)
        // Follows the Pokemon being raised, which is the seam Phase 3 left here
        // on purpose: `featured(on:)` survives only as the fallback for a
        // collection with nothing in it yet.
        .task(id: shown.map { "\($0.entry.id)-\($0.variant)" } ?? "none") {
            guard let shown else { return }
            await sprite.show(shown.entry, variant: shown.variant)
            await pet.show(shown.entry, variant: shown.variant)
            // Settle notification permission here rather than at the first
            // evolution, which would race its own prompt and be dropped.
            await game.prepareNotifications()
        }
    }

    /// A symbol instead of a sprite, or nil to show the sprite.
    ///
    /// Scanning and failure keep their glyphs: a Pokemon sitting in the menu bar
    /// while the engine is broken reads as everything being fine.
    private var symbol: String? {
        switch monitor.state {
        case .failed: "exclamationmark.triangle.fill"
        case .scanning: "circle.dotted"
        case .idle, .watching: nil
        }
    }

    private var shown: (entry: DexEntry, variant: SpriteVariant)? { game.statusItem() }

    private var accessibilityText: String {
        var coins = "PokeBar, \(UsageFormat.groupedInt(game.coins)) coins"
        switch monitor.state {
        case .scanning: return coins + ", reading usage history"
        case .failed: return coins + ", usage reading failed"
        case .idle, .watching:
            if let raise = game.lead, let entry = game.leadEntry {
                coins += ", raising \(entry.name) at level \(raise.level)"
            } else if let name = sprite.entry?.name {
                coins += ", showing \(name)"
            }
            return coins
        }
    }
}
