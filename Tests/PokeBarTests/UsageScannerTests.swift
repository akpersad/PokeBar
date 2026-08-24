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

    private func usage(timestamp: String, input: Int, cached: Int, write: Int, output: Int) -> String {
        jsonLine([
            "timestamp": timestamp,
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
                input: 120, cached: 100, write: 15, output: 7),
            to: file)
        let second = scanner.scan(cursors: first.cursors)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertNotEqual(first.entries[0].id, second.entries[0].id)
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
