import XCTest

@testable import PokeBar

final class CodexUsageParserTests: XCTestCase {

    /// Stands in for the rollout file name, which carries the session UUID.
    private let session = "rollout-2026-08-24T03-25-39-01a031f6.jsonl"

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func context(model: String = "gpt-5.6-sol") -> String {
        line([
            "timestamp": "2026-08-24T03:25:39.655Z",
            "ordinal": 12,
            "type": "turn_context",
            "payload": ["model": model],
        ])
    }

    private func tokenCount(
        input: Int = 20_699,
        cached: Int = 16_717,
        cacheWrite: Int = 3_979,
        output: Int = 221,
        reasoning: Int = 137,
        ordinal: Int? = 27
    ) -> String {
        var object: [String: Any] = [
            "timestamp": "2026-08-24T03:25:51.810Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 52_899, "cached_input_tokens": 32_194,
                        "cache_write_input_tokens": 20_696, "output_tokens": 416,
                        "reasoning_output_tokens": 149, "total_tokens": 53_315,
                    ],
                    "last_token_usage": [
                        "input_tokens": input, "cached_input_tokens": cached,
                        "cache_write_input_tokens": cacheWrite, "output_tokens": output,
                        "reasoning_output_tokens": reasoning,
                        "total_tokens": input + output,
                    ],
                ],
            ],
        ]
        if let ordinal { object["ordinal"] = ordinal }
        return line(object)
    }

    func testContextSetsModelWithoutProducingUsage() {
        var model: String?
        var project: String?
        XCTAssertNil(CodexUsageParser.consume(
            line: context(), sessionKey: session, fallbackID: "context", currentModel: &model, currentProject: &project))
        XCTAssertEqual(model, "gpt-5.6-sol")
    }

    func testParsesLastUsageIntoNonOverlappingClasses() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session, fallbackID: "codex|file#2", currentModel: &model, currentProject: &project))

        XCTAssertEqual(entry.id, "codex|\(session)#27")
        XCTAssertEqual(entry.model, "gpt-5.6-sol")
        XCTAssertEqual(entry.tokens, TokenCounts(
            input: 3, output: 221, cacheWrite: 3_979, cacheRead: 16_717))
        XCTAssertEqual(entry.tokens.total, 20_920)
    }

    func testReasoningIsNotAddedOnTopOfOutput() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(input: 10, cached: 0, cacheWrite: 0, output: 100, reasoning: 80),
            sessionKey: session,
            fallbackID: "x",
            currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.tokens.output, 100)
        XCTAssertEqual(entry.tokens.total, 110, "reasoning is a subset of output")
    }

    func testUsesLastUsageRatherThanCumulativeTotal() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.tokens.total, 20_920)
        XCTAssertNotEqual(entry.tokens.total, 53_315)
    }

    /// The double-credit guard. The id must be a function of the record, not of
    /// where the scan started, or a file re-read from zero after an incremental
    /// pass re-credits every event under a fresh id. Coins are frozen at credit
    /// time, so that inflation could never be undone.
    func testIDIgnoresTheScanOffsetAndFollowsTheRecord() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let incremental = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session,
            fallbackID: "codex|/tmp/a.jsonl#8192+3", currentModel: &model, currentProject: &project))
        let fromZero = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session,
            fallbackID: "codex|/tmp/a.jsonl#0+41", currentModel: &model, currentProject: &project))

        XCTAssertEqual(incremental.id, fromZero.id)
        XCTAssertEqual(incremental.id, "codex|\(session)#27")
    }

    /// Two events in one session are two credits, not one.
    func testDistinctOrdinalsAreDistinctEntries() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let first = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(ordinal: 27), sessionKey: session,
            fallbackID: "x", currentModel: &model, currentProject: &project))
        let second = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(ordinal: 33), sessionKey: session,
            fallbackID: "y", currentModel: &model, currentProject: &project))
        XCTAssertNotEqual(first.id, second.id)
    }

    /// A future Codex build that stops writing `ordinal` must still be counted,
    /// even though the positional id it falls back to is weaker.
    func testFallsBackToThePositionalIDWhenOrdinalIsAbsent() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(ordinal: nil), sessionKey: session,
            fallbackID: "codex|/tmp/a.jsonl#0+41", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.id, "codex|/tmp/a.jsonl#0+41")
    }

    /// Every rollout on this machine opens its `turn_context` before its first
    /// `token_count`, so this is the shape of a scan that began mid-file with a
    /// cursor that lost its carried model. The tokens are still counted: losing
    /// the attribution must not lose the usage.
    ///
    /// Note the asymmetry it leaves behind. `unknown-codex-model` is absent from
    /// the rate table, so it earns at `unknownModelTierMultiplier` (1.0) rather
    /// than Sol's 0.8. An unattributed Codex turn is worth slightly *more* than
    /// an attributed one. That is the deliberate "a new model must not silently
    /// earn nothing" policy showing through, and it is pinned here so a change
    /// to it is a visible one.
    func testUsageWithNoPrecedingContextIsCountedUnderAnUnknownModel() throws {
        var model: String?
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.model, "unknown-codex-model")
        XCTAssertEqual(entry.tokens.total, 20_920)
        XCTAssertNil(ModelPricing().rate(for: entry.model))
        XCTAssertNil(ModelPricing().tierMultiplier(for: entry.model))
    }

    func testModelSwitchMidSessionIsPickedUp() throws {
        var model: String?
        var project: String?
        _ = CodexUsageParser.consume(
            line: context(), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project)
        _ = CodexUsageParser.consume(
            line: context(model: "gpt-5.6-luna"), sessionKey: session,
            fallbackID: "x", currentModel: &model, currentProject: &project)
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.model, "gpt-5.6-luna")
    }

    /// An empty model on a `turn_context` must not erase what we already knew.
    func testEmptyContextModelDoesNotClobberTheCurrentModel() {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        _ = CodexUsageParser.consume(
            line: context(model: ""), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project)
        XCTAssertEqual(model, "gpt-5.6-sol")
    }

    /// The four classes must re-sum to the event's own `total_tokens`, which the
    /// parser never reads. Holds for all 110 events in the live corpus.
    func testClassesReSumToTheEventsOwnTotal() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.tokens.total, 20_699 + 221, "input_tokens + output_tokens")
    }

    func testMalformedLinesAreIgnoredRatherThanCrashing() {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let bad = [
            "not json at all",
            #"{"type":"event_msg"}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
            // No timestamp: an entry with no date cannot be day-bucketed.
            #"{"type":"event_msg","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}"#,
        ]
        for line in bad {
            XCTAssertNil(
                CodexUsageParser.consume(
                    line: line, sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project),
                line)
        }
        XCTAssertEqual(model, "gpt-5.6-sol", "a bad line must not disturb the carried model")
    }

    /// Cached plus written can only exceed the reported input if Codex changes
    /// shape. Clamp rather than emit a negative class.
    func testOverlappingCacheClassesClampRatherThanGoNegative() throws {
        var model: String? = "gpt-5.6-sol"
        var project: String?
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(input: 100, cached: 90, cacheWrite: 50, output: 5),
            sessionKey: session, fallbackID: "x", currentModel: &model, currentProject: &project))
        XCTAssertEqual(entry.tokens.input, 0)
    }

    func testIgnoresUnrelatedAndZeroUsageEvents() {
        var model: String?
        var project: String?
        XCTAssertNil(CodexUsageParser.consume(
            line: line(["type": "event_msg", "payload": ["type": "item_completed"]]),
            sessionKey: session,
            fallbackID: "x",
            currentModel: &model, currentProject: &project))
        XCTAssertNil(CodexUsageParser.consume(
            line: tokenCount(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0),
            sessionKey: session,
            fallbackID: "x",
            currentModel: &model, currentProject: &project))
    }
}
