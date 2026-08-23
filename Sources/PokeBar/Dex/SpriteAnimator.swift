import Foundation
import Observation
import CoreGraphics

/// Drives one animated sprite for the UI to bind to.
///
/// **Why this animates at all, and what it costs.** Measured on the live sprite
/// set: a gen-V sprite is 51 to 108 frames with 60 to 200 ms delays, so animating
/// it redraws the status item at 5 to 16 fps for as long as the app runs. That is
/// a real continuous cost in a project whose usage engine deliberately does not
/// poll, so it is a deliberate exception rather than an oversight: the moving
/// sprite is the point of the app, and an 18pt bitmap blit is cheap in a way that
/// re-reading 481 MiB of JSONL is not.
///
/// Two concessions keep it honest. Frames are pre-scaled at decode time, so the
/// per-tick work is a pointer swap and a redraw, not an image resize. And Low
/// Power Mode drops to a single still frame, because a battery-saving user did not
/// ask for 16 fps of decoration.
@MainActor
@Observable
final class SpriteAnimator {

    /// The frame the UI should draw, or nil before the first sprite resolves.
    private(set) var frame: CGImage?
    /// The entry currently being shown, for the accessibility label.
    private(set) var entry: DexEntry?

    private let pokedex: Pokedex?
    private let store: SpriteStore
    private let box: CGFloat
    private let scale: CGFloat

    private var frames: [SpriteFrame] = []
    private var ticker: Task<Void, Never>?
    private var loaded: Int?

    /// - Parameters:
    ///   - box: display size in points, the square the sprite fits inside.
    ///   - scale: backing scale factor. 2 covers every Retina display this runs on.
    init(pokedex: Pokedex?, store: SpriteStore, box: CGFloat = 18, scale: CGFloat = 2) {
        self.pokedex = pokedex
        self.store = store
        self.box = box
        self.scale = scale
    }

    /// Show `entry`, fetching and decoding its sprite if needed.
    ///
    /// Idempotent for a given entry, so a view that calls this on every state
    /// change cannot restart the animation or re-fetch.
    func show(_ entry: DexEntry) async {
        guard let pokedex, loaded != entry.id else { return }
        loaded = entry.id
        self.entry = entry

        let key = pokedex.cacheKey(for: entry)
        let url = pokedex.spriteURL(for: entry)
        guard let data = await store.data(key: key, url: url) else {
            // Offline with a cold cache. Leave the previous frame in place and
            // allow a later call to retry rather than latching a failure.
            loaded = nil
            return
        }

        let box = self.box, scale = self.scale
        let decoded = await Task.detached { SpriteDecoder.decode(data, box: box, scale: scale) }.value
        guard !decoded.isEmpty else { return }

        frames = decoded
        frame = decoded.first?.image
        startTicker()
    }

    /// Show the dex entry for the given day. See `Pokedex.featured(on:)` for why
    /// this is a placeholder with a clean seam into the game layer.
    func showFeatured(on date: Date = Date()) async {
        guard let entry = pokedex?.featured(on: date) else { return }
        await show(entry)
    }

    /// Stops the ticker. No `deinit` counterpart: under Swift 6 strict concurrency
    /// a `deinit` cannot touch main-actor state, and this object lives as long as
    /// the status item does, so there is nothing to clean up implicitly.
    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private func startTicker() {
        stop()
        // A still, or a battery-saving user: draw one frame and start nothing.
        guard frames.count > 1, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }

        ticker = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                let frames = self.frames
                guard frames.count > 1 else { return }
                index = (index + 1) % frames.count
                let next = frames[index]
                self.frame = next.image
                try? await Task.sleep(for: .seconds(next.delay))
            }
        }
    }
}
