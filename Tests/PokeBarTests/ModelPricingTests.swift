import XCTest

@testable import PokeBar

final class ModelPricingTests: XCTestCase {

    private let pricing = ModelPricing()

    // MARK: - Rates

    func testBundledRatesForEveryModelInUseOnThisMachine() throws {
        for model in [
            "claude-fable-5", "claude-opus-5", "claude-opus-4-8", "claude-sonnet-5",
            "gpt-5.6-sol",
        ] {
            XCTAssertNotNil(pricing.rate(for: model), "\(model) must be priced")
        }
    }

    /// Pins the published OpenAI rates, re-verified 2026-08-24. The first cut of
    /// this branch carried every GPT figure at half its real value, which is
    /// invisible in the dollar readout but not in the game: the Sol tier
    /// multiplier came out 0.5 instead of 0.8, and coins are frozen at credit
    /// time, so tokens credited under a wrong weight can never be corrected.
    func testCodexModelRates() throws {
        let sol = try XCTUnwrap(pricing.rate(for: "gpt-5.6-sol"))
        XCTAssertEqual(sol.input * 1_000_000, 4, accuracy: 0.001)
        XCTAssertEqual(sol.output * 1_000_000, 20, accuracy: 0.001)
        XCTAssertEqual(sol.cacheWrite * 1_000_000, 5, accuracy: 0.001)
        XCTAssertEqual(sol.cacheRead * 1_000_000, 0.4, accuracy: 0.001)

        let terra = try XCTUnwrap(pricing.rate(for: "gpt-5.6-terra"))
        XCTAssertEqual(terra.input * 1_000_000, 2, accuracy: 0.001)
        XCTAssertEqual(terra.output * 1_000_000, 12, accuracy: 0.001)

        let luna = try XCTUnwrap(pricing.rate(for: "gpt-5.6-luna"))
        XCTAssertEqual(luna.input * 1_000_000, 0.2, accuracy: 0.001)
        XCTAssertEqual(luna.output * 1_000_000, 1.2, accuracy: 0.001)
    }

