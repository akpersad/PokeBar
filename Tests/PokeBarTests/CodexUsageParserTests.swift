import XCTest

@testable import PokeBar

final class CodexUsageParserTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func context(model: String = "gpt-5.6-sol") -> String {
        line([
            "timestamp": "2026-08-24T03:25:39.655Z",
            "type": "turn_context",
            "payload": ["model": model],
        ])
    }

    private func tokenCount(
        input: Int = 20_699,
        cached: Int = 16_717,
        cacheWrite: Int = 3_979,
        output: Int = 221,
        reasoning: Int = 137
    ) -> String {
        line([
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
        ])
    }

    func testContextSetsModelWithoutProducingUsage() {
        var model: String?
        XCTAssertNil(CodexUsageParser.consume(
            line: context(), fallbackID: "context", currentModel: &model))
        XCTAssertEqual(model, "gpt-5.6-sol")
    }

    func testParsesLastUsageIntoNonOverlappingClasses() throws {
        var model: String? = "gpt-5.6-sol"
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), fallbackID: "codex|file#2", currentModel: &model))

        XCTAssertEqual(entry.id, "codex|file#2")
        XCTAssertEqual(entry.model, "gpt-5.6-sol")
        XCTAssertEqual(entry.tokens, TokenCounts(
            input: 3, output: 221, cacheWrite: 3_979, cacheRead: 16_717))
        XCTAssertEqual(entry.tokens.total, 20_920)
    }

    func testReasoningIsNotAddedOnTopOfOutput() throws {
        var model: String? = "gpt-5.6-sol"
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(input: 10, cached: 0, cacheWrite: 0, output: 100, reasoning: 80),
            fallbackID: "x",
            currentModel: &model))
        XCTAssertEqual(entry.tokens.output, 100)
        XCTAssertEqual(entry.tokens.total, 110, "reasoning is a subset of output")
    }

    func testUsesLastUsageRatherThanCumulativeTotal() throws {
        var model: String? = "gpt-5.6-sol"
        let entry = try XCTUnwrap(CodexUsageParser.consume(
            line: tokenCount(), fallbackID: "x", currentModel: &model))
        XCTAssertEqual(entry.tokens.total, 20_920)
        XCTAssertNotEqual(entry.tokens.total, 53_315)
    }

    func testIgnoresUnrelatedAndZeroUsageEvents() {
        var model: String?
        XCTAssertNil(CodexUsageParser.consume(
            line: line(["type": "event_msg", "payload": ["type": "item_completed"]]),
            fallbackID: "x",
            currentModel: &model))
        XCTAssertNil(CodexUsageParser.consume(
            line: tokenCount(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0),
            fallbackID: "x",
            currentModel: &model))
    }
}
