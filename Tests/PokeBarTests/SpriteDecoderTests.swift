import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import PokeBar

/// Pins the decode contract: bytes in, display-ready frames out.
///
/// Fixtures are synthesised in memory rather than checked in, so these stay
/// hermetic while still exercising real ImageIO GIF and PNG decoding.
final class SpriteDecoderTests: XCTestCase {

    // MARK: - Fixtures

    /// A solid rectangle of `size` centred in a `canvas`-sized transparent frame.
    private func image(canvas: CGSize, subject: CGRect) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(canvas.width), height: Int(canvas.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(subject)
        return try XCTUnwrap(context.makeImage())
    }

    /// Encodes frames as an animated GIF with the given per-frame delay.
    private func gif(frames: [CGImage], delay: Double) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - Animated path

    /// The shape of a real gen-V sprite: many full-canvas frames on a non-square
    /// canvas. Frames must all survive, and each must come out pre-scaled to the
    /// aspect-preserving fit rather than squashed into the square box.
    func testAnimatedGIFDecodesEveryFrameAtTheFittedSize() throws {
        // Spoink's canvas, the worst aspect ratio in the set.
        let canvas = CGSize(width: 36, height: 66)
        let frames = try (0..<8).map { i in
            try image(canvas: canvas, subject: CGRect(x: 0, y: i, width: 36, height: 60))
        }
        let decoded = SpriteDecoder.decode(
            try gif(frames: frames, delay: 0.1), height: 18, maxWidth: 30, scale: 2)

        XCTAssertEqual(decoded.count, 8)
        // 36x66 at 18pt tall => 9.818 x 18, at scale 2 => 20 x 36.
        let expected = SpriteGeometry.fit(pixelSize: canvas, height: 18, maxWidth: 30)
        for frame in decoded {
            XCTAssertEqual(frame.image.width, Int((expected.width * 2).rounded()))
            XCTAssertEqual(frame.image.height, Int((expected.height * 2).rounded()))
            XCTAssertEqual(frame.delay, 0.1, accuracy: 0.001)
        }
    }

    /// Animated frames are deliberately not cropped: on every real gen-V sprite
    /// the canvas already equals the union of the per-frame content boxes, and the
    /// per-frame boxes differ from each other (10 to 57 distinct boxes in one
    /// sprite). Cropping each to its own box would make the sprite jitter.
    ///
    /// The fixture makes that visible: each frame's subject sits at a different
    /// offset, so per-frame cropping would yield differing sizes.
    func testAnimatedFramesAreNotCroppedIndividually() throws {
        let canvas = CGSize(width: 40, height: 40)
        let frames = try [
            image(canvas: canvas, subject: CGRect(x: 0, y: 0, width: 10, height: 10)),
            image(canvas: canvas, subject: CGRect(x: 20, y: 20, width: 20, height: 20)),
            image(canvas: canvas, subject: CGRect(x: 5, y: 30, width: 30, height: 5)),
        ]
        let decoded = SpriteDecoder.decode(
            try gif(frames: frames, delay: 0.1), height: 20, maxWidth: 30, scale: 1)

        XCTAssertEqual(decoded.count, 3)
        let sizes = Set(decoded.map { "\($0.image.width)x\($0.image.height)" })
        XCTAssertEqual(sizes.count, 1, "every frame must keep the same bounds, or the sprite jitters")
        XCTAssertEqual(decoded[0].image.width, 20, "square canvas is as wide as it is tall")
    }