    /// The load-bearing half of the rate table. A wrong input rate is a wrong
    /// currency weight, and `ModelPricing` derives the multiplier rather than
    /// storing it, so this is the assertion that catches a bad GPT figure.
    func testCodexTierMultiplierIsDerivedFromTheOpusBaseline() throws {
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "gpt-5.6-sol")), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "gpt-5.6-terra")), 0.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "gpt-5.6-luna")), 0.04, accuracy: 1e-9)
    }

    /// Cache classes follow input on the GPT entries too, even though output
    /// does not. Scoped separately from `testWithinModelRatiosAreUniform`,
    /// which now covers Claude only.
    func testCodexCacheRatiosFollowInput() throws {
        for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            let rate = try XCTUnwrap(pricing.rate(for: model))
            XCTAssertEqual(rate.cacheWrite / rate.input, 1.25, accuracy: 1e-9, "\(model) cacheWrite")
            XCTAssertEqual(rate.cacheRead / rate.input, 0.1, accuracy: 1e-9, "\(model) cacheRead")
        }
    }

    /// The concrete upstream defect: no entry for the two newest models, so
    /// 342,492,125 tokens (18.5% of this corpus) priced at $0.00.
    func testOpusFiveAndSonnetFiveArePriced() throws {
        let opus = try XCTUnwrap(pricing.rate(for: "claude-opus-5"))
        XCTAssertEqual(opus.input * 1_000_000, 5, accuracy: 0.001)
        XCTAssertEqual(opus.output * 1_000_000, 25, accuracy: 0.001)
        XCTAssertEqual(opus.cacheWrite * 1_000_000, 6.25, accuracy: 0.001)
        XCTAssertEqual(opus.cacheRead * 1_000_000, 0.5, accuracy: 0.001)

        let sonnet = try XCTUnwrap(pricing.rate(for: "claude-sonnet-5"))
        // List, not the introductory $2 that lapses 2026-08-31, so the tier
        // multiplier does not shift under us when the promo ends.
        XCTAssertEqual(sonnet.input * 1_000_000, 3, accuracy: 0.001)
    }

    /// The source carries ten prefixed variants of claude-opus-5, including
    /// `au.anthropic.claude-opus-5` at a 10% markup. Fuzzy matching would pick
    /// one up silently.
    func testLookupIsExactKeyOnly() {
        for variant in [
            "anthropic.claude-opus-5", "au.anthropic.claude-opus-5",
            "azure_ai/claude-opus-5", "vertex_ai/claude-opus-5",
            "openrouter/anthropic/claude-opus-5", "us.anthropic.claude-opus-5",
        ] {
            XCTAssertNil(pricing.rate(for: variant), "\(variant) must not resolve")
        }
    }

    func testUnknownModelResolvesToNilNotZero() {
        XCTAssertNil(pricing.rate(for: "claude-something-7"))
        XCTAssertNil(pricing.tierMultiplier(for: "claude-something-7"))
    }

    // MARK: - Tier multipliers

    func testTierMultipliersRelativeToOpusBaseline() throws {
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "claude-opus-5")), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "claude-fable-5")), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "claude-sonnet-5")), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.tierMultiplier(for: "claude-haiku-4-5")), 0.2, accuracy: 1e-9)
    }

    /// Every current Claude model prices output at 5x input, cache write at
    /// 1.25x, cache read at 0.1x. The parser relies on this only as a
    /// per-missing-field fallback, but if it ever stops holding in the bundled
    /// table that is worth knowing about.
    func testWithinModelRatiosAreUniform() throws {
        for (model, rate) in ModelPricing.bundled where model.hasPrefix("claude-") {
            XCTAssertEqual(rate.output / rate.input, 5.0, accuracy: 1e-9, "\(model) output")
            XCTAssertEqual(rate.cacheWrite / rate.input, 1.25, accuracy: 1e-9, "\(model) cacheWrite")
            XCTAssertEqual(rate.cacheRead / rate.input, 0.1, accuracy: 1e-9, "\(model) cacheRead")
        }
    }

    // MARK: - Aggregation

    func testCostMath() throws {
        let entry = UsageEntry(
            id: "a", date: Date(), model: "claude-opus-5", source: .claudeCode,
            tokens: TokenCounts(
                input: 1_000_000, output: 1_000_000,
                cacheWrite: 1_000_000, cacheRead: 1_000_000),
            localDay: "2026-08-22")
        let (totals, weighted) = pricing.totals(for: [entry])
        // 5 + 25 + 6.25 + 0.5
        XCTAssertEqual(totals.costUSD, 36.75, accuracy: 0.0001)
        XCTAssertFalse(totals.hasUnpricedModels)
        XCTAssertEqual(weighted, 4_000_000, accuracy: 0.001, "opus tier is 1.0")
    }

    func testFableEarnsDoubleOpusForIdenticalUsage() {
        func weighted(_ model: String) -> Double {
            pricing.totals(for: [
                UsageEntry(
                    id: "x", date: Date(), model: model, source: .claudeCode,
                    tokens: TokenCounts(input: 100, output: 0, cacheWrite: 0, cacheRead: 0),
                    localDay: "2026-08-22")
            ]).weightedTokens
        }
        XCTAssertEqual(weighted("claude-fable-5"), weighted("claude-opus-5") * 2, accuracy: 1e-9)
    }

    /// An unknown model must still earn (at baseline) and must flag the cost as
    /// incomplete — never report $0.00 as though it were free.
    func testUnknownModelEarnsAtBaselineAndFlagsCost() {
        let entry = UsageEntry(
            id: "a", date: Date(), model: "claude-future-9", source: .claudeCode,
            tokens: TokenCounts(input: 500, output: 0, cacheWrite: 0, cacheRead: 0),
            localDay: "2026-08-22")
        let (totals, weighted) = pricing.totals(for: [entry])
        XCTAssertTrue(totals.hasUnpricedModels)
        XCTAssertEqual(totals.costUSD, 0)
        XCTAssertEqual(weighted, 500 * ModelPricing.unknownModelTierMultiplier, accuracy: 1e-9)
    }

    func testPerModelBreakdownAccumulates() {
        let entries = (0..<3).map {
            UsageEntry(
                id: "e\($0)", date: Date(), model: "claude-opus-5", source: .claudeCode,
                tokens: TokenCounts(input: 10, output: 20, cacheWrite: 0, cacheRead: 0),
                localDay: "2026-08-22")
        }
        let (totals, _) = pricing.totals(for: entries)
        XCTAssertEqual(totals.byModel["claude-opus-5"]?.input, 30)
        XCTAssertEqual(totals.byModel["claude-opus-5"]?.output, 60)
        XCTAssertEqual(totals.tokens.total, 90)
    }

    // MARK: - Runtime snapshot parsing

    func testParserKeepsBareKeysAndDropsPrefixedVariants() throws {
        let json = """
        {
          "claude-opus-5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6,
                            "cache_creation_input_token_cost": 6.25e-6,
                            "cache_read_input_token_cost": 0.5e-6},
          "au.anthropic.claude-opus-5": {"input_cost_per_token": 5.5e-6,
                                         "output_cost_per_token": 27.5e-6},
          "azure_ai/claude-opus-5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6},
          "gpt-5.5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 30e-6}
        }
        """
        let parsed = try XCTUnwrap(PricingCatalog.parse(Data(json.utf8)))
        XCTAssertEqual(Set(parsed.keys), ["claude-opus-5"], "only the bare Claude key survives")
        XCTAssertEqual(try XCTUnwrap(parsed["claude-opus-5"]).input * 1_000_000, 5, accuracy: 0.001)
    }

    func testParserFallsBackToUniformRatiosForMissingCacheFields() throws {
        let json = """
        {"claude-test-1": {"input_cost_per_token": 4e-6, "output_cost_per_token": 20e-6}}
        """
        let rate = try XCTUnwrap(PricingCatalog.parse(Data(json.utf8))?["claude-test-1"])
        XCTAssertEqual(rate.cacheWrite * 1_000_000, 5.0, accuracy: 0.001, "1.25x input")
        XCTAssertEqual(rate.cacheRead * 1_000_000, 0.4, accuracy: 0.001, "0.1x input")
    }

    func testParserRejectsGarbage() {
        XCTAssertNil(PricingCatalog.parse(Data("not json".utf8)))
        XCTAssertNil(PricingCatalog.parse(Data("{}".utf8)), "no Claude keys means no snapshot")
        XCTAssertNil(
            PricingCatalog.parse(Data(#"{"claude-x": {"input_cost_per_token": 0}}"#.utf8)),
            "a zero rate is not a valid price")
    }

    /// A fetched snapshot must win over the bundled entry, so a corrected or
    /// newly-published rate takes effect without a rebuild.
    func testFetchedRatesOverrideBundled() {
        let override = ModelRate.perMillion(
            input: 99, output: 99, cacheWrite: 99, cacheRead: 99)
        let merged = ModelPricing(
            table: ModelPricing.bundled.merging(["claude-opus-5": override]) { _, new in new })
        XCTAssertEqual(merged.rate(for: "claude-opus-5")?.input, override.input)
        XCTAssertNotNil(merged.rate(for: "claude-fable-5"), "bundled entries survive the merge")
    }
}
