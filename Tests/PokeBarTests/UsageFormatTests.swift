import XCTest

@testable import PokeBar

/// The views hold no logic worth testing; everything they render goes through
/// these pure functions, so this is where the display behaviour is pinned.
final class UsageFormatTests: XCTestCase {

    // MARK: - Compact tokens

    func testCompactTokensKeepsThreeSignificantDigits() {
        XCTAssertEqual(UsageFormat.compactTokens(0), "0")
        XCTAssertEqual(UsageFormat.compactTokens(573), "573")
        XCTAssertEqual(UsageFormat.compactTokens(999), "999")
        XCTAssertEqual(UsageFormat.compactTokens(1_000), "1.00K")
        XCTAssertEqual(UsageFormat.compactTokens(12_345), "12.3K")
        XCTAssertEqual(UsageFormat.compactTokens(342_492), "342K")
        XCTAssertEqual(UsageFormat.compactTokens(12_092_882), "12.1M")
        XCTAssertEqual(UsageFormat.compactTokens(342_492_125), "342M")
        // The real figures from the corpus: total volume and the cache-read share.
        XCTAssertEqual(UsageFormat.compactTokens(1_848_085_379), "1.85B")
        XCTAssertEqual(UsageFormat.compactTokens(1_711_257_073), "1.71B")
    }

    /// A mantissa that rounds to 1000 must promote to the next unit rather than
    /// render as "1000K", which is both wider and misleading.
    func testCompactTokensPromotesInsteadOfRoundingToFourDigits() {
        XCTAssertEqual(UsageFormat.compactTokens(999_950), "1.00M")
        XCTAssertEqual(UsageFormat.compactTokens(999_499), "999K")
    }

    func testCompactTokensHandlesNegatives() {
        XCTAssertEqual(UsageFormat.compactTokens(-1_500), "-1.50K")
    }

    // MARK: - Grouping and currency

    func testGroupedInt() {
        XCTAssertEqual(UsageFormat.groupedInt(0), "0")
        XCTAssertEqual(UsageFormat.groupedInt(999), "999")
        XCTAssertEqual(UsageFormat.groupedInt(1_000), "1,000")
        XCTAssertEqual(UsageFormat.groupedInt(33_456), "33,456")
        XCTAssertEqual(UsageFormat.groupedInt(1_234_567), "1,234,567")
        XCTAssertEqual(UsageFormat.groupedInt(-1_500), "-1,500")
    }

    func testUSD() {
        XCTAssertEqual(UsageFormat.usd(0), "$0.00")
        // The measured 31-day API-equivalent figure.
        XCTAssertEqual(UsageFormat.usd(3_513.84), "$3,513.84")
        XCTAssertEqual(UsageFormat.usd(113.35), "$113.35")
        XCTAssertEqual(UsageFormat.usd(9.999), "$10.00")
        // A single cheap turn must not read as free.
        XCTAssertEqual(UsageFormat.usd(0.0055), "$0.01")
    }

    /// Regression: splitting a rounded Double into whole and fractional parts can
    /// leave the cents field at 100, rendering "$2.100".
    func testUSDNeverRendersThreeDecimalPlaces() {
        for cents in 1...2_000 {
            let text = UsageFormat.usd(Double(cents) / 100)
            let fraction = text.split(separator: ".").last ?? ""
            XCTAssertEqual(fraction.count, 2, "\(text) is not a currency string")
        }
    }

    // MARK: - Relative age

