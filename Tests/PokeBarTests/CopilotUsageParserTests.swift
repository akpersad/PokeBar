import XCTest

@testable import PokeBar

/// Exercises `CopilotUsageParser` against a real SQLite fixture built to the
/// schema observed in `~/.copilot/session-store.db` on a live machine.
final class CopilotUsageParserTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    private func makeDatabase(
        _ rows: [CopilotFixture.Row], reasoningTokens: Int = 0
    ) throws -> URL {
        let url = CopilotFixture.scratchURL("copilot-fixture")
        scratch.append(url)
        return try CopilotFixture.makeDatabase(
            at: url, rows: rows, reasoningTokens: reasoningTokens)
    }

    func testMissingDatabaseReturnsNothingRatherThanFailing() {
        let result = CopilotUsageParser.scan(
            databaseURL: CopilotFixture.scratchURL("copilot-missing"), cursor: 0)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.cursor, 0)
    }

    func testReadsRowsPastTheCursorAndComputesNonOverlappingInput() throws {
        let url = try makeDatabase([
            .init(model: "claude-sonnet-5", input: 44036, output: 410,
                  cacheRead: 40979, cacheWrite: 3055),
        ])

        let result = CopilotUsageParser.scan(databaseURL: url, cursor: 0)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.cursor, 1)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.model, "claude-sonnet-5")
        XCTAssertEqual(entry.source, .copilotCLI)
        XCTAssertEqual(entry.id, "copilot|1")
        XCTAssertEqual(entry.tokens.output, 410)
        XCTAssertEqual(entry.tokens.cacheRead, 40979)
        XCTAssertEqual(entry.tokens.cacheWrite, 3055)
        // 44036 - 40979 - 3055 = 2, the handful of tokens outside both cache
        // classes. This is the real row 8 from this machine's live database.
        XCTAssertEqual(entry.tokens.input, 2)
        XCTAssertEqual(entry.tokens.total, 44_446)
    }

    /// The model id is passed through exactly as the source wrote it, because
    /// pricing lookup is exact-key (invariant 4) and the ids Copilot writes are
    /// the same strings the bundled table already holds. The `"copilot:"` marker
    /// belongs to the *ledger key*, not to `entry.model`, and putting it here
    /// would silently price every Copilot row at the unknown-model fallback.
    func testModelIsTheExactPricingKeyWithNoSourceMarker() throws {
        let url = try makeDatabase([
            .init(model: "gpt-5.6-luna", input: 200, output: 20),
        ])
        let entry = try XCTUnwrap(
            CopilotUsageParser.scan(databaseURL: url, cursor: 0).entries.first)
        XCTAssertEqual(entry.model, "gpt-5.6-luna")
        XCTAssertNotNil(
            ModelPricing().rate(for: entry.model),
            "a model Copilot CLI actually reports must resolve in the bundled table")
    }

    /// `reasoning_tokens` is a subset of `output_tokens`, not a fifth class.
    /// Adding it in would double-count thinking tokens and mint coins for them
    /// twice, and coins are frozen at credit time so that cannot be undone.
    func testReasoningTokensAreNotCountedASecondTime() throws {
        let url = try makeDatabase(
            [.init(input: 100, output: 40)], reasoningTokens: 30)
        let entry = try XCTUnwrap(
            CopilotUsageParser.scan(databaseURL: url, cursor: 0).entries.first)
        XCTAssertEqual(entry.tokens.output, 40, "output, not output plus reasoning")
        XCTAssertEqual(entry.tokens.total, 140)
    }

    /// The cursor is the row `id`, not a byte offset or a count: a rescan from
    /// the same cursor must return nothing, so a row can never be credited
    /// twice. Copilot rows are immutable once written, which is what makes a
    /// plain high-water mark sufficient where Claude Code needs keep-max dedup.
    func testCursorSkipsAlreadySeenRowsOnRescan() throws {
        let url = try makeDatabase([
            .init(model: "claude-sonnet-5", input: 100, output: 10,
                  createdAt: CopilotFixture.recentTimestamp(minutesAgo: 2)),
            .init(model: "gpt-5.6-luna", input: 200, output: 20,
                  createdAt: CopilotFixture.recentTimestamp(minutesAgo: 1)),
        ])

        let first = CopilotUsageParser.scan(databaseURL: url, cursor: 0)
        XCTAssertEqual(first.entries.map(\.model), ["claude-sonnet-5", "gpt-5.6-luna"])
        XCTAssertEqual(first.entries.map(\.id), ["copilot|1", "copilot|2"])
        XCTAssertEqual(first.cursor, 2)

        let second = CopilotUsageParser.scan(databaseURL: url, cursor: first.cursor)
        XCTAssertTrue(second.entries.isEmpty, "nothing new past the cursor")
        XCTAssertEqual(second.cursor, 2)

        // Only the tail, when the cursor sits between the two rows.
        let partial = CopilotUsageParser.scan(databaseURL: url, cursor: 1)
        XCTAssertEqual(partial.entries.map(\.id), ["copilot|2"])
    }

    /// A row with no tokens in any class is not usage, the same rule the Claude
    /// Code and Codex parsers apply. It still moves the cursor: a skipped row
    /// that held the cursor back would re-offer itself forever.
    func testZeroTokenRowIsSkippedButStillAdvancesTheCursor() throws {
        let url = try makeDatabase([.init(input: 0, output: 0)])
        let result = CopilotUsageParser.scan(databaseURL: url, cursor: 0)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.cursor, 1, "the row was seen, so it must never be re-read")
    }

    /// An unparseable timestamp costs its own row and nothing else. The cursor
    /// must clear it, or every later row is stuck behind it for good.
    func testUnparseableTimestampIsSkippedWithoutWedgingTheCursor() throws {
        let url = try makeDatabase([
            .init(input: 100, output: 10, createdAt: "not-a-date"),
            .init(model: "gpt-5.6-luna", input: 200, output: 20),
        ])
        let result = CopilotUsageParser.scan(databaseURL: url, cursor: 0)
        XCTAssertEqual(result.entries.map(\.id), ["copilot|2"])
        XCTAssertEqual(result.cursor, 2, "the bad row is behind the cursor, not blocking it")
    }

    /// `created_at` is ISO with a Z on every row the CLI writes, but the column's
    /// own schema default is `datetime('now')`, which is UTC with a space and no
    /// zone marker. Parsing both means the default firing costs a timestamp
    /// offset rather than a permanently skipped row.
    func testTimestampAcceptsBothTheCLIFormatAndTheSchemaDefault() throws {
        let iso = try XCTUnwrap(CopilotUsageParser.timestamp("2026-08-24T15:08:10.375Z"))
        let sqliteDefault = try XCTUnwrap(CopilotUsageParser.timestamp("2026-08-24 15:08:10"))
        XCTAssertEqual(
            iso.timeIntervalSince(sqliteDefault), 0.375, accuracy: 1e-6,
            "both must resolve to the same instant in UTC, not shift by the local offset")

        XCTAssertNil(CopilotUsageParser.timestamp(""))
        XCTAssertNil(CopilotUsageParser.timestamp("not-a-date"))
    }
}
