import XCTest

@testable import PokeBar

final class DirectoryWatcherTests: XCTestCase {

    private var scratch: [URL] = []

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    /// Races the stream against a sleep so a missed event fails the test instead
    /// of hanging it.
    private func awaitTick(
        _ stream: AsyncStream<Void>, within seconds: Double
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func testEmitsTickWhenAFileIsCreated() async throws {
        let dir = try tempDir()
        let stream = DirectoryWatcher.changes(in: [dir], latency: 0.1)

        // FSEvents needs a moment to arm before writes register.
        try await Task.sleep(nanoseconds: 400_000_000)
        try "line\n".write(
            to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let ticked = await awaitTick(stream, within: 5)
        XCTAssertTrue(ticked, "a file creation under a watched root must produce a tick")
    }

    func testEmitsTickWhenAnExistingFileIsAppendedTo() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("session.jsonl")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)

        let stream = DirectoryWatcher.changes(in: [dir], latency: 0.1)
        try await Task.sleep(nanoseconds: 400_000_000)

        // The real signal: Claude Code appending a turn to a live session file.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()

        let ticked = await awaitTick(stream, within: 5)
        XCTAssertTrue(ticked, "an append to an existing file must produce a tick")
    }

    func testEmitsTickForChangesInNestedSubdirectories() async throws {
        let dir = try tempDir()
        // Mirrors the real shape: ~/.claude/projects/<encoded-path>/<uuid>.jsonl
        let nested = dir.appendingPathComponent("project-a/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let stream = DirectoryWatcher.changes(in: [dir], latency: 0.1)
        try await Task.sleep(nanoseconds: 400_000_000)
        try "x\n".write(
            to: nested.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let ticked = await awaitTick(stream, within: 5)
        XCTAssertTrue(ticked, "watching must be recursive")
    }

    /// The whole point of dropping the timer: silence costs nothing.
    func testStaysSilentWhenNothingChanges() async throws {
        let dir = try tempDir()
        let stream = DirectoryWatcher.changes(in: [dir], latency: 0.1)
        try await Task.sleep(nanoseconds: 400_000_000)

        let ticked = await awaitTick(stream, within: 1.5)
        XCTAssertFalse(ticked, "an idle tree must not produce ticks")
    }

    func testEmptyRootsFinishesImmediatelyRatherThanHanging() async {
        let stream = DirectoryWatcher.changes(in: [], latency: 0.1)
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "no roots means a finished stream, not a live one")
    }

    func testNonexistentRootFinishesRatherThanHanging() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-does-not-exist-\(UUID().uuidString)")
        let stream = DirectoryWatcher.changes(in: [missing], latency: 0.1)
        // FSEvents tolerates a missing path, so this may stay open; what must
        // not happen is a crash or a spurious tick.
        let ticked = await awaitTick(stream, within: 1.0)
        XCTAssertFalse(ticked)
    }

    /// A burst of writes must not produce a tick per write — that is what makes
    /// the ~2.4-writes-per-turn streaming pattern affordable.
    func testCoalescesABurstOfWrites() async throws {
        let dir = try tempDir()
        let stream = DirectoryWatcher.changes(in: [dir], latency: 1.0)
        try await Task.sleep(nanoseconds: 400_000_000)

        let counter = TickCounter()
        let consumer = Task {
            for await _ in stream { await counter.increment() }
        }

        let file = dir.appendingPathComponent("burst.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for i in 0..<40 {
            try handle.write(contentsOf: Data("line \(i)\n".utf8))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try handle.close()

        try await Task.sleep(nanoseconds: 2_500_000_000)
        consumer.cancel()

        let ticks = await counter.value
        XCTAssertGreaterThan(ticks, 0, "the burst must be noticed at all")
        XCTAssertLessThan(ticks, 40, "40 writes must not mean 40 rescans")
    }
}

private actor TickCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
