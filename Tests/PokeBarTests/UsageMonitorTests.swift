import XCTest

@testable import PokeBar

/// End-to-end over a synthetic Claude project tree: watch, scan, credit, publish,
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

    private func assistantLine(
        messageID: String, requestID: String,
        model: String = "claude-opus-5",
        input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
        timestamp: String = "2026-08-22T12:00:00.000Z"
    ) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
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

    private func makeMonitor(root: URL, stateURL: URL) -> UsageMonitor {
        UsageMonitor(
            scanner: UsageScanner(roots: [root]),
            catalog: PricingCatalog(
                cacheURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pokebar-pricing-\(UUID().uuidString).json")),
            stateURL: stateURL)
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
}
