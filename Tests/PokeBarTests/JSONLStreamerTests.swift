import XCTest

@testable import PokeBar

final class JSONLStreamerTests: XCTestCase {

    private var scratch: [URL] = []

    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-test-\(UUID().uuidString).jsonl")
        scratch.append(url)
        return url
    }

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testReadsEveryCompleteLine() throws {
        let url = temp()
        try "a\nb\nc\n".write(to: url, atomically: true, encoding: .utf8)

        var seen: [String] = []
        let end = try JSONLStreamer.read(url) { seen.append($0) }
        XCTAssertEqual(seen, ["a", "b", "c"])
        XCTAssertEqual(end, 6)
    }

    func testResumingFromOffsetYieldsOnlyAppendedLines() throws {
        let url = temp()
        try "first\nsecond\n".write(to: url, atomically: true, encoding: .utf8)

        var first: [String] = []
        let offset = try JSONLStreamer.read(url) { first.append($0) }
        XCTAssertEqual(first, ["first", "second"])

        // Claude Code appending a turn to the live session file.
        try append("third\n", to: url)

        var second: [String] = []
        _ = try JSONLStreamer.read(url, from: offset) { second.append($0) }
        XCTAssertEqual(second, ["third"], "resume must not re-emit consumed lines")
    }

    func testHalfWrittenTrailingLineIsWithheldUntilComplete() throws {
        let url = temp()
        // No trailing newline: the writer is mid-flush.
        try "done\npart".write(to: url, atomically: true, encoding: .utf8)

        var seen: [String] = []
        let offset = try JSONLStreamer.read(url) { seen.append($0) }
        XCTAssertEqual(seen, ["done"], "a truncated line must not be emitted as whole")
        XCTAssertEqual(offset, 5, "offset must exclude the incomplete fragment")

        try append("ial\n", to: url)

        var seen2: [String] = []
        _ = try JSONLStreamer.read(url, from: offset) { seen2.append($0) }
        XCTAssertEqual(seen2, ["partial"], "the completed line must arrive intact next pass")
    }

    func testBlankLinesAreSkippedWithoutBreakingOffsets() throws {
        let url = temp()
        try "a\n\nb\n".write(to: url, atomically: true, encoding: .utf8)

        var seen: [String] = []
        let end = try JSONLStreamer.read(url) { seen.append($0) }
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(end, 5)
    }

    func testLineLongerThanOneChunkSurvivesReassembly() throws {
        let url = temp()
        let long = String(repeating: "x", count: JSONLStreamer.chunkSize * 2 + 17)
        try "short\n\(long)\n".write(to: url, atomically: true, encoding: .utf8)

        var seen: [String] = []
        _ = try JSONLStreamer.read(url) { seen.append($0) }
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.last?.count, long.count)
    }

    func testMissingFileThrows() {
        let url = temp()
        XCTAssertThrowsError(try JSONLStreamer.read(url) { _ in })
    }
}
