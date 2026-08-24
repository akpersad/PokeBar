import AppKit
import SwiftUI

/// The menu bar window: chrome, currency, and one of four panes.
///
/// Tabs rather than a scrolling wall, because the four things the app does are
/// genuinely separate activities and the popover is 340pt wide. The currency row
/// sits above the tabs because it is the one figure every pane is spending.
struct PokeBarPopover: View {
    let monitor: UsageMonitor
    let game: GameMonitor
    let store: SpriteStore
    let pet: FloatingPet

    @State private var pane: Pane = .companion
    @State private var message: String?

    enum Pane: String, CaseIterable, Identifiable {
        case companion = "Raise"
        case dex = "Dex"
        case shop = "Shop"
        case usage = "Usage"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            currency

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                    weightedTokensPerDay: monitor.todayWeightedTokens, onError: report)
            case .dex:
                DexView(game: game, store: store, onError: report)
            case .shop:
                ShopView(game: game, onError: report)
            case .usage:
                UsagePopover(monitor: monitor)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: pane) { message = nil }
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
