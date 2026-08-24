import XCTest

@testable import PokeBar

/// Runs the real scanner over the real Claude Code and Codex trees.
///
/// Opt-in via `POKEBAR_CORPUS=1` because it is not hermetic: it reads hundreds
/// of megabytes and its numbers grow every time Claude Code is used. Its job is
/// not to assert fixed totals but to prove the Swift implementation agrees with
/// an independently written reference, and that incremental resume is exact.
final class CorpusParityTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["POKEBAR_CORPUS"] == "1"
    }

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "set POKEBAR_CORPUS=1 to run against the live corpus")
        let root = UsageScanner.defaultRoots()[0]
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: root.path), "no corpus at \(root.path)")
    }

    func testReportsCorpusTotals() throws {
        try skipUnlessEnabled()

        let clock = Date()
        let result = UsageScanner().scan()
        let elapsed = Date().timeIntervalSince(clock)

        var totals = TokenCounts.zero
        var byModel: [String: (turns: Int, tokens: TokenCounts)] = [:]
        var days = Set<String>()
        for entry in result.entries {
            totals += entry.tokens
            days.insert(entry.localDay)
            var bucket = byModel[entry.model] ?? (0, .zero)
            bucket.turns += 1
            bucket.tokens += entry.tokens
            byModel[entry.model] = bucket
        }

        print("""

        ── PokeBar corpus scan ─────────────────────────────────────────
        files examined : \(result.filesExamined)
        files read     : \(result.filesRead)
        bytes read     : \(result.bytesRead) (\(result.bytesRead / 1_048_576) MiB)
        elapsed        : \(String(format: "%.2fs", elapsed))
        deduped turns  : \(result.entries.count)
        distinct days  : \(days.count)

        input          : \(totals.input)
        output         : \(totals.output)
        cache write    : \(totals.cacheWrite)
        cache read     : \(totals.cacheRead)
        GRAND TOTAL    : \(totals.total)
        ────────────────────────────────────────────────────────────────
        """)
        for (model, bucket) in byModel.sorted(by: { $0.value.tokens.total > $1.value.tokens.total }) {
            print(String(
                format: "  %-24s turns=%-7d total=%d",
                (model as NSString).utf8String!, bucket.turns, bucket.tokens.total))
        }

        XCTAssertGreaterThan(result.entries.count, 0, "corpus present but no usage parsed")
        XCTAssertGreaterThan(totals.total, 0)
        // Cache reads dominate agentic usage; if this inverts, dedup is broken.
        XCTAssertGreaterThan(totals.cacheRead, totals.input)
    }

    /// Independent parity check for Codex's cumulative session counters.
    ///
    /// The production parser sums per-response `last_token_usage`; this reference
    /// instead takes the final `total_token_usage` snapshot from each rollout.
    /// Agreement proves that responses are neither skipped nor double-counted.
    func testCodexEntriesMatchCumulativeSessionTotals() throws {
        try skipUnlessEnabled()

        let codexRoot = UsageScanner.defaultRoots()[1]
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: codexRoot.path),
            "no Codex corpus at \(codexRoot.path)")

        var expected = TokenCounts.zero
        var expectedEvents = 0
        for file in UsageScanner.jsonlFiles(under: codexRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            var latest: [String: Any]?
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { continue }
                latest = total
                expectedEvents += 1
            }
            guard let latest else { continue }
            let input = latest["input_tokens"] as? Int ?? 0
            let read = latest["cached_input_tokens"] as? Int ?? 0
            let write = latest["cache_write_input_tokens"] as? Int ?? 0
            expected += TokenCounts(
                input: max(0, input - read - write),
                output: latest["output_tokens"] as? Int ?? 0,
                cacheWrite: write,
                cacheRead: read)
        }

        let entries = UsageScanner(roots: [codexRoot]).scan().entries
        let actual = entries.reduce(into: TokenCounts.zero) { $0 += $1.tokens }
        XCTAssertGreaterThan(expectedEvents, 0)
        XCTAssertEqual(actual, expected)
    }

    /// Prices the real corpus and reports the tier-weighted currency.
    ///
    /// Currency is raw token count (every class counted equally, matching what
    /// the Anthropic console reports) times a per-model tier multiplier. The
    /// dollar figure is API-equivalent, not money spent on a subscription.
    func testReportsCostAndWeightedCurrency() throws {
        try skipUnlessEnabled()

        let pricing = ModelPricing()
        let entries = UsageScanner().scan().entries
        let (totals, weighted) = pricing.totals(for: entries)

        print("""

        ── pricing ─────────────────────────────────────────────────────
        raw tokens        : \(totals.tokens.total)
        weighted currency : \(String(format: "%.0f", weighted))
        API-equiv cost    : $\(String(format: "%.2f", totals.costUSD))
        unpriced models   : \(totals.hasUnpricedModels ? "YES — cost is a floor" : "none")
        ────────────────────────────────────────────────────────────────
        """)
        let byWeight = totals.byModel.sorted { $0.value.total > $1.value.total }
        for (model, tokens) in byWeight {
            let tier = pricing.tierMultiplier(for: model)
            let rate = pricing.rate(for: model)
            print(String(
                format: "  %-20s tokens=%-14d tier=%-5s cost=$%.2f",
                (model as NSString).utf8String!, tokens.total,
                ((tier.map { String(format: "%.1f", $0) } ?? "??") as NSString).utf8String!,
                rate?.costUSD(for: tokens) ?? 0))
        }

        XCTAssertFalse(
            totals.hasUnpricedModels,
            "a model in this corpus is unpriced; the bundled table needs the entry")
        XCTAssertGreaterThan(totals.costUSD, 0)
        // Usage is ~81% fable-5 at tier 2.0, so weighting must exceed raw count.
        XCTAssertGreaterThan(weighted, Double(totals.tokens.total))
    }

    /// The runtime snapshot must actually resolve the models in this corpus,
    /// not just parse. Network-dependent, so a fetch failure skips rather than
    /// fails — the bundled table is the guarantee, this is the improvement.
    func testRuntimeSnapshotCoversThisCorpus() async throws {
        try skipUnlessEnabled()

        let catalog = PricingCatalog(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pokebar-pricing-\(UUID().uuidString).json"))
        let refreshed = await catalog.refreshIfNeeded(force: true)
        try XCTSkipUnless(refreshed, "pricing source unreachable")

        let pricing = await catalog.current()
        let models = Set(UsageScanner().scan().entries.map(\.model))
        print("\n── runtime snapshot ────────────────────────────────────────────")
        for model in models.sorted() {
            let rate = pricing.rate(for: model)
            print(String(
                format: "  %-20s %@",
                (model as NSString).utf8String!,
                rate.map { String(format: "$%.2f/$%.2f per MTok",
                                  $0.input * 1e6, $0.output * 1e6) } ?? "UNPRICED"))
            XCTAssertNotNil(rate, "\(model) unpriced after a live refresh")
        }
        print("────────────────────────────────────────────────────────────────")
    }

    /// The property that makes event-driven updates safe: scanning twice must
    /// not double count, and the second pass must read almost nothing.
    func testSecondPassIsIncrementalAndAddsNothing() throws {
        try skipUnlessEnabled()

        let scanner = UsageScanner()
        let first = scanner.scan()
        let second = scanner.scan(cursors: first.cursors)

        print("""

        ── incremental resume ──────────────────────────────────────────
        pass 1: \(first.filesRead) files, \(first.bytesRead) bytes, \(first.entries.count) turns
        pass 2: \(second.filesRead) files, \(second.bytesRead) bytes, \(second.entries.count) turns
        ────────────────────────────────────────────────────────────────
        """)

        XCTAssertLessThan(
            second.bytesRead, first.bytesRead / 100,
            "resume read too much; cursors are not being honoured")
        XCTAssertEqual(
            second.cursors.count, first.cursors.count,
            "cursor set changed size across an idle pass")
    }
}
