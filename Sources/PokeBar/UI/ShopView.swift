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
///
/// **The eggs are here even though they are not items.** An egg opens the instant
/// it is paid for, so there is never one to hold, and the Raise pane's split
/// button is where the plain one actually gets pressed. What the shop adds is the
/// ladder side by side: four prices against four pool sizes is the only view that
/// makes the choice between them legible, and a price list is what a shop is.
struct ShopView: View {
    let game: GameMonitor
    let onError: (any Error) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("EGGS") {
                    Text(GameFormat.eggSectionNote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(EggTier.allCases) { tier in
                        eggRow(tier)
                    }
                }
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
                    expShare
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

    /// One rung of the egg ladder. Hatches on press rather than buying an item,
    /// which is the one thing that makes this row different from every other.
    private func eggRow(_ tier: EggTier) -> some View {
        let total = game.hatchPoolSize(for: .egg)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(tier.displayName)
                    .font(.callout)
                Spacer(minLength: 8)
                Button(UsageFormat.groupedInt(tier.priceInCoins)) {
                    do { _ = try game.hatch(tier: tier) } catch { onError(error) }
                }
                .controlSize(.small)
                .disabled(game.coins < tier.priceInCoins)
            }
            Text(
                GameFormat.eggPoolLine(
                    tier, pool: game.hatchPoolSize(for: tier), total: total))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(tier.displayName), \(GameFormat.coins(tier.priceInCoins)), \(tier.promise)")
    }

    /// Every party slot on the lead's rate.
    ///
    /// **A boost, never a split.** The whole credit still goes to slot 1 and the
    /// whole credit goes to each party slot too, so this takes a full team from
    /// 5x to 6x. An item that divided one credit six ways would have made a paid
    /// purchase slower than the free default.
    ///
    /// The toggle lives here rather than in the Raise pane because this is where
    /// the item is. What it *does* is visible there, in the team's multiplier.
    @ViewBuilder
    private var expShare: some View {
        if game.trainer.hasExpShare {
            VStack(alignment: .leading, spacing: 1) {
                Toggle(isOn: Binding(
                    get: { game.trainer.expShareEnabled },
                    set: { game.setExpShare($0) })
                ) {
                    HStack(spacing: 5) {
                        Label("Exp Share", systemImage: "square.stack.3d.up.fill")
                            .font(.callout)
                        Text("Owned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text(GameFormat.expShareDetail(enabled: game.trainer.expShareEnabled))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            row(
                .expShare, name: "Exp Share",
                detail: GameFormat.expShareDetail(enabled: nil),
                held: 0)
        }
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
