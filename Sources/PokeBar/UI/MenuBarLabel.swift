import SwiftUI

/// The always-visible status item.
///
/// Shows coins rather than tokens: coins are the game currency and the reason the
/// app exists, and the restored ledger publishes them before the cold scan starts,
/// so a relaunch shows a real number immediately instead of a zero that climbs.
/// Compact formatting keeps the item's width stable as the figure grows.
struct MenuBarLabel: View {
    let monitor: UsageMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(UsageFormat.compactTokens(monitor.coins))
        }
        .accessibilityLabel(accessibilityText)
    }

    /// A species sprite replaces this once the Pokedex data layer lands. Until
    /// then `smallcircle.filled.circle` is the closest thing SF Symbols has to a
    /// Poke Ball, and the dotted circle is the original placeholder icon, reused
    /// to mean "still reading".
    private var symbol: String {
        switch monitor.state {
        case .failed: "exclamationmark.triangle.fill"
        case .scanning: "circle.dotted"
        case .idle, .watching: "smallcircle.filled.circle"
        }
    }

    private var accessibilityText: String {
        let coins = "PokeBar, \(UsageFormat.groupedInt(monitor.coins)) coins"
        switch monitor.state {
        case .scanning: return coins + ", reading usage history"
        case .failed: return coins + ", usage reading failed"
        case .idle, .watching: return coins
        }
    }
}
