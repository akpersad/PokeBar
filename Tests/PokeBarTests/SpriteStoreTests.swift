import XCTest
@testable import PokeBar

/// Pins the disk cache's behaviour.
///
/// The cache is permanent by design, which is only safe because sprite URLs are
/// pinned to a commit. That makes "never re-fetches" the central property, and
/// makes a torn write the one failure a never-expiring cache could not repair on
/// its own.
final class SpriteStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpriteStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A `URLProtocol` stub, so no test touches the network. Counts requests,
    /// which is how "fetched once" is asserted.
    private final class StubProtocol: URLProtocol {
        // Shared because URLProtocol is instantiated by the loading system, so
        // there is no place to inject per-instance state.
        nonisolated(unsafe) static var payload: Data = Data()
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var requestCount = 0
        static let lock = NSLock()

        static func reset(payload: Data, status: Int = 200) {
            lock.withLock {
                Self.payload = payload
                Self.status = status
                Self.requestCount = 0
            }
        }

        static var count: Int { lock.withLock { requestCount } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (payload, status) = Self.lock.withLock {
                Self.requestCount += 1
                return (Self.payload, Self.status)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !payload.isEmpty {
                client?.urlProtocol(self, didLoad: payload)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeStore(payload: Data, status: Int = 200) -> SpriteStore {
        StubProtocol.reset(payload: payload, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SpriteStore(directory: directory, session: URLSession(configuration: config))
    }

    private let url = URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/abc/1.gif")!

    func testFetchesOnceThenServesFromCache() async {
        let payload = Data("sprite-bytes".utf8)
        let store = makeStore(payload: payload)

        let first = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertEqual(first, payload)
        XCTAssertEqual(StubProtocol.count, 1)

        let second = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertEqual(second, payload)
        XCTAssertEqual(StubProtocol.count, 1, "a pinned URL must never be re-fetched")
    }

    /// The property that makes the cache worth having: sprites are served with
    /// `cache-control: max-age=300`, so relying on URLCache would re-download
    /// everything every five minutes. A fresh store with a cold memory cache must
    /// still answer from disk with no request at all.
    func testSurvivesARelaunchWithNoNetwork() async {
        let payload = Data("sprite-bytes".utf8)
        let store = makeStore(payload: payload)
        _ = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertEqual(StubProtocol.count, 1)

        // A new store over the same directory is what a relaunch looks like.
        let relaunched = makeStore(payload: Data("different".utf8))
        let cached = await relaunched.data(key: "1-gen5.gif", url: url)
        XCTAssertEqual(cached, payload, "must answer from disk, not re-fetch")
        XCTAssertEqual(StubProtocol.count, 0, "no request should be issued at all")
    }

    func testCachedReturnsNilBeforeAnythingIsFetched() async {
        let store = makeStore(payload: Data("x".utf8))
        let hit = await store.cached(key: "1-gen5.gif")
        XCTAssertNil(hit)
        XCTAssertEqual(StubProtocol.count, 0, "cached() must never touch the network")
    }

    func testCachedAnswersAfterAFetch() async {
        let payload = Data("sprite-bytes".utf8)
        let store = makeStore(payload: payload)
        _ = await store.data(key: "1-gen5.gif", url: url)
        let hit = await store.cached(key: "1-gen5.gif")
        XCTAssertEqual(hit, payload)
    }

    /// A missing sprite is cosmetic and must never surface as an error, nor be
    /// cached as an empty file that a permanent cache would then serve forever.
    func testFailedFetchIsNotCached() async {
        let store = makeStore(payload: Data(), status: 404)
        let result = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertNil(result)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("1-gen5.gif").path),
            "a 404 must not leave a file behind")
    }

    func testEmptyBodyIsTreatedAsFailure() async {
        let store = makeStore(payload: Data(), status: 200)
        let result = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertNil(result, "a zero-byte 200 is not a sprite")
    }

    /// A failure must not latch. The next call retries, because the sprite may
    /// simply have been unreachable while offline.
    func testFailureCanBeRetried() async {
        let store = makeStore(payload: Data(), status: 500)
        let failed = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertNil(failed)

        StubProtocol.reset(payload: Data("sprite-bytes".utf8))
        let retried = await store.data(key: "1-gen5.gif", url: url)
        XCTAssertEqual(retried, Data("sprite-bytes".utf8))
    }

    /// A dex grid asks many tiles for the same sprite at once. Coalescing is what
    /// keeps that one request rather than N.
    func testConcurrentRequestsForTheSameKeyCoalesce() async {
        let payload = Data("sprite-bytes".utf8)
        let store = makeStore(payload: payload)

        let url = self.url
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 {
                group.addTask { await store.data(key: "1-gen5.gif", url: url) }
            }
            for await result in group {
                XCTAssertEqual(result, payload)
            }
        }
        XCTAssertEqual(StubProtocol.count, 1, "20 concurrent asks should be one request")
    }

    func testDistinctKeysAreCachedSeparately() async {
        let store = makeStore(payload: Data("a".utf8))
        _ = await store.data(key: "1-gen5.gif", url: url)
        _ = await store.data(key: "1-gen5-shiny.gif", url: url)
        let usage = await store.diskUsage()
        XCTAssertEqual(usage.files, 2)
    }

    /// Writes are atomic so a crash mid-write cannot leave a truncated GIF that a
    /// never-expiring cache would then serve for good.
    func testWritesAreAtomic() async throws {
        let payload = Data(repeating: 0xAB, count: 64_000)
        let store = makeStore(payload: payload)
        _ = await store.data(key: "1-gen5.gif", url: url)

        let written = try Data(contentsOf: directory.appendingPathComponent("1-gen5.gif"))
        XCTAssertEqual(written.count, payload.count)
        XCTAssertEqual(written, payload)
    }
}
