import XCTest

@testable import PokeBar

final class UsageScannerTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch.append(root)
        return root
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func context(_ model: String = "gpt-5.6-sol") -> String {
        jsonLine([
            "timestamp": "2026-08-24T03:25:39.655Z",
            "type": "turn_context",
            "payload": ["model": model],
        ])
    }

    private func usage(
        timestamp: String, input: Int, cached: Int, write: Int, output: Int, ordinal: Int = 15
    ) -> String {
        jsonLine([
            "timestamp": timestamp,
            "ordinal": ordinal,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "cache_write_input_tokens": write,
                        "output_tokens": output,
                    ],
                ],
            ],
        ])
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

    func testScansCodexResponsesAndPreservesModelAcrossPasses() throws {
        let root = try tempRoot()
        let file = root.appendingPathComponent("rollout.jsonl")
        let scanner = UsageScanner(roots: [root])

        try append(context(), to: file)
        let contextPass = scanner.scan()
        XCTAssertTrue(contextPass.entries.isEmpty)
        XCTAssertEqual(contextPass.cursors.values.only?.codexModel, "gpt-5.6-sol")

        try append(
            usage(
                timestamp: "2026-08-24T03:25:51.810Z",
                input: 20_699, cached: 16_717, write: 3_979, output: 221),
            to: file)
        let usagePass = scanner.scan(cursors: contextPass.cursors)
        let entry = try XCTUnwrap(usagePass.entries.only)
        XCTAssertEqual(entry.model, "gpt-5.6-sol")
        XCTAssertEqual(entry.tokens, TokenCounts(
            input: 3, output: 221, cacheWrite: 3_979, cacheRead: 16_717))
    }

    func testIncrementalScanCreditsEachCodexResponseOnce() throws {
        let root = try tempRoot()
        let file = root.appendingPathComponent("rollout.jsonl")
        let scanner = UsageScanner(roots: [root])
        try append(
            context()
                + usage(
                    timestamp: "2026-08-24T03:25:51.810Z",
                    input: 100, cached: 80, write: 10, output: 5),
            to: file)

        let first = scanner.scan()
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertTrue(scanner.scan(cursors: first.cursors).entries.isEmpty)

        try append(
            usage(
                timestamp: "2026-08-24T03:26:02.486Z",
                input: 120, cached: 100, write: 15, output: 7, ordinal: 21),
            to: file)
        let second = scanner.scan(cursors: first.cursors)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertNotEqual(first.entries[0].id, second.entries[0].id)
    }

    /// Invariant 2 lives on the ledger, but it can only work if the same event
    /// keeps the same id. A file read incrementally and then re-read from zero
    /// (inode change, truncation, a cursor dropped by a transient stat failure)
    /// must produce byte-identical ids, or every Codex event is credited twice
    /// and the frozen coins can never be walked back.
    func testCodexIDsSurviveAFullReReadFromZero() throws {
        let root = try tempRoot()
        let file = root.appendingPathComponent("rollout-2026-08-24T03-25-39-01a031f6.jsonl")
        let scanner = UsageScanner(roots: [root])

        try append(context(), to: file)
        let contextPass = scanner.scan()
        try append(
            usage(
                timestamp: "2026-08-24T03:25:51.810Z",
                input: 100, cached: 80, write: 10, output: 5),
            to: file)

        let incremental = scanner.scan(cursors: contextPass.cursors)
        let fromZero = scanner.scan()

        XCTAssertEqual(incremental.entries.map(\.id), fromZero.entries.map(\.id))
        XCTAssertEqual(incremental.entries.count, 1)
    }

    /// The Codex prefilter matches raw text, so a Claude turn that merely quotes
    /// `token_count` trips it. Falling through to the Claude parser keeps that
    /// turn's usage; branching else-if silently dropped it. Zero lines in the
    /// live Claude corpus match today, which is exactly why this needs a test:
    /// the sessions most likely to produce one are the ones spent on this code.
    func testClaudeUsageSurvivesALineThatQuotesTheCodexMarkers() throws {
        let root = try tempRoot()
        let file = root.appendingPathComponent("claude.jsonl")
        try append(
            jsonLine([
                "timestamp": "2026-08-24T03:25:51.810Z",
                "type": "assistant",
                "requestId": "req_quotes_the_marker",
                "message": [
                    "id": "msg_quotes_the_marker",
                    "model": "claude-opus-5",
                    "content": #"the rollout writes a "token_count" after each "turn_context""#,
                    "usage": [
                        "input_tokens": 11, "output_tokens": 22,
                        "cache_creation_input_tokens": 33, "cache_read_input_tokens": 44,
                    ],
                ],
            ]),
            to: file)

        let entry = try XCTUnwrap(UsageScanner(roots: [root]).scan().entries.only)
        XCTAssertEqual(entry.model, "claude-opus-5")
        XCTAssertEqual(entry.id, "msg_quotes_the_marker|req_quotes_the_marker")
        XCTAssertEqual(entry.tokens.total, 110)
    }

    /// Both corpus parity tests index `defaultRoots()` positionally, so the
    /// order is load-bearing and untested until now.
    func testDefaultRootsCoverBothToolsInOrderAndHonourBothEnvVars() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        let plain = UsageScanner.defaultRoots(environment: [:], home: home)
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(plain[0].path, "/Users/nobody/.claude/projects")
        XCTAssertEqual(plain[1].path, "/Users/nobody/.codex/sessions")

        let relocated = UsageScanner.defaultRoots(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc", "CODEX_HOME": "/tmp/cx"],
            home: home)
        XCTAssertEqual(relocated[0].path, "/tmp/cc/projects")
        XCTAssertEqual(relocated[1].path, "/tmp/cx/sessions")

        // An empty value is not a relocation.
        let empty = UsageScanner.defaultRoots(
            environment: ["CLAUDE_CONFIG_DIR": "", "CODEX_HOME": ""], home: home)
        XCTAssertEqual(empty, plain)
    }

    /// The common state for anyone who has one tool installed and not the other.
    func testAMissingRootIsSkippedRatherThanFailingTheWholeScan() throws {
        let root = try tempRoot()
        let file = root.appendingPathComponent("rollout-2026-08-24T03-25-39-01a031f6.jsonl")
        try append(
            context()
                + usage(
                    timestamp: "2026-08-24T03:25:51.810Z",
                    input: 100, cached: 80, write: 10, output: 5),
            to: file)

        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertEqual(UsageScanner(roots: [missing, root]).scan().entries.count, 1)
        XCTAssertEqual(UsageScanner(roots: [root, missing]).scan().entries.count, 1)
    }

    func testExistingClaudeCursorStateDecodesWithoutCodexModel() throws {
        let data = Data(#"{"inode":42,"size":100,"offset":80}"#.utf8)
        let cursor = try JSONDecoder().decode(FileCursor.self, from: data)
        XCTAssertEqual(cursor.inode, 42)
        XCTAssertEqual(cursor.size, 100)
        XCTAssertEqual(cursor.offset, 80)
        XCTAssertNil(cursor.codexModel)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
