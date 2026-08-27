import AppKit
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
        XCTAssertEqual(ModelIdentity("gpt-5.6-sol").displayName, "GPT 5.6 Sol")
        XCTAssertEqual(ModelIdentity("gpt-5.6-sol").family, .gpt)
    }

    /// A Copilot-sourced ledger key renders as the underlying model's normal
    /// name plus a visible tag, so the same model used through both Claude Code
    /// and Copilot CLI reads as two distinguishable rows, not one merged total.
    /// Claude Code and Codex are unaffected: they never carry this prefix.
    func testCopilotLedgerKeyAppendsASourceTag() {
        let identity = ModelIdentity("copilot:claude-opus-5")
        XCTAssertEqual(identity.displayName, "Opus 5 (Copilot)")
        XCTAssertEqual(identity.family, .opus, "colour grouping still follows the underlying model")

        XCTAssertEqual(ModelIdentity("copilot:gpt-5.6-luna").displayName, "GPT 5.6 Luna (Copilot)")
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

    /// A GPT id older or newer than `gpt-5.6-*` still has to render. The
    /// number-vs-word branch is the whole point: version components stay as
    /// written, names get capitalised.
    func testGPTDisplayNamesKeepVersionsAndCapitaliseNames() {
        XCTAssertEqual(ModelIdentity("gpt-4o").displayName, "GPT 4o")
        XCTAssertEqual(ModelIdentity("gpt-4o").family, .gpt)
        XCTAssertEqual(ModelIdentity("gpt-5.6-terra").displayName, "GPT 5.6 Terra")
        XCTAssertEqual(ModelIdentity("gpt-5.6-luna").displayName, "GPT 5.6 Luna")
    }

    func testUnknownProviderIdentifiersFallBackToRaw() {
        // "gpt-" is the GPT-side counterpart of "claude-": a prefix with
        // nothing after it renders as the raw id, not as "GPT ".
        for raw in ["Other", "<synthetic>", "claude-", "gpt-", ""] {
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

    // MARK: Popover geometry

    /// The per-model row's columns are fixed and the bar takes the slack, so the
    /// budget has to leave the bar something to be. Widening the name column
    /// past its share is a silent change: the row still lays out, the bar just
    /// collapses to its 3pt minimum and stops carrying any information.

    // MARK: Project breakdown

    func testProjectBreakdownIsRankedAndSharesAreOfTheDay() {
        let rows = ProjectBreakdown.rows(
            from: [
                "/work/PokeBar": counts(600),
                "/work/hue-scenes": counts(300),
                "/work/tiny": counts(100),
            ],
            dayTotal: 1_000)

        XCTAssertEqual(rows.map(\.name), ["PokeBar", "hue-scenes", "tiny"])
        XCTAssertEqual(rows.map(\.tokens), [600, 300, 100])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rows[0].share, 0.6, accuracy: 1e-9)
    }

    /// The whole reason `dayTotal` is a parameter. `dailyByProject` is
    /// forward-only, so on the day it ships the attributed rows are short of the
    /// day's real total, and shares taken against the rows would each read too
    /// high while the section quietly claimed to cover the day.
    func testProjectBreakdownSurfacesWhatPredatesTheTable() {
        let rows = ProjectBreakdown.rows(
            from: ["/work/PokeBar": counts(250)], dayTotal: 1_000)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.key, ProjectBreakdown.beforeTrackingKey)
        XCTAssertEqual(rows.first?.name, "Before this update")
        XCTAssertEqual(rows.first?.tokens, 750)
        XCTAssertEqual(rows.last?.name, "PokeBar")
        XCTAssertEqual(rows.last?.share ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
    }

    /// The ordinary case, once a day has been fully tracked: no remainder row at
    /// all. It must not appear as a permanent zero-token fixture.
    func testProjectBreakdownAddsNoRemainderWhenTheDayIsFullyAttributed() {
        let byProject = ["/work/PokeBar": counts(600), "/work/hue": counts(400)]
        for total in [1_000, nil] as [Int?] {
            let rows = ProjectBreakdown.rows(from: byProject, dayTotal: total)
            XCTAssertEqual(rows.count, 2, "dayTotal \(String(describing: total))")
            XCTAssertFalse(rows.contains { $0.key == ProjectBreakdown.beforeTrackingKey })
        }
    }

    /// A day total *below* the attributed sum cannot happen (both tables take the
    /// same delta), but if it ever did, negative shares would be the visible
    /// symptom. Clamped instead.
    func testProjectBreakdownIgnoresADayTotalBelowWhatIsAttributed() {
        let rows = ProjectBreakdown.rows(from: ["/work/a": counts(500)], dayTotal: 100)
        XCTAssertEqual(rows.map(\.share), [1.0])
        XCTAssertFalse(rows.contains { $0.key == ProjectBreakdown.beforeTrackingKey })
    }

    /// Attribution is per working directory, so two directories really can share
    /// a last component. Showing both as "Assets.xcassets" is silent: the two
    /// numbers look like they should have been one.
    func testProjectBreakdownQualifiesCollidingNames() {
        let rows = ProjectBreakdown.rows(
            from: [
                "/work/PokeBar/Assets.xcassets": counts(300),
                "/work/PokeFit/Assets.xcassets": counts(200),
                "/work/PokeBar": counts(100),
            ],
            dayTotal: 600)

        XCTAssertEqual(
            rows.map(\.name), ["PokeBar/Assets.xcassets", "PokeFit/Assets.xcassets", "PokeBar"],
            "only the colliding pair is qualified")
    }

    func testProjectBreakdownNamesTheUnknownAndHomeKeys() {
        let rows = ProjectBreakdown.rows(
            from: [Project.unknown: counts(30), "/Users/someone": counts(10)],
            dayTotal: 40, home: "/Users/someone")
        XCTAssertEqual(rows.map(\.name), ["Unknown", "Home"])
    }

    func testProjectBreakdownCollapsesTheTail() {
        var byProject: [String: TokenCounts] = [:]
        for i in 0..<9 { byProject["/work/p\(i)"] = counts(100 - i) }
        let rows = ProjectBreakdown.rows(from: byProject, limit: 5)

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.last?.key, ProjectBreakdown.otherKey)
        XCTAssertEqual(rows.last?.name, "5 more", "the tail says how many it stands for")
        XCTAssertEqual(rows.last?.tokens, (4..<9).reduce(0) { $0 + (100 - $1) })
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
    }

    func testProjectBreakdownDoesNotCollapseAtTheLimit() {
        var byProject: [String: TokenCounts] = [:]
        for i in 0..<5 { byProject["/work/p\(i)"] = counts(100 - i) }
        let rows = ProjectBreakdown.rows(from: byProject, limit: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertFalse(rows.contains { $0.key == ProjectBreakdown.otherKey })
    }

    /// Dictionary order is not stable, and these rows are re-derived on every
    /// publish. Two publishes of identical data must not reshuffle the pane.
    func testProjectBreakdownTiesBreakOnKey() {
        let byProject = ["/work/b": counts(10), "/work/a": counts(10), "/work/c": counts(10)]
        let first = ProjectBreakdown.rows(from: byProject).map(\.key)
        XCTAssertEqual(first, ["/work/a", "/work/b", "/work/c"])
        for _ in 0..<20 {
            XCTAssertEqual(ProjectBreakdown.rows(from: byProject).map(\.key), first)
        }
    }

    func testProjectBreakdownDropsEmptyProjectsAndEmptyInput() {
        XCTAssertTrue(ProjectBreakdown.rows(from: [:]).isEmpty)
        XCTAssertTrue(ProjectBreakdown.rows(from: ["/work/a": .zero]).isEmpty)
        XCTAssertTrue(ProjectBreakdown.rows(from: [:], dayTotal: 0).isEmpty)

        let rows = ProjectBreakdown.rows(from: ["/work/a": counts(5), "/work/b": .zero])
        XCTAssertEqual(rows.map(\.key), ["/work/a"])
    }

    /// The reserved keys must be unreachable as real projects, since a row's
    /// identity is its key and a collision would merge a directory into the
    /// bookkeeping row.
    func testReservedProjectKeysCannotBeDirectories() {
        for key in [ProjectBreakdown.otherKey, ProjectBreakdown.beforeTrackingKey] {
            XCTAssertTrue(key.hasPrefix("\u{0000}"))
            XCTAssertNotEqual(key, Project.unknown)
        }
        XCTAssertNotEqual(ProjectBreakdown.otherKey, ProjectBreakdown.beforeTrackingKey)
    }

    /// No em dashes in anything a user reads, including the names this assembles.
    func testProjectBreakdownCopyAvoidsEmDashes() {
        var byProject: [String: TokenCounts] = [Project.unknown: counts(1)]
        for i in 0..<9 { byProject["/work/p\(i)"] = counts(100 - i) }
        for row in ProjectBreakdown.rows(from: byProject, dayTotal: 5_000) {
            XCTAssertFalse(row.name.contains("\u{2014}"), row.name)
            XCTAssertFalse(row.name.contains("\u{2013}"), row.name)
        }
    }

    func testModelRowColumnsLeaveTheBarAUsableWidth() {
        let row = PopoverMetrics.ModelRow.self
        let fixed = row.nameWidth + row.shareWidth + row.totalWidth + 3 * row.columnSpacing
        XCTAssertLessThan(fixed, PopoverMetrics.contentWidth, "the row must fit the pane")
        XCTAssertEqual(row.barWidth, PopoverMetrics.contentWidth - fixed, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            row.barWidth, 60,
            "a share bar narrower than this reads as a dot, not a proportion")
    }

    /// The name column has to hold the longest name the breakdown can produce,
    /// which is now a Copilot-tagged GPT id. Measured with `NSFont` at 12pt
    /// (`.callout`): `"GPT 5.6 Terra (Copilot)"` is 130.8pt. Asserted as a
    /// character budget rather than by measuring a font here, because measuring
    /// one in a test asserts the OS rather than this code.
    func testNameColumnIsBudgetedForTheLongestTaggedName() {
        let longest = ModelIdentity("copilot:gpt-5.6-terra").displayName
        XCTAssertEqual(longest, "GPT 5.6 Terra (Copilot)")
        // 12pt system text averages just under 5.7pt per character across this
        // set, so the column is sized at 132pt for a 23 character worst case.
        XCTAssertGreaterThanOrEqual(
            PopoverMetrics.ModelRow.nameWidth, CGFloat(longest.count) * 5.7)
    }

    /// The Raise pane is sized to its content and then clamped, because it holds
    /// a single card on a fresh install and six slots plus a bench later. A fixed
    /// frame would mean dead space at one end and a 900pt popover at the other.
    func testRaisePaneClampsItsMeasuredHeight() {
        let pane = PopoverMetrics.RaisePane.self
        XCTAssertEqual(pane.height(forContent: 0), pane.minHeight, "before the first measure")
        XCTAssertEqual(pane.height(forContent: 90), pane.minHeight)
        XCTAssertEqual(pane.height(forContent: 200), 200, "a short team gets no dead space")
        XCTAssertEqual(pane.height(forContent: 900), pane.maxHeight, "past this it scrolls")
        XCTAssertLessThan(pane.minHeight, pane.maxHeight)
    }

    /// The PC pane starts *empty* rather than small, which is the one way it
    /// differs from the Raise pane: a fresh install has nothing stored, and a
    /// fixed 300pt of nothing is worse than a short pane.
    func testPCPaneClampsItsMeasuredHeight() {
        let pane = PopoverMetrics.PCPane.self
        XCTAssertEqual(pane.height(forContent: 0), pane.minHeight)
        XCTAssertEqual(pane.height(forContent: 180), 180)
        XCTAssertEqual(pane.height(forContent: 900), pane.maxHeight)
        XCTAssertLessThan(pane.minHeight, pane.maxHeight)
    }

    /// **The tab bar fits, and it is nearly full.**
    ///
    /// `SegmentedTabs` distributes `.fillEqually`, so AppKit will happily hand
    /// back a control wider than the pane and let the labels truncate rather than
    /// refuse to lay out. Five tabs measure 300pt against the pane's 312pt, so
    /// there is 12pt spare and a sixth tab does not fit. Measured here rather
    /// than asserted as a constant, because the answer depends on the system font
    /// and this is the check that would catch a name change like "PC" to "Storage"
    /// silently truncating every other label.
    func testTheTabBarFitsThePane() {
        let control = NSSegmentedControl(
            labels: PokeBarPopover.Pane.allCases.map(\.rawValue),
            trackingMode: .selectOne, target: nil, action: nil)
        control.segmentDistribution = .fillEqually
        XCTAssertLessThanOrEqual(
            control.intrinsicContentSize.width, PopoverMetrics.contentWidth,
            "the tabs no longer fit; shorten a label or drop one")
    }
}
