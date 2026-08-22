import XCTest

@testable import PokeBar

private func entry(
    id: String = "msg|req",
    model: String = "claude-opus-5",
    input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
    day: String = "2026-08-22",
    date: Date = Date()
) -> UsageEntry {
    UsageEntry(
        id: id, date: date, model: model,
        tokens: TokenCounts(
            input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead),
        localDay: day)
}

final class UsageLedgerTests: XCTestCase {

    private let pricing = ModelPricing()

    func testCreditsANewEntryInFull() {
        var ledger = UsageLedger()
        let added = ledger.credit([entry(input: 10, output: 20)], pricing: pricing)

        XCTAssertEqual(added, TokenCounts(input: 10, output: 20, cacheWrite: 0, cacheRead: 0))
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 30)
        XCTAssertEqual(ledger.weightedTokens, 30, accuracy: 1e-9, "opus tier 1.0")
    }

    /// The idempotence that lets the caller rescan on every filesystem tick.
    func testRecreditingUnchangedEntriesAddsNothing() {
        var ledger = UsageLedger()
        let e = entry(input: 10, output: 20)
        ledger.credit([e], pricing: pricing)
        let second = ledger.credit([e], pricing: pricing)

        XCTAssertEqual(second, .zero)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 30, "no double count")
        XCTAssertEqual(ledger.weightedTokens, 30, accuracy: 1e-9)
    }

    /// The straddling-scan case: a turn seen partially, then completed.
    func testCreditsOnlyTheGrowthWhenATurnCompletesAcrossScans() {
        var ledger = UsageLedger()
        // Pass 1: streaming, output still small.
        ledger.credit([entry(input: 100, output: 5, cacheRead: 900)], pricing: pricing)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 1005)

        // Pass 2: same turn, response finished.
        let added = ledger.credit(
            [entry(input: 100, output: 700, cacheRead: 900)], pricing: pricing)

        XCTAssertEqual(added.output, 695, "only the output growth is new")
        XCTAssertEqual(added.input, 0, "input does not grow")
        XCTAssertEqual(added.cacheRead, 0, "cache read does not grow")
        XCTAssertEqual(
            ledger.tokens(forDay: "2026-08-22").total, 1700,
            "total must equal the completed turn, not the sum of both copies")
    }

    /// Naive accumulation across the same two passes would report 2,705.
    func testNaiveAccumulationWouldOvercount() {
        let partial = entry(input: 100, output: 5, cacheRead: 900)
        let complete = entry(input: 100, output: 700, cacheRead: 900)
        XCTAssertEqual(partial.tokens.total + complete.tokens.total, 2705)

        var ledger = UsageLedger()
        ledger.credit([partial], pricing: pricing)
        ledger.credit([complete], pricing: pricing)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 1700)
    }

    /// A later copy reporting fewer tokens must never subtract earned currency.
    func testShrinkingTokenCountsAreIgnored() {
        var ledger = UsageLedger()
        ledger.credit([entry(output: 700)], pricing: pricing)
        let added = ledger.credit([entry(output: 5)], pricing: pricing)

        XCTAssertEqual(added, .zero)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 700)
        XCTAssertEqual(ledger.weightedTokens, 700, accuracy: 1e-9)
    }

    func testDistinctTurnsBothCredit() {
        var ledger = UsageLedger()
        ledger.credit(
            [entry(id: "a", output: 10), entry(id: "b", output: 20)], pricing: pricing)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 30)
    }

    func testWeightingUsesModelTier() {
        var ledger = UsageLedger()
        ledger.credit([entry(id: "f", model: "claude-fable-5", output: 100)], pricing: pricing)
        ledger.credit([entry(id: "o", model: "claude-opus-5", output: 100)], pricing: pricing)
        // fable 2.0 + opus 1.0
        XCTAssertEqual(ledger.weightedTokens, 300, accuracy: 1e-9)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 200, "raw count is unweighted")
    }

    func testUnknownModelCreditsAtBaselineRatherThanZero() {
        var ledger = UsageLedger()
        ledger.credit([entry(model: "claude-future-9", output: 100)], pricing: pricing)
        XCTAssertEqual(
            ledger.weightedTokens, 100 * ModelPricing.unknownModelTierMultiplier, accuracy: 1e-9)
    }

    func testSeparatesDays() {
        var ledger = UsageLedger()
        ledger.credit([entry(id: "a", output: 10, day: "2026-08-21")], pricing: pricing)
        ledger.credit([entry(id: "b", output: 20, day: "2026-08-22")], pricing: pricing)

        XCTAssertEqual(ledger.tokens(forDay: "2026-08-21").total, 10)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 20)
        XCTAssertEqual(ledger.allTimeByModel()["claude-opus-5"]?.total, 30)
    }

    func testPrunesInFlightEntriesPastTheGrowthWindow() {
        var ledger = UsageLedger()
        let old = Date(timeIntervalSinceNow: -UsageLedger.growthWindow - 3600)
        ledger.credit([entry(id: "old", output: 10, date: old)], pricing: pricing)
        XCTAssertEqual(ledger.inFlight.count, 0, "aged-out entries drop from growth tracking")

        // The credited tokens survive the prune — only growth tracking is lost.
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 10)
    }

    /// Consequence of pruning: an entry that somehow grows after aging out is
    /// credited again. Acceptable because a turn stops growing in seconds, but
    /// worth pinning so the tradeoff is visible.
    func testAgedOutEntryGrowingAgainIsRecredited() {
        var ledger = UsageLedger()
        let old = Date(timeIntervalSinceNow: -UsageLedger.growthWindow - 3600)
        ledger.credit([entry(id: "x", output: 10, date: old)], pricing: pricing)
        ledger.credit([entry(id: "x", output: 10, date: old)], pricing: pricing)
        XCTAssertEqual(ledger.tokens(forDay: "2026-08-22").total, 20)
    }

    func testCoinsScaleByTokensPerCoin() {
        var ledger = UsageLedger()
        ledger.credit(
            [entry(output: Int(UsageLedger.tokensPerCoin) * 3)], pricing: pricing)
        XCTAssertEqual(ledger.coins, 3)
    }

    func testRoundTripsThroughCodable() throws {
        var ledger = UsageLedger()
        ledger.credit([entry(input: 5, output: 700, cacheRead: 900)], pricing: pricing)

        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(UsageLedger.self, from: data)

        XCTAssertEqual(restored, ledger)
        // The point of persisting: a relaunch keeps totals and does not
        // re-credit a turn it already saw.
        var reopened = restored
        let added = reopened.credit(
            [entry(input: 5, output: 700, cacheRead: 900)], pricing: pricing)
        XCTAssertEqual(added, .zero, "restored in-flight state prevents re-crediting")
    }
}
