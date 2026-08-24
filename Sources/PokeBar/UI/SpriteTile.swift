import CoreGraphics
import SwiftUI

/// One still sprite, fetched and decoded on appearance.
///
/// A dex page turns over dozens of these, so it draws a single frame rather than
/// an animation and asks the store for cached bytes first: on the common path the
/// sprite is already on disk and appears without a placeholder flash. Sprites are
/// never prefetched, so scrolling into new territory is what pulls them.
struct SpriteTile: View {
    let entry: DexEntry
    var variant: SpriteVariant = .normal
    let dex: Pokedex
    let store: SpriteStore
    var height: CGFloat = 40
    /// Draw the sprite as a flat silhouette. Used for entries seen in one variant
    /// but not this one, where the shape is already known and the colours are the
    /// thing still to earn.
    var silhouette: Bool = false

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .opacity(silhouette ? 0.45 : 1)
                    .saturation(silhouette ? 0 : 1)
                    .brightness(silhouette ? -0.35 : 0)
            } else {
                // Holds the row height so a grid does not reflow as sprites land.
                Color.clear
            }
        }
        .frame(height: height)
        .task(id: TileKey(entry: entry.id, variant: entry.resolve(variant))) {
            await load()
        }
    }

    private struct TileKey: Hashable {
        let entry: Int
        let variant: SpriteVariant
    }

    private func load() async {
        let key = dex.cacheKey(for: entry, variant: variant)
        let url = dex.spriteURL(for: entry, variant: variant)
        guard let data = await store.data(key: key, url: url) else { return }
        let height = self.height
        let decoded = await Task.detached {
            // Width is left generous: a grid cell is square-ish and the widest
            // sprite in the pool is 2.00 aspect, so this only ever caps the
            // extremes rather than shrinking the median.
            SpriteDecoder.still(data, height: height, maxWidth: height * 2)
        }.value
        guard let decoded else { return }
        image = decoded
    }
}
