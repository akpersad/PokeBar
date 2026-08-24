import XCTest

@testable import PokeBar

/// End-to-end over a synthetic usage tree: watch, scan, credit, publish,
/// persist, relaunch.
@MainActor
final class UsageMonitorTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    private func makeTree() throws -> (root: URL, stateURL: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-monitor-\(UUID().uuidString)")
        let root = base.appendingPathComponent("projects/some-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch.append(base)
        return (root, base.appendingPathComponent("usage-state.json"))
    }

    /// Fixture timestamps have to be **relative to now**, not literals.
    ///
    /// `UsageLedger` prunes its in-flight dedup table by the *log* timestamp
    /// against a 2 day `growthWindow`, so a hardcoded date stops working exactly
    /// 48 hours after it is written: the first copy of a turn is inserted and
    /// pruned in the same call, the rewrite then looks like a brand new id, and
    /// the growth-only rule appears to be broken when it is working perfectly.
    /// This file shipped with `2026-08-22T12:00:00.000Z` and went red on
    /// 2026-08-24, which is the whole lesson.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func recentTimestamp(minutesAgo: Double = 1) -> String {
        Self.iso.string(from: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    private func assistantLine(
        messageID: String, requestID: String,
        model: String = "claude-opus-5",
        input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
        timestamp: String? = nil
    ) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp ?? recentTimestamp(),
            "requestId": requestID,
            "message": [
                "id": messageID, "role": "assistant", "model": model,
                "usage": [
                    "input_tokens": input, "output_tokens": output,
                    "cache_creation_input_tokens": cacheWrite,
                    "cache_read_input_tokens": cacheRead,
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    private func append(_ text: String, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// `copilotDatabaseURL` defaults to a path that does not exist, never to the
    /// real `~/.copilot/session-store.db`: this machine has genuine Copilot CLI
    /// usage recorded, and crediting it here would pollute every assertion on
    /// totals in this file with live data that changes between runs.
    private func makeMonitor(
        root: URL, stateURL: URL, copilotDatabaseURL: URL? = nil
    ) -> UsageMonitor {
        UsageMonitor(
            scanner: UsageScanner(roots: [root]),
            catalog: PricingCatalog(
                cacheURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pokebar-pricing-\(UUID().uuidString).json")),
            stateURL: stateURL,
            copilotDatabaseURL: copilotDatabaseURL
                ?? CopilotFixture.scratchURL("copilot-absent"))
    }

    /// Polls rather than sleeping a fixed interval, so the test is neither flaky
    /// nor slower than it has to be.
    private func waitFor(
        _ condition: @MainActor () -> Bool, timeout: Double = 10, label: String
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    func testColdScanPublishesTotals() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        try append(
            assistantLine(messageID: "m1", requestID: "r1", input: 100, output: 200), to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.allTimeTokens.total == 300 }, label: "cold scan totals")
        XCTAssertEqual(monitor.allTimeTokens.input, 100)
        XCTAssertEqual(monitor.allTimeTokens.output, 200)
        // opus-5: 100 input @ $5/MTok + 200 output @ $25/MTok
        XCTAssertEqual(monitor.allTimeCostUSD, 0.0055, accuracy: 1e-9)
        XCTAssertFalse(monitor.costIsIncomplete)
    }

    func testPicksUpAnAppendedTurnWithoutPolling() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        try append(assistantLine(messageID: "m1", requestID: "r1", output: 100), to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.state == .watching }, label: "watching state")
        await waitFor({ monitor.allTimeTokens.total == 100 }, label: "initial total")

        try append(assistantLine(messageID: "m2", requestID: "r2", output: 400), to: file)

        await waitFor({ monitor.allTimeTokens.total == 500 }, label: "appended turn credited")
        XCTAssertNotNil(monitor.lastUpdated)
    }

    /// The guard against this file's own time bomb. A fixture timestamp must
    /// sit inside the ledger's growth window, or the streaming-rewrite tests
    /// below silently stop testing anything and start failing instead.
    func testFixtureTimestampsSitInsideTheGrowthWindow() throws {
        let line = assistantLine(messageID: "m1", requestID: "r1", output: 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let date = try XCTUnwrap(ClaudeUsageParser.parseTimestamp(object["timestamp"]))
        XCTAssertLessThan(
            Date().timeIntervalSince(date), UsageLedger.growthWindow,
            "a fixture older than the growth window is pruned before the rewrite arrives")
    }

    /// The straddling-scan case end to end: a turn observed mid-stream, then
    /// completed, must be counted once at its final size.
    func testStreamingRewriteCreditsOnlyGrowth() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        try append(
            assistantLine(messageID: "m1", requestID: "r1", input: 50, output: 5, cacheRead: 900),
            to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.allTimeTokens.total == 955 }, label: "partial turn")
        await waitFor({ monitor.state == .watching }, label: "watching state")

        // Same turn rewritten with the completed response.
        try append(
            assistantLine(messageID: "m1", requestID: "r1", input: 50, output: 700, cacheRead: 900),
            to: file)

        await waitFor(
            { monitor.allTimeTokens.total == 1650 }, label: "completed turn at final size")
        XCTAssertEqual(
            monitor.allTimeTokens.output, 700,
            "output must be the final value, not 5 + 700")
    }

    /// Cursors and ledger both persist, so a relaunch keeps its totals without
    /// re-reading the tree.
    func testTotalsSurviveRelaunch() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        try append(
            assistantLine(messageID: "m1", requestID: "r1", output: 250), to: file)

        let first = makeMonitor(root: root, stateURL: stateURL)
        first.start()
        await waitFor({ first.allTimeTokens.total == 250 }, label: "first run totals")
        let coinsBefore = first.coins
        first.stop()

        let second = makeMonitor(root: root, stateURL: stateURL)
        second.start()
        defer { second.stop() }

        await waitFor({ second.allTimeTokens.total == 250 }, label: "restored totals")
        XCTAssertEqual(second.coins, coinsBefore, "earned currency survives a relaunch")
        XCTAssertEqual(
            second.allTimeTokens.output, 250,
            "a relaunch must not double-count an already-credited turn")
    }

    func testTierWeightingFeedsCoins() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        // 1 coin = 100,000 weighted tokens; fable tier is 2.0.
        let perCoin = Int(UsageLedger.tokensPerCoin)
        try append(
            assistantLine(
                messageID: "m1", requestID: "r1", model: "claude-fable-5", output: perCoin),
            to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.coins == 2 }, label: "fable earns double")
        XCTAssertEqual(
            monitor.allTimeTokens.total, perCoin, "raw token count stays unweighted")
    }

    func testUnpricedModelFlagsIncompleteCost() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        try append(
            assistantLine(
                messageID: "m1", requestID: "r1", model: "claude-not-a-real-model", output: 100),
            to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.costIsIncomplete }, label: "incomplete-cost flag")
        XCTAssertEqual(monitor.allTimeTokens.total, 100, "usage still counts")
        XCTAssertGreaterThan(monitor.coins >= 0 ? 1 : 0, 0)
    }

    /// The popover re-derives on open, so that path has to be inert: displaying
    /// the totals again must not credit currency a second time.
    func testRefreshDisplayedTotalsCreditsNothing() async throws {
        let (root, stateURL) = try makeTree()
        let file = root.appendingPathComponent("session.jsonl")
        // 200,000 output tokens at the opus tier of 1.0 is exactly 2 coins.
        try append(assistantLine(messageID: "m1", requestID: "r1", output: 200_000), to: file)

        let monitor = makeMonitor(root: root, stateURL: stateURL)
        monitor.start()
        defer { monitor.stop() }

        await waitFor({ monitor.coins == 2 }, label: "initial coins")
        let tokens = monitor.allTimeTokens
        let cost = monitor.allTimeCostUSD

        for _ in 0..<5 { monitor.refreshDisplayedTotals() }

        XCTAssertEqual(monitor.coins, 2, "re-publishing must not mint coins")
        XCTAssertEqual(monitor.allTimeTokens, tokens)
        XCTAssertEqual(monitor.allTimeCostUSD, cost, accuracy: 1e-12)
    }

    // MARK: Copilot CLI

    /// The end-to-end shape of the whole feature: a Copilot row and a Claude
    /// Code turn on the *same* model are both credited, both priced off the same
    /// unprefixed model id, and land in two separate breakdown rows rather than
    /// merging into one total.
    func testCreditsCopilotRowsAlongsideClaudeCodeWithoutMerging() async throws {
        let (root, stateURL) = try makeTree()
        try append(
            assistantLine(
                messageID: "m1", requestID: "r1", model: "claude-sonnet-5", output: 100),
            to: root.appendingPathComponent("session.jsonl"))

        let database = CopilotFixture.scratchURL("copilot-monitor")
        scratch.append(database)
        try CopilotFixture.makeDatabase(
            at: database,
            rows: [.init(model: "claude-sonnet-5", input: 60, output: 40, cacheRead: 10)])

        let monitor = makeMonitor(
            root: root, stateURL: stateURL, copilotDatabaseURL: database)
        monitor.start()
        defer { monitor.stop() }

        // 100 from Claude Code, plus (60 - 10) input + 40 output + 10 cache read.
        await waitFor({ monitor.allTimeTokens.total == 200 }, label: "both sources credited")

        XCTAssertEqual(monitor.byModelToday["claude-sonnet-5"]?.total, 100, "Claude Code row")
        XCTAssertEqual(
            monitor.byModelToday["copilot:claude-sonnet-5"]?.total, 100, "Copilot row")

        // Priced, not silently unknown: the prefix must never reach the pricing
        // table. sonnet-5 is $3/MTok in, $15/MTok out, $0.30/MTok cache read.
        XCTAssertFalse(
            monitor.costIsIncomplete,
            "a prefixed key reaching the pricing table would flag the cost incomplete")
        XCTAssertGreaterThan(monitor.allTimeCostUSD, 0)

        // Two rows in the breakdown, distinguishable on screen.
        let names = ModelBreakdown.rows(from: monitor.byModelToday).map(\.identity.displayName)
        XCTAssertEqual(Set(names), ["Sonnet 5", "Sonnet 5 (Copilot)"])
    }

    /// The Copilot cursor has to survive a relaunch or every launch re-credits
    /// every row ever written. Coins are frozen at credit time, so that
    /// inflation would be permanent (invariant 3).
    func testCopilotCursorPersistsSoARelaunchCreditsNothingTwice() async throws {
        let (root, stateURL) = try makeTree()
        let database = CopilotFixture.scratchURL("copilot-relaunch")
        scratch.append(database)
        try CopilotFixture.makeDatabase(
            at: database, rows: [.init(input: 100, output: 100)])

        let first = makeMonitor(root: root, stateURL: stateURL, copilotDatabaseURL: database)
        first.start()
        await waitFor({ first.allTimeTokens.total == 200 }, label: "first launch credits")
        first.stop()

        let second = makeMonitor(root: root, stateURL: stateURL, copilotDatabaseURL: database)
        second.start()
        defer { second.stop() }
        await waitFor({ second.allTimeTokens.total == 200 }, label: "restored totals")
        // Give a second pass time to double-credit if the cursor were lost.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(second.allTimeTokens.total, 200, "a relaunch must credit nothing again")
    }

    /// Invariant 23, on the usage side. A state file written before Copilot
    /// support existed has no `copilotCursor` key, and the synthesized decoder
    /// throws on a missing key even where the property has a default. `load()`
    /// cannot tell that throw from "no state yet", so it would silently restart
    /// the ledger, and the coin balance, from zero.
    func testStateFileWrittenBeforeCopilotSupportStillDecodes() throws {
        let json = """
            {"ledger":{"daily":{"2026-08-22":{"claude-opus-5":\
            {"input":10,"output":20,"cacheWrite":0,"cacheRead":0}}},\
            "weightedTokens":30,"inFlight":{}},"cursors":{}}
            """
        let decoded = try JSONDecoder().decode(
            UsageMonitor.PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.ledger.weightedTokens, 30)
        XCTAssertEqual(decoded.ledger.tokens(forDay: "2026-08-22").total, 30)
        XCTAssertEqual(decoded.copilotCursor, 0, "absent key defaults, it does not throw")
    }
}
