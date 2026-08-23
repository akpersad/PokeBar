import XCTest
@testable import PokeBar

/// Pins the sprite display geometry, which is the whole reason `SpriteGeometry`
/// is a pure enum rather than logic inside a view body.
final class SpriteGeometryTests: XCTestCase {

    // MARK: - Aspect-preserving fit

    /// The bug this prevents, with the measured canvas sizes that expose it.
    ///
    /// Static sprites are uniformly 96x96, so stretching to fill a square box is
    /// invisible on that path. Gen-V animated GIFs have a per-species canvas that
    /// is not square, so the same code distorts only the animated path, which is
    /// the one the menu bar uses. Spoink is the worst case at 36x66.
    func testGenVCanvasesFitWithoutDistortion() {
        // Spoink #325: 36x66, aspect 0.545. Stretched to square it is 1.83x too wide.
        let spoink = SpriteGeometry.fit(pixelSize: CGSize(width: 36, height: 66), box: 18)
        XCTAssertEqual(spoink.height, 18, accuracy: 0.001, "long edge should touch the box")
        XCTAssertEqual(spoink.width, 18 * 36 / 66, accuracy: 0.001)
        XCTAssertEqual(spoink.width / spoink.height, 36.0 / 66.0, accuracy: 0.001)

        // Pikachu #25: 50x46, wider than tall, so the width is what touches.
        let pikachu = SpriteGeometry.fit(pixelSize: CGSize(width: 50, height: 46), box: 18)
        XCTAssertEqual(pikachu.width, 18, accuracy: 0.001)
        XCTAssertEqual(pikachu.width / pikachu.height, 50.0 / 46.0, accuracy: 0.001)
    }

    func testSquareCanvasFillsTheBoxExactly() {
        let fitted = SpriteGeometry.fit(pixelSize: CGSize(width: 96, height: 96), box: 18)
        XCTAssertEqual(fitted.width, 18, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 18, accuracy: 0.001)
    }

    func testAspectIsPreservedForEveryMeasuredGenVCanvas() {
        // Every gen-V canvas measured against the live set.
        let canvases = [(37, 38), (50, 46), (74, 75), (36, 66), (46, 47), (47, 63)]
        for (width, height) in canvases {
            let fitted = SpriteGeometry.fit(
                pixelSize: CGSize(width: width, height: height), box: 18)
            XCTAssertEqual(
                fitted.width / fitted.height,
                CGFloat(width) / CGFloat(height),
                accuracy: 0.001,
                "\(width)x\(height)")
            XCTAssertLessThanOrEqual(max(fitted.width, fitted.height), 18.001)
        }
    }

    /// A failed decode reports a zero size. Dividing by it would produce NaN and
    /// SwiftUI would silently draw nothing, so the fallback is the square box.
    func testDegenerateSizesFallBackToTheBox() {
        XCTAssertEqual(SpriteGeometry.fit(pixelSize: .zero, box: 18),
                       CGSize(width: 18, height: 18))
        XCTAssertEqual(SpriteGeometry.fit(pixelSize: CGSize(width: 10, height: 0), box: 18),
                       CGSize(width: 18, height: 18))
        XCTAssertEqual(SpriteGeometry.fit(pixelSize: CGSize(width: 10, height: 10), box: 0),
                       .zero)
    }

    // MARK: - Content box

    /// The measured case: a static sprite's subject occupies 14 to 19% of its
    /// 96x96 canvas, so uncropped in an 18pt status item the Pokemon draws at
    /// about half size.
    func testContentBoxFindsTheSubjectInsideTransparentMargin() {
        // A 39x46 subject inside a 96x96 canvas, which is Pikachu's static sprite.
        let box = SpriteGeometry.contentBox(width: 96, height: 96) { x, y in
            (28..<67).contains(x) && (25..<71).contains(y) ? 1 : 0
        }
        XCTAssertEqual(box, CGRect(x: 28, y: 25, width: 39, height: 46))
    }

    func testContentBoxIsNilWhenFullyTransparent() {
        XCTAssertNil(SpriteGeometry.contentBox(width: 32, height: 32) { _, _ in 0 })
    }

    func testContentBoxCoversTheWholeCanvasWhenAlreadyTight() {
        // The gen-V case: the canvas already equals the content bounds, which is
        // why animated frames are not cropped at all.
        let box = SpriteGeometry.contentBox(width: 50, height: 46) { _, _ in 1 }
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 50, height: 46))
    }

    /// Nearly-transparent pixels are margin, not content. Without a threshold, a
    /// single stray alpha-1 pixel in a corner defeats the crop entirely.
    func testContentBoxIgnoresNearlyTransparentPixels() {
        let box = SpriteGeometry.contentBox(width: 16, height: 16) { x, y in
            if x == 0 && y == 0 { return 0.005 }   // stray, below threshold
            return (4..<8).contains(x) && (4..<8).contains(y) ? 1 : 0
        }
        XCTAssertEqual(box, CGRect(x: 4, y: 4, width: 4, height: 4))
    }

    func testContentBoxHandlesASinglePixel() {
        let box = SpriteGeometry.contentBox(width: 8, height: 8) { x, y in
            x == 3 && y == 5 ? 1 : 0
        }
        XCTAssertEqual(box, CGRect(x: 3, y: 5, width: 1, height: 1))
    }

    func testContentBoxRejectsEmptyCanvas() {
        XCTAssertNil(SpriteGeometry.contentBox(width: 0, height: 10) { _, _ in 1 })
        XCTAssertNil(SpriteGeometry.contentBox(width: 10, height: 0) { _, _ in 1 })
    }

    // MARK: - Composition

    /// The two together, on the worst measured case: a HOME fallback is a 512x512
    /// canvas whose subject is 392x300, so cropping first is what lets the subject
    /// fill an 18pt box instead of 77% of it.
    func testCropThenFitFillsTheBox() {
        let box = SpriteGeometry.contentBox(width: 512, height: 512) { x, y in
            (60..<452).contains(x) && (106..<406).contains(y) ? 1 : 0
        }
        let content = try! XCTUnwrap(box)
        XCTAssertEqual(content.size, CGSize(width: 392, height: 300))

        let fitted = SpriteGeometry.fit(pixelSize: content.size, box: 18)
        XCTAssertEqual(fitted.width, 18, accuracy: 0.001, "long edge fills the box after cropping")

        // Uncropped, the same sprite would only reach 77% of the box.
        let uncropped = SpriteGeometry.fit(pixelSize: CGSize(width: 512, height: 512), box: 18)
        let subjectShare = 18 * (392.0 / 512.0)
        XCTAssertEqual(uncropped.width, 18, accuracy: 0.001)
        XCTAssertLessThan(subjectShare, 14, "uncropped subject is much smaller than the box")
    }
}
