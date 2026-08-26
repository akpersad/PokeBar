import AppKit
import SwiftUI

/// The menu bar window: chrome, currency, and one of five panes.
///
/// Tabs rather than a scrolling wall, because the things the app does are
/// genuinely separate activities and the popover is 340pt wide. The currency row
/// sits above the tabs because it is the one figure every pane is spending.
///
/// **The PC is a tab, not a box at the bottom of the Raise pane.** It shipped
/// inside that pane's scroll area and read as an appendix to the team: the user
/// saw it under the Everstone caption, above the Hatch button, and said it did
/// not belong there. It is also the one list that grows without limit, so it was
/// the thing forcing a 6-row cap and an overflow note on a pane that had no room
/// to show either. A tab gives it the whole 312pt and lets the Raise pane be
/// about the six slots that are actually earning.
///
/// **Pane selection and the Dex's focused entry both live here**, because
/// "show me this one's Dex entry" is a jump *between* panes and neither pane can
/// own it. The Raise and PC panes hand up an entry id, this sets the id and the
/// tab together, and the Dex opens on that entry's detail. Working out when a
/// Pokemon evolves used to mean leaving the Raise pane, switching tab, and
/// finding the tile by hand.
struct PokeBarPopover: View {
    let monitor: UsageMonitor
    let game: GameMonitor
    let store: SpriteStore
    let pet: FloatingPet

    @State private var pane: Pane = .companion
    @State private var message: String?

    /// The Dex entry the Dex pane is showing the detail for, or nil for the grid.
    @State private var dexFocus: Int?

    enum Pane: String, CaseIterable, Identifiable {
        case companion = "Raise"
        case pc = "PC"
        case dex = "Dex"
        case shop = "Shop"
        case usage = "Usage"
        var id: String { rawValue }
    }

    /// Opens an entry's Dex detail from whichever pane asked.
    private func openDex(entryID: Int) {
        dexFocus = entryID
        pane = .dex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            currency

            // `SegmentedTabs`, not `Picker`, and the reason is in that file:
            // SwiftUI's segmented picker fits each segment to its own label and
            // then centres the lot, so the four tabs sat in the middle of the
            // popover with dead space either side however it was framed.
            SegmentedTabs(
                tabs: Pane.allCases.map { (label: $0.rawValue, value: $0) },
                selection: $pane)
            .frame(maxWidth: .infinity)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch pane {
            case .companion:
                CompanionView(
                    game: game, store: store, pet: pet,
                    weightedTokensPerDay: monitor.todayWeightedTokens,
                    onOpenDex: openDex(entryID:), onOpenPC: { pane = .pc },
                    onError: report)
            case .pc:
                PCView(
                    game: game, store: store, onOpenDex: openDex(entryID:), onError: report)
            case .dex:
                DexView(game: game, store: store, focus: $dexFocus, onError: report)
            case .shop:
                ShopView(game: game, onError: report)
            case .usage:
                UsagePopover(monitor: monitor)
            }

            Divider()
            footer
        }
        .padding(PopoverMetrics.padding)
        .frame(width: PopoverMetrics.width)
        .onChange(of: pane) { message = nil }
        // Over the whole popover, not inside a pane: a hatch can be started from
        // the Raise tab or from the Dex, and the thing you just paid for deserves
        // the same moment either way.
        .overlay {
            if let celebration = game.celebration { CelebrationCard(
                game: game, store: store, celebration: celebration)
            }
        }
        .animation(.snappy, value: game.celebration)
    }

    /// Shows why something was refused, in the player's terms. Cleared on the
    /// next tab change rather than on a timer, so a message cannot vanish while
    /// it is being read.
    private func report(_ error: any Error) {
        message = GameFormat.describe(error)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.red)
                Text("PokeBar")
                    .font(.headline)
                Spacer()
                StatusBadge(state: monitor.state)
            }
            if case .failed(let text) = monitor.state {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Both currencies, side by side, because the split is the mechanic: coins
    /// accrue while the machine is busy, Dust only ever comes from duplicates.
    private var currency: some View {
        HStack(spacing: 8) {
            purse(
                value: game.coins, label: game.coins == 1 ? "coin" : "coins",
                caption: "1 per \(UsageFormat.groupedInt(Int(UsageLedger.tokensPerCoin))) weighted tokens",
                tint: .yellow)
            purse(
                value: game.dust, label: "Dust",
                caption: "From duplicate hatches", tint: .purple)
        }
        .animation(.snappy, value: game.coins)
        .animation(.snappy, value: game.dust)
    }

    private func purse(value: Int, label: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(UsageFormat.groupedInt(value))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(UsageFormat.groupedInt(value)) \(label)")
    }

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") {
                monitor.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
    }

    private var updatedText: String {
        guard let last = monitor.lastUpdated else { return "Waiting for the first scan" }
        return "Updated \(UsageFormat.relativeAge(of: last))"
    }
}
