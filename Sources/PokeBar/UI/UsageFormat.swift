import Foundation

/// Display formatting for everything the popover and the status item render.
///
/// Deliberately hand-rolled rather than `NumberFormatter` / `RelativeDateTimeFormatter`:
/// these strings are asserted in tests, and the system formatters are locale- and
/// SDK-dependent, so the assertions would be testing the OS rather than this code.
/// The app runs on one machine for one user, so locale-aware grouping buys nothing.
enum UsageFormat {

    /// Three significant digits with a magnitude suffix: `1.85B`, `342M`, `12.1M`.
    ///
    /// Raw counts here reach 1.85 billion, so the status item and the summary rows
    /// cannot show grouped integers without either truncating or resizing on every
    /// update. Decimal places shrink as the mantissa grows, which keeps the rendered
    /// width roughly constant and stops the menu bar item from jittering.
    static func compactTokens(_ count: Int) -> String {
        let sign = count < 0 ? "-" : ""
        var value = Double(abs(count))
        let suffixes = ["", "K", "M", "B", "T"]
        var index = 0
        // 999.5 rather than 1000: 999_950 must promote to "1.00M", not round to
        // "1000K", which would be both wider and wrong-looking.
        while value >= 999.5, index < suffixes.count - 1 {
            value /= 1000
            index += 1
        }
        guard index > 0 else { return sign + String(Int(value.rounded())) }
        let decimals = value < 9.995 ? 2 : (value < 99.95 ? 1 : 0)
        return sign + String(format: "%.\(decimals)f", value) + suffixes[index]
    }

    /// Comma-grouped integer, for figures small enough to show exactly (coins).
    static func groupedInt(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (offset, char) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return (value < 0 ? "-" : "") + out
    }

    /// Always two decimal places. This is a hypothetical API-equivalent figure,
    /// not money spent, so it is never rounded to whole dollars: the cents make it
    /// read as a computed estimate rather than a bill.
    static func usd(_ amount: Double) -> String {
        // Rounded to integer cents first, then split. Taking the fractional part
        // of a Double instead lets a value like 2.9999999999999996 render as
        // "$2.100", because the cents field rounds up to 100 on its own.
        let cents = Int((abs(amount) * 100).rounded())
        let sign = amount < 0 ? "-" : ""
        return sign + "$" + groupedInt(cents / 100) + String(format: ".%02d", cents % 100)
    }

    /// Coarse relative age for the "updated" footer. `now` is injected so the
    /// thresholds are testable without waiting.
    static func relativeAge(of date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "just now" }
        switch seconds {
        case ..<45: return "just now"
        case ..<90: return "1 min ago"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<7200: return "1 hr ago"
        case ..<86400: return "\(Int(seconds / 3600)) hr ago"
        case ..<172_800: return "1 day ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }
}

/// The popover's fixed geometry, and the column budget the per-model usage rows
/// are laid out against.
///
/// Here rather than as literals in the view bodies for the reason the rest of
/// this file exists: the numbers have to *add up*, and a sum asserted in a view
/// body cannot be tested in this toolchain. `ModelRow.barWidth` is what is left
/// after the fixed columns, so a future widening of the name column shows up as
/// a failing test rather than as a bar squeezed to nothing on screen.
enum PopoverMetrics {

    /// A menu bar window, so this is a chosen width, not an available one.
    static let width: CGFloat = 340
    static let padding: CGFloat = 14
    /// What a pane actually gets to lay out in: 312pt.
    static var contentWidth: CGFloat { width - 2 * padding }

    /// One row of the per-model breakdown: `name | bar | share | total`.
    ///
    /// The name column is fixed and the **bar** flexes, which is the way round
    /// that both fills the row and keeps every bar starting and ending on the
    /// same x. Widths measured with `NSFont.systemFont`, not guessed: at 12pt
    /// (`.callout`) the widest name this can produce is
    /// `"GPT 5.6 Terra (Copilot)"` at 130.8pt, so 132 renders it whole. The old
    /// 74pt at 10pt cut `"Sonnet 5 (Copilot)"` down to `"Sonnet 5 (Co..."`.
    /// The numeric columns are 10pt monospaced digits: `"100%"` is 28.6pt and
    /// `"76.7M"` is 31.2pt, the widest either can hold.
    enum ModelRow {
        static let columnSpacing: CGFloat = 6
        static let nameWidth: CGFloat = 132
        static let shareWidth: CGFloat = 30
        static let totalWidth: CGFloat = 36
        static let barHeight: CGFloat = 5

