import SwiftUI

/// What coins buy.
///
/// Coins only. Dust is spent in the dex, on the entry it is being spent on, which
/// keeps the two currencies from reading as interchangeable: coins buy volume,
/// Dust buys choice, and neither substitutes for the other.
///
/// No Mint. A Mint rerolls a nature, and natures play no part here because there
/// is no stat raising to aim at, so it would be a coin sink that buys nothing
/// observable. Rejected rather than deferred (DECISIONS.md).
struct ShopView: View {
    let game: GameMonitor
    let onError: (any Error) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("TRAINING") {
                    row(
                        .rareCandy, name: "Rare Candy",
                        detail: "\(UsageFormat.groupedInt(Int(Prices.rareCandyXP))) XP, used from the Raise tab",
                        held: game.trainer.count(ofItem: Trainer.rareCandySlug))
                }
                section("PERMANENT") {
                    if game.trainer.hasShinyCharm {
                        HStack {
                            Label("Shiny Charm", systemImage: "sparkles")
                                .font(.callout)
                            Spacer()
                            Text("Owned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Shiny odds are 1 in \(Prices.shinyOddsWithCharm) instead of 1 in \(Prices.shinyOdds).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        row(
                            .shinyCharm, name: "Shiny Charm",
                            detail: "Shiny odds go from 1 in \(Prices.shinyOdds) to 1 in \(Prices.shinyOddsWithCharm), forever",
                            held: 0)
                    }
                }
                section("EVOLUTION ITEMS") {
                    Text("Held items unlock the 95 evolutions that no amount of levelling will.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(game.dex?.evolutionItems ?? [], id: \.slug) { item in
                        row(
                            .item(slug: item.slug, name: item.name), name: item.name,
                            detail: nil, held: game.trainer.count(ofItem: item.slug))
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: 280)
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }

    private func row(
        _ item: Trainer.ShopItem, name: String, detail: String?, held: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.callout)
                if held > 0 {
                    Text("x\(held)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("\(UsageFormat.groupedInt(item.priceInCoins))") {
                    do { try game.buy(item) } catch { onError(error) }
                }
                .controlSize(.small)
                .disabled(!game.canAfford(item))
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(GameFormat.coins(item.priceInCoins))")
    }
}
