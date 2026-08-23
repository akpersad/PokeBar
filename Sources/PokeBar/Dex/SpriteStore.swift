import Foundation

/// Fetches sprite bytes and caches them on disk, permanently.
///
/// **An explicit disk cache, not `URLCache`.** Measured: every sprite in all three
/// sets is served by `raw.githubusercontent.com` with `cache-control: max-age=300`.
/// Five minutes. A URL-cache-backed dex would re-download the whole wall of
/// sprites every five minutes of browsing, and would show nothing at all offline.
///
/// What makes a permanent cache safe is that `Pokedex.spriteURL` pins the sprites
/// repo to a commit SHA, so a given URL's bytes can never change. There is no
/// revalidation, no ETag round-trip, and no expiry: a file on disk is the answer.
/// Upstream cached to disk too, but against `master`, so its cached files could
/// silently drift from the branch they were named after.
///
/// Nothing is prefetched. Sprites are pulled on first display, which keeps a fresh
/// install from opening 2,166 connections for a dex the player has not looked at.
actor SpriteStore {

    /// Bytes held in memory, most-recently-used last.
    ///
    /// Bounded because a dex page turns over many sprites and animated GIFs are
    /// far heavier than the static PNGs upstream was caching: measured 19 KiB for
    /// Bulbasaur, 29 KiB for Ditto, 75 KiB for Gengar, and 108 KiB for a HOME
    /// fallback. 96 entries is a few MiB at the top end, which comfortably covers
    /// a visible page without growing without bound across a long session.
    private static let memoryLimit = 96

    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private let directory: URL
    private let session: URLSession

    /// In-flight fetches, keyed by cache key, so a grid that asks for the same
    /// sprite from several tiles at once issues one request rather than N.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(directory: URL = SpriteStore.defaultDirectory(), session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBar/sprites", isDirectory: true)
    }

    /// Cached bytes for `key`, without touching the network. nil if not cached.
    ///
    /// Lets a view draw immediately on the common path instead of flashing a
    /// placeholder for one frame before the async load resolves.
    func cached(key: String) -> Data? {
        if let data = memory[key] {
            touch(key)
            return data
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)) else {
            return nil
        }
        remember(key, data)
        return data
    }

    /// Bytes for `key`, fetching from `url` and caching if not already present.
    ///
    /// Returns nil on any failure. A missing sprite is a cosmetic problem, so it
    /// must never propagate as an error into the usage engine.
    func data(key: String, url: URL) async -> Data? {
        if let hit = cached(key: key) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty
            else { return nil }
            return data
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil

        guard let data else { return nil }
        // Atomic so a crash mid-write cannot leave a truncated GIF cached
        // permanently, which a never-expiring cache would otherwise never repair.
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
        remember(key, data)
        return data
    }

    /// Bytes on disk, in bytes, and the file count. For diagnostics only.
    func diskUsage() -> (files: Int, bytes: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return (0, 0)
        }
        var total = 0
        for name in names {
            let path = directory.appendingPathComponent(name).path
            total += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }
        return (names.count, total)
    }

    // MARK: - Memory LRU

    private func remember(_ key: String, _ data: Data) {
        memory[key] = data
        touch(key)
        while order.count > Self.memoryLimit {
            let evicted = order.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
