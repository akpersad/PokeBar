import XCTest

@testable import PokeBar

/// Builds an assistant line in the exact shape Claude Code writes.
private func makeLine(
    messageID: String? = "msg_1",
    requestID: String? = "req_1",
    model: String = "claude-opus-5",
    input: Int = 0,
    output: Int = 0,
    cacheWrite: Int = 0,
    cacheRead: Int = 0,
    timestamp: String = "2026-08-22T14:20:59.123Z",
    type: String = "assistant"
) -> String {
    var message: [String: Any] = [
        "role": "assistant",
        "model": model,
        "usage": [
            "input_tokens": input,
            "output_tokens": output,
            "cache_creation_input_tokens": cacheWrite,
            "cache_read_input_tokens": cacheRead,
        ],
    ]
    if let messageID { message["id"] = messageID }
    var object: [String: Any] = ["type": type, "timestamp": timestamp, "message": message]
    if let requestID { object["requestId"] = requestID }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

final class ClaudeUsageParserTests: XCTestCase {

    func testParsesAllFourTokenClasses() throws {
        let entry = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(input: 11, output: 22, cacheWrite: 33, cacheRead: 44),
            fallbackID: "unused"))
        XCTAssertEqual(entry.tokens, TokenCounts(input: 11, output: 22, cacheWrite: 33, cacheRead: 44))
        XCTAssertEqual(entry.tokens.total, 110)
        XCTAssertEqual(entry.model, "claude-opus-5")
        XCTAssertEqual(entry.id, "msg_1|req_1")
    }

    func testIgnoresNonAssistantLineTypes() {
        for kind in ["user", "attachment", "mode", "file-history-snapshot", "queue-operation"] {
            XCTAssertNil(
                ClaudeUsageParser.entry(fromLine: makeLine(output: 5, type: kind), fallbackID: "x"),
                "line type \(kind) must not produce usage")
        }
    }

    func testSkipsSyntheticPlaceholderTurns() {
        XCTAssertNil(ClaudeUsageParser.entry(
            fromLine: makeLine(model: "<synthetic>", output: 5), fallbackID: "x"))
    }

    func testSkipsTurnsWithNoTokens() {
        XCTAssertNil(ClaudeUsageParser.entry(fromLine: makeLine(), fallbackID: "x"))
    }

    /// Upstream produced the key `"|"` whenever both identifiers were absent,
    /// which collapses every such line in the corpus into a single entry.
    func testFallbackIDKeepsIDLessLinesDistinct() throws {
        let a = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(messageID: nil, requestID: nil, output: 1), fallbackID: "file#1"))
        let b = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(messageID: nil, requestID: nil, output: 1), fallbackID: "file#2"))
        XCTAssertEqual(a.id, "file#1")
        XCTAssertEqual(b.id, "file#2")
        XCTAssertEqual(ClaudeUsageParser.dedupKeepMax([a, b]).count, 2)
    }

    /// The load-bearing rule. Streaming logs the same turn repeatedly and
    /// `output` grows as the response completes, so first-wins under-counts.
    func testDedupKeepsLargestTotalRegardlessOfOrder() throws {
        let partial = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(input: 100, output: 5, cacheRead: 900), fallbackID: "x"))
        let complete = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(input: 100, output: 700, cacheRead: 900), fallbackID: "x"))

        for ordering in [[partial, complete], [complete, partial]] {
            let deduped = ClaudeUsageParser.dedupKeepMax(ordering)
            XCTAssertEqual(deduped.count, 1)
            XCTAssertEqual(deduped[0].tokens.output, 700, "keeping the first copy would report 5")
        }
    }

    func testDistinctTurnsAreNotCollapsed() throws {
        let one = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(messageID: "a", requestID: "r1", output: 10), fallbackID: "x"))
        let two = try XCTUnwrap(ClaudeUsageParser.entry(
            fromLine: makeLine(messageID: "b", requestID: "r2", output: 10), fallbackID: "y"))
        XCTAssertEqual(ClaudeUsageParser.dedupKeepMax([one, two]).count, 2)
    }

    func testTimestampFormats() {
        XCTAssertNotNil(ClaudeUsageParser.parseTimestamp("2026-08-22T14:20:59.123Z"))
        XCTAssertNotNil(ClaudeUsageParser.parseTimestamp("2026-08-22T14:20:59Z"))
        XCTAssertNil(ClaudeUsageParser.parseTimestamp("not a date"))
        XCTAssertNil(ClaudeUsageParser.parseTimestamp(nil))
    }

    func testLocalDayKeyIsZeroPadded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = try XCTUnwrap(ClaudeUsageParser.parseTimestamp("2026-01-05T00:00:00.000Z"))
        XCTAssertEqual(ClaudeUsageParser.localDayKey(date, calendar: calendar), "2026-01-05")
    }

    func testTokenCountsAddition() {
        let a = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        var b = a
        b += a
        XCTAssertEqual(b, TokenCounts(input: 2, output: 4, cacheWrite: 6, cacheRead: 8))
        XCTAssertEqual(TokenCounts.zero.total, 0)
    }
}