        /// The slack the flexible bar receives. Derived, never typed in.
        static var barWidth: CGFloat {
            PopoverMetrics.contentWidth
                - (nameWidth + shareWidth + totalWidth + 3 * columnSpacing)
        }
    }
}

/// The tier a model belongs to, parsed from its identifier.
///
/// Only used for display grouping and colour. Currency weighting reads the real
/// multiplier out of `ModelPricing`, never this, so a family that parses to
/// `.unknown` costs nothing but a grey swatch.
enum ModelFamily: String, Sendable, CaseIterable {
    case fable, mythos, opus, sonnet, haiku, gpt, unknown
}

/// A model identifier split into something displayable.
///
/// Parsing, not a lookup table: the pricing table already has to be refreshed at
/// runtime because a hardcoded model list goes stale on every launch day (see
/// DECISIONS.md). A display name that has to be shipped per model would go stale
/// the same way, and read as blank or raw in the popover.
struct ModelIdentity: Sendable, Equatable {
    let raw: String
    let family: ModelFamily
    /// `claude-haiku-4-5-20251001` renders as `Haiku 4.5`.
    let displayName: String

    init(_ raw: String) {
        self.raw = raw

        // A ledger key carrying the Copilot marker renders as the underlying
        // model's normal name plus a visible tag, and keeps the underlying
        // model's family so the row's colour swatch still reads as its tier.
        // Claude Code and Codex entries never carry the prefix and are
        // unaffected: this is the *only* place source ever changes display.
        // The marker's spelling lives on `UsageSource`, not here.
        if UsageSource.isCopilotLedgerKey(raw) {
            let inner = ModelIdentity(UsageSource.model(fromLedgerKey: raw))
            family = inner.family
            displayName = "\(inner.displayName) (Copilot)"
            return
        }

        // `gpt-5.6-sol` renders as `GPT 5.6 Sol`. A bare `gpt-` falls back to
        // raw, the same way a bare `claude-` does below: a displayable name
        // with nothing after the prefix is worse than showing the id.
        if raw.hasPrefix("gpt-") {
            let parts = raw.dropFirst("gpt-".count).split(separator: "-").map(String.init)
            guard !parts.isEmpty else {
                family = .unknown
                displayName = raw
                return
            }
            family = .gpt
            displayName = "GPT " + parts.map { part in
                part.first?.isNumber == true ? part : part.capitalized
            }.joined(separator: " ")
            return
        }

        guard raw.hasPrefix("claude-") else {
            family = .unknown
            displayName = raw
            return
        }

        var parts = raw.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // A trailing 8-digit stamp is a snapshot date, not a version component.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let head = parts.first, !head.isEmpty else {
            family = .unknown
            displayName = raw
            return
        }

        family = ModelFamily(rawValue: head) ?? .unknown
        let version = parts.dropFirst().joined(separator: ".")
        displayName = version.isEmpty ? head.capitalized : "\(head.capitalized) \(version)"
    }
}

/// One row of the per-model breakdown.
struct ModelUsageRow: Sendable, Equatable, Identifiable {
    var id: String { key }
    /// Raw model id, or `ModelBreakdown.otherKey` for the collapsed tail.
    let key: String
    let identity: ModelIdentity
    let tokens: TokenCounts
    /// Fraction of the set's total tokens, 0...1.
    let share: Double
}

enum ModelBreakdown {

    /// Row key for the collapsed tail. Not a valid model id, so it cannot collide.
    static let otherKey = "\u{0000}other"

    /// Ranked rows, largest first, with anything past `limit` collapsed into one
    /// "Other" row.
    ///
    /// The collapse is a layout guard, not cosmetic: the popover is a fixed-width
    /// menu bar window, and a session that touched a dozen models would otherwise
    /// grow it past the screen. Zero-token models are dropped so a model that
    /// only ever appeared in a pruned turn does not occupy a row forever.
    static func rows(from byModel: [String: TokenCounts], limit: Int = 5) -> [ModelUsageRow] {
        let used = byModel.filter { $0.value.total > 0 }
        let total = used.values.reduce(0) { $0 + $1.total }
        guard total > 0 else { return [] }

        // Sorted by volume, then by id, because dictionary order is not stable
        // and rows must not shuffle between two publishes of identical data.
        let ranked = used.sorted {
            $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total
        }

        func row(_ key: String, _ tokens: TokenCounts) -> ModelUsageRow {
            ModelUsageRow(
                key: key,
                identity: ModelIdentity(key),
                tokens: tokens,
                share: Double(tokens.total) / Double(total))
        }

        guard ranked.count > limit else {
            return ranked.map { row($0.key, $0.value) }
        }

        var rows = ranked.prefix(limit - 1).map { row($0.key, $0.value) }
        let tail = ranked.dropFirst(limit - 1).reduce(into: TokenCounts.zero) { $0 += $1.value }
        rows.append(
            ModelUsageRow(
                key: otherKey,
                identity: ModelIdentity("Other"),
                tokens: tail,
                share: Double(tail.total) / Double(total)))
        return rows
    }
}