    func testRelativeAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            UsageFormat.relativeAge(of: now.addingTimeInterval(-secondsAgo), now: now)
        }

        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(30), "just now")
        XCTAssertEqual(age(60), "1 min ago")
        XCTAssertEqual(age(120), "2 min ago")
        XCTAssertEqual(age(59 * 60), "59 min ago")
        XCTAssertEqual(age(3_600), "1 hr ago")
        XCTAssertEqual(age(5 * 3_600), "5 hr ago")
        XCTAssertEqual(age(25 * 3_600), "1 day ago")
        XCTAssertEqual(age(3 * 86_400), "3 days ago")
    }

    /// A future timestamp means the clock moved, not that usage is pending.
    func testRelativeAgeClampsFutureDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageFormat.relativeAge(of: now.addingTimeInterval(600), now: now), "just now")
    }

    // MARK: - Model identity

    func testModelDisplayNames() {
        XCTAssertEqual(ModelIdentity("claude-fable-5").displayName, "Fable 5")
        XCTAssertEqual(ModelIdentity("claude-opus-5").displayName, "Opus 5")
        XCTAssertEqual(ModelIdentity("claude-opus-4-8").displayName, "Opus 4.8")
        XCTAssertEqual(ModelIdentity("claude-sonnet-5").displayName, "Sonnet 5")
    }

    /// Snapshot ids carry a trailing date that is not a version component.
    func testModelDisplayNameDropsSnapshotDate() {
        let identity = ModelIdentity("claude-haiku-4-5-20251001")
        XCTAssertEqual(identity.displayName, "Haiku 4.5")
        XCTAssertEqual(identity.family, .haiku)
    }

    func testFamiliesParseForEveryPricedModel() {
        for model in ModelPricing.bundled.keys {
            XCTAssertNotEqual(
                ModelIdentity(model).family, .unknown,
                "\(model) should resolve to a tier colour")
        }
    }

    /// A model newer than the pricing table still has to render as a name. This
    /// is the display-side counterpart of pricing resolving to nil rather than
    /// to zero: unknown must look unknown, not blank.
    func testUnknownModelStillRendersAName() {
        let identity = ModelIdentity("claude-quasar-7")
        XCTAssertEqual(identity.displayName, "Quasar 7")
        XCTAssertEqual(identity.family, .unknown)
    }

    func testNonClaudeIdentifiersFallBackToRaw() {
        for raw in ["gpt-4o", "Other", "<synthetic>", "claude-", ""] {
            let identity = ModelIdentity(raw)
            XCTAssertEqual(identity.displayName, raw)
            XCTAssertEqual(identity.family, .unknown)
        }
    }

    // MARK: - Breakdown rows

    private func counts(_ total: Int) -> TokenCounts { TokenCounts(output: total) }

    func testBreakdownIsRankedAndSharesSumToOne() {
        let rows = ModelBreakdown.rows(from: [
            "claude-opus-5": counts(200),
            "claude-fable-5": counts(800),
            "claude-sonnet-5": counts(1_000),
        ])

        XCTAssertEqual(rows.map(\.key), ["claude-sonnet-5", "claude-fable-5", "claude-opus-5"])
        XCTAssertEqual(rows.map(\.identity.displayName), ["Sonnet 5", "Fable 5", "Opus 5"])
        XCTAssertEqual(rows.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(rows[0].share, 0.5, accuracy: 1e-9)
    }

    func testBreakdownDropsEmptyModelsAndEmptyInput() {
        XCTAssertTrue(ModelBreakdown.rows(from: [:]).isEmpty)
        XCTAssertTrue(ModelBreakdown.rows(from: ["claude-opus-5": .zero]).isEmpty)

        let rows = ModelBreakdown.rows(from: [
            "claude-opus-5": counts(10), "claude-haiku-4-5": .zero,
        ])
        XCTAssertEqual(rows.map(\.key), ["claude-opus-5"])
    }

    /// Equal volumes must not shuffle between publishes, because dictionary
    /// iteration order is not stable across two calls with identical data.
    func testBreakdownTiesBreakOnIdentifier() {
        let byModel = ["claude-sonnet-5": counts(50), "claude-opus-5": counts(50)]
        let first = ModelBreakdown.rows(from: byModel).map(\.key)
        XCTAssertEqual(first, ["claude-opus-5", "claude-sonnet-5"])
        for _ in 0..<20 {
            XCTAssertEqual(ModelBreakdown.rows(from: byModel).map(\.key), first)
        }
    }

    func testBreakdownCollapsesTheTail() {
        var byModel: [String: TokenCounts] = [:]
        for index in 1...7 { byModel["claude-model-\(index)"] = counts(index * 100) }

        let rows = ModelBreakdown.rows(from: byModel, limit: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.last?.key, ModelBreakdown.otherKey)
        XCTAssertEqual(rows.last?.identity.displayName, "Other")
        // 300 + 200 + 100 out of 2,800.
        XCTAssertEqual(rows.last?.tokens.total, 600)
        XCTAssertEqual(rows.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testBreakdownDoesNotCollapseAtTheLimit() {
        var byModel: [String: TokenCounts] = [:]
        for index in 1...5 { byModel["claude-model-\(index)"] = counts(index * 100) }

        let rows = ModelBreakdown.rows(from: byModel, limit: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertFalse(rows.contains { $0.key == ModelBreakdown.otherKey })
    }
}