    /// A near-zero delay means "as fast as possible". Honouring it literally would
    /// spin the animation ticker, so it is clamped to the browser convention.
    func testNearZeroDelayIsClamped() throws {
        let frames = try (0..<3).map { _ in
            try image(canvas: CGSize(width: 20, height: 20),
                      subject: CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let decoded = SpriteDecoder.decode(
            try gif(frames: frames, delay: 0.001), height: 18, maxWidth: 30)
        XCTAssertFalse(decoded.isEmpty)
        for frame in decoded {
            XCTAssertEqual(frame.delay, 0.1, accuracy: 0.001)
        }
    }

    // MARK: - Still path

    /// The opposite rule: a still is cropped, because a static sprite's subject
    /// fills only 14 to 19% of its canvas and would otherwise draw at about half
    /// size in an 18pt status item.
    func testStillIsCroppedToItsSubject() throws {
        // Pikachu's static sprite: a 39x46 subject in a 96x96 canvas.
        let source = try image(
            canvas: CGSize(width: 96, height: 96),
            subject: CGRect(x: 28, y: 25, width: 39, height: 46))
        let decoded = SpriteDecoder.decode(try png(source), height: 18, maxWidth: 30, scale: 1)

        XCTAssertEqual(decoded.count, 1)
        let frame = try XCTUnwrap(decoded.first)
        // Cropped to 39x46, then fitted to 18pt tall.
        XCTAssertEqual(frame.image.height, 18)
        XCTAssertEqual(frame.image.width, Int((18.0 * 39 / 46).rounded()))
        // Uncropped, the 96x96 canvas is square, so it would have been 18x18 and
        // the subject would have occupied roughly half of it.
        XCTAssertNotEqual(frame.image.width, 18)
    }

    /// A single frame gets no delay, which is how the animator knows not to start
    /// a ticker at all for the 14 static entries.
    func testStillReportsNoDelay() throws {
        let source = try image(
            canvas: CGSize(width: 32, height: 32),
            subject: CGRect(x: 8, y: 8, width: 16, height: 16))
        let decoded = SpriteDecoder.decode(try png(source), height: 18, maxWidth: 30)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].delay, 0)
    }

    /// A fully transparent still has no content box. It must fall back to the
    /// uncropped image rather than decoding to nothing.
    func testFullyTransparentStillStillDecodes() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let blank = try XCTUnwrap(context.makeImage())
        let decoded = SpriteDecoder.decode(try png(blank), height: 18, maxWidth: 30, scale: 1)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].image.width, 18)
    }

    // MARK: - Failure handling

    /// A missing or corrupt sprite is cosmetic. It must decode to nothing rather
    /// than throwing or trapping, so the status item falls back to its symbol.
    func testGarbageDecodesToNoFrames() {
        XCTAssertTrue(
            SpriteDecoder.decode(Data("not an image".utf8), height: 18, maxWidth: 30).isEmpty)
        XCTAssertTrue(SpriteDecoder.decode(Data(), height: 18, maxWidth: 30).isEmpty)
    }

    func testNonPositiveDimensionsDecodeToNoFrames() throws {
        let source = try image(canvas: CGSize(width: 32, height: 32),
                               subject: CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = try png(source)
        XCTAssertTrue(SpriteDecoder.decode(data, height: 0, maxWidth: 30).isEmpty)
        XCTAssertTrue(SpriteDecoder.decode(data, height: 18, maxWidth: 0).isEmpty)
        XCTAssertTrue(SpriteDecoder.decode(data, height: 18, maxWidth: 30, scale: 0).isEmpty)
    }

    /// A very wide sprite gives up height rather than pushing the menu bar around.
    /// Galarian Linoone at 82x41 is the widest in the pool.
    func testVeryWideSpriteIsClampedByMaxWidth() throws {
        let frames = try (0..<3).map { _ in
            try image(canvas: CGSize(width: 82, height: 41),
                      subject: CGRect(x: 0, y: 0, width: 82, height: 41))
        }
        let decoded = SpriteDecoder.decode(
            try gif(frames: frames, delay: 0.1), height: 18, maxWidth: 30, scale: 1)
        XCTAssertFalse(decoded.isEmpty)
        let frame = try XCTUnwrap(decoded.first)
        XCTAssertEqual(frame.image.width, 30, "clamped to the cap")
        XCTAssertEqual(frame.image.height, 15, "height given up to respect the cap")
    }
}
