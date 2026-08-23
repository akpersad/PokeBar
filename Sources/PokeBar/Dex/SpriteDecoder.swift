import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One rendered animation frame, already cropped and scaled to its display size.
struct SpriteFrame: Sendable {
    let image: CGImage
    /// How long to hold this frame, in seconds.
    let delay: TimeInterval
}

/// Decodes sprite bytes into display-ready frames.
///
/// Frames are pre-scaled to the target box at decode time rather than scaled on
/// every draw. A gen-V sprite is 51 to 108 frames and the menu bar redraws at up
/// to 16 fps, so rescaling per draw would be doing the same work thousands of
/// times a minute for an identical result.
enum SpriteDecoder {

    /// Decode `data` into frames fitted to `height` points, with width free up to
    /// `maxWidth`, rendered at `scale`.
    ///
    /// Height-constrained rather than fitted to a square box, because the menu bar
    /// limits height and has width to spare. See `SpriteGeometry.fit(pixelSize:height:maxWidth:)`.
    ///
    /// Returns an empty array if the bytes do not decode, which callers treat as
    /// "no sprite" rather than as an error.
    static func decode(
        _ data: Data,
        height: CGFloat,
        maxWidth: CGFloat,
        scale: CGFloat = 2
    ) -> [SpriteFrame] {
        guard height > 0, maxWidth > 0, scale > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return [] }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }

        // Frame extraction is safe index by index because every gen-V sprite
        // stores full-canvas frames: measured across Bulbasaur, Pikachu, Gengar,
        // Spoink and Lucario, all report a single distinct frame size and no
        // disposal metadata. An optimised GIF storing partial frames would need
        // compositing, and these do not.
        var frames: [SpriteFrame] = []
        frames.reserveCapacity(count)

        // Crop only stills.
        //
        // Measured: on every gen-V sprite the union of the per-frame content
        // boxes is exactly the full canvas, so cropping an animation buys nothing.
        // Cropping each frame to its own box would be actively wrong, because the
        // per-frame boxes differ (10 to 57 distinct boxes within one sprite) and
        // the sprite would jitter as its bounds moved under it. Stills are the
        // opposite case: a static PNG fills only 14 to 19% of its canvas, so
        // uncropped it draws at about half size.
        let cropStills = count == 1

        for index in 0..<count {
            guard let raw = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let cropped = cropStills ? cropToContent(raw) ?? raw : raw
            let fitted = SpriteGeometry.fit(
                pixelSize: CGSize(width: cropped.width, height: cropped.height),
                height: height,
                maxWidth: maxWidth)
            guard let scaled = resize(cropped, to: fitted, scale: scale) else { continue }
            frames.append(SpriteFrame(image: scaled, delay: delay(source, index, count: count)))
        }
        return frames
    }

    /// Frame delay in seconds, from the GIF metadata.
    ///
    /// Measured on the live set: delays are 60 to 200 ms, so 5 to 16 fps. A single
    /// frame has no meaningful delay and is reported as zero so callers can skip
    /// starting a ticker at all.
    private static func delay(_ source: CGImageSource, _ index: Int, count: Int) -> TimeInterval {
        guard count > 1 else { return 0 }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let seconds = unclamped ?? clamped ?? 0.1
        // A zero or near-zero delay means "as fast as possible", which browsers
        // interpret as ~0.1s. Honouring it literally would spin the ticker.
        return seconds < 0.02 ? 0.1 : seconds
    }

    /// Tight crop to non-transparent content.
    private static func cropToContent(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        // Draw into a known 8-bit RGBA buffer rather than trusting the source's
        // layout, so the alpha offset below is always correct.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let box = SpriteGeometry.contentBox(width: width, height: height, alphaAt: { x, y in
            CGFloat(pixels[(y * width + x) * 4 + 3]) / 255
        }) else { return nil }
        return image.cropping(to: box)
    }

    /// Nearest-neighbour resize.
    ///
    /// Interpolation is off on purpose. These are pixel-art sprites and smoothing
    /// them turns crisp pixels into mush, which is most obvious at the small sizes
    /// the menu bar uses.
    private static func resize(_ image: CGImage, to size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
