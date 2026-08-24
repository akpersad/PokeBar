import SwiftUI

/// The usage pane. Reads `UsageMonitor` and renders it; holds no state of its
/// own, so there is no second copy of the totals to fall out of sync.
///
/// The window chrome around it (header, currency, tabs, footer) belongs to
/// `PokeBarPopover`, because those are shared with the game panes.
struct UsagePopover: View {
    let monitor: UsageMonitor

    private var hasUsage: Bool { monitor.allTimeTokens.total > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasUsage {
                todaySection
                Divider()
                allTimeSection
            } else {
                placeholderSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Re-derive on open. "Today" is bucketed when the engine last published,
        // so a quiet run across midnight would otherwise keep yesterday's figures
        // under today's heading. Costs nothing: no disk, no scan.
        .task { monitor.refreshDisplayedTotals() }
    }

    // MARK: Sections

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Today")
            StatRow(label: "Tokens", value: UsageFormat.compactTokens(monitor.todayTokens.total))

            let rows = ModelBreakdown.rows(from: monitor.byModelToday)
            if rows.isEmpty {
                Text("Nothing yet today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { ModelRow(row: $0) }
                }
                .padding(.vertical, 2)
                TokenClassGrid(tokens: monitor.todayTokens)
            }

            StatRow(label: "API equivalent", value: UsageFormat.usd(monitor.todayCostUSD))
            Text(costCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allTimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("All time")
            StatRow(label: "Tokens", value: UsageFormat.compactTokens(monitor.allTimeTokens.total))
            StatRow(label: "API equivalent", value: UsageFormat.usd(monitor.allTimeCostUSD))
        }
    }

    /// Cost is a hypothetical, and saying so every time is the point: on a
    /// subscription this is value realised, not money spent. The incomplete
    /// variant exists because an unpriced model must never read as free.
    private var costCaption: String {
        monitor.costIsIncomplete
            ? "A model in use has no published price, so this is a floor. On a subscription it is value realised, not money spent."
            : "What this usage would have cost on the API. On a subscription it is value realised, not money spent."
    }

    private var placeholderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if monitor.state == .scanning {
                Text("Reading your Claude Code, Codex and Copilot history")
                    .font(.subheadline.weight(.medium))
                Text("The first pass covers everything on disk and takes a few seconds.")
            } else {
                Text("No usage yet")
                    .font(.subheadline.weight(.medium))
                Text("Start a Claude Code, Codex or Copilot CLI session and it shows up here about a second after the turn finishes.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// MARK: - Pieces

struct SectionHeader: View {
    private let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }
}

/// The four classes, shown because they differ in price by up to 60x and because
/// the shape of the split is the interesting part: cache reads dominate volume.
private struct TokenClassGrid: View {
    let tokens: TokenCounts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            // Two equal columns, so the grid spans the pane instead of
            // bunching against the left with dead space to the right.
            GridRow {
                cell("Input", tokens.input)
                cell("Output", tokens.output)
            }
            GridRow {
                cell("Cache write", tokens.cacheWrite)
                cell("Cache read", tokens.cacheRead)
            }
        }
    }

    /// `maxWidth: .infinity` so the two columns split the popover's width
    /// evenly rather than hugging the left edge with a gap beside them, and
    /// so "Cache read" lines up under "Output" instead of drifting.
    private func cell(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(UsageFormat.compactTokens(count))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelRow: View {
    let row: ModelUsageRow

    /// Column widths, and the reasoning behind them, live in `PopoverMetrics`
    /// so the budget can be asserted in a test.
    private typealias Metrics = PopoverMetrics.ModelRow

    var body: some View {
        HStack(spacing: Metrics.columnSpacing) {
            Text(row.identity.displayName)
                .font(.callout)
                .lineLimit(1)
                // Last resort only. A name long enough to need this shrinks
                // slightly instead of losing its tail, which is the difference
                // between reading small and not reading at all.
                .minimumScaleFactor(0.85)
                .frame(width: Metrics.nameWidth, alignment: .leading)

            Capsule()
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.barHeight)
                // GeometryReader inside an overlay, so the share can be a
                // fraction of a width this view does not get to choose. It
                // reads the already-resolved track bounds and imposes no size
                // of its own.
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, proxy.size.width * row.share))
                    }
                }

            Text(shareText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Metrics.shareWidth, alignment: .trailing)

            Text(UsageFormat.compactTokens(row.tokens.total))
                .font(.caption)
                .monospacedDigit()
                .frame(width: Metrics.totalWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.identity.displayName), \(shareText) of today's tokens, "
                + "\(UsageFormat.groupedInt(row.tokens.total)) tokens")
    }

    private var shareText: String {
        let percent = row.share * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// Tier colour, so the split reads at a glance. Grey means the family did not
    /// parse, which is also what an unpriced brand new model looks like.
    private var tint: Color {
        switch row.identity.family {
        case .fable, .mythos: .purple
        case .opus: .orange
        case .sonnet: .blue
        case .haiku: .green
        case .gpt: .cyan
        case .unknown: .gray
        }
    }
}

struct StatusBadge: View {
    let state: UsageMonitor.State

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch state {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .watching: "Live"
        case .failed: "Error"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: .secondary
        case .scanning: .yellow
        case .watching: .green
        case .failed: .red
        }
    }
}
