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

    // MARK: - Height-constrained fit (what the menu bar uses)

    /// The bug this fixes, with the case that exposed it on screen.
    ///
    /// A horizontal menu bar constrains height and has width to spare, so fitting
    /// to a square box shrinks every wide sprite for nothing. Glaceon shipped
    /// looking small for exactly this reason.
    func testWideSpriteFillsTheHeightInsteadOfBeingShrunk() {
        let glaceon = CGSize(width: 76, height: 54)

        // What a square box did: 18 wide, only 12.79 tall in a 22pt menu bar.
        let squared = SpriteGeometry.fit(pixelSize: glaceon, box: 18)
        XCTAssertEqual(squared.width, 18, accuracy: 0.001)
        XCTAssertEqual(squared.height, 18 * 54 / 76, accuracy: 0.001)
        XCTAssertLessThan(squared.height, 13)

        // Height-constrained: full 18pt tall, width follows.
        let fitted = SpriteGeometry.fit(pixelSize: glaceon, height: 18, maxWidth: 30)
        XCTAssertEqual(fitted.height, 18, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 18 * 76 / 54, accuracy: 0.001)
        XCTAssertEqual(fitted.width / fitted.height, 76.0 / 54.0, accuracy: 0.001)
    }

    /// A tall sprite is unaffected: it already filled the height under either rule.
    func testTallSpriteIsUnchangedByHeightFitting()  {
        let spoink = CGSize(width: 36, height: 66)
        let squared = SpriteGeometry.fit(pixelSize: spoink, box: 18)
        let fitted = SpriteGeometry.fit(pixelSize: spoink, height: 18, maxWidth: 30)
        XCTAssertEqual(fitted.width, squared.width, accuracy: 0.001)
        XCTAssertEqual(fitted.height, squared.height, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 18, accuracy: 0.001)
    }

    /// The widest sprite in the pool. It gives up height rather than pushing the
    /// menu bar around, and it is the only reason the cap exists.
    func testWidestSpriteInThePoolIsClampedByTheCap() {
        // Galarian Linoone, 82x41, aspect 2.00: 36pt wide at 18pt tall.
        let linoone = CGSize(width: 82, height: 41)
        let uncapped = SpriteGeometry.fit(pixelSize: linoone, height: 18, maxWidth: 100)
        XCTAssertEqual(uncapped.width, 36, accuracy: 0.001)

        let capped = SpriteGeometry.fit(pixelSize: linoone, height: 18, maxWidth: 30)
        XCTAssertEqual(capped.width, 30, accuracy: 0.001)
        XCTAssertEqual(capped.height, 15, accuracy: 0.001, "height given up, not aspect")
        XCTAssertEqual(capped.width / capped.height, 82.0 / 41.0, accuracy: 0.001)
    }

    /// The cap only ever scales down. A narrow sprite must not be stretched out to
    /// reach it.
    func testCapNeverScalesUp() {
        // Farigiraf, 62x128, the tallest sampled: 8.7pt wide at 18pt tall.
        let fitted = SpriteGeometry.fit(pixelSize: CGSize(width: 62, height: 128),
                                        height: 18, maxWidth: 30)
        XCTAssertEqual(fitted.height, 18, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 18 * 62 / 128, accuracy: 0.001)
        XCTAssertLessThan(fitted.width, 9)
    }

    /// Every canvas measured against the live set reaches full height under the
    /// 30pt cap, except the widest, which is the documented trade.
    func testMeasuredCanvasesReachFullHeightUnderTheCap() {
        let canvases = [
            (37, 38), (50, 46), (74, 75), (36, 66), (46, 47), (47, 63),  // gen-V samples
            (76, 54),   // Glaceon
            (94, 57),   // Heatmor, aspect 1.65
            (62, 128),  // Farigiraf, tallest
        ]
        for (width, height) in canvases {
            let fitted = SpriteGeometry.fit(
                pixelSize: CGSize(width: width, height: height), height: 18, maxWidth: 30)
            XCTAssertEqual(fitted.height, 18, accuracy: 0.001, "\(width)x\(height)")
            XCTAssertLessThanOrEqual(fitted.width, 30.001, "\(width)x\(height)")
            XCTAssertEqual(
                fitted.width / fitted.height,
                CGFloat(width) / CGFloat(height),
                accuracy: 0.001,
                "\(width)x\(height)")
        }
    }

    func testHeightFitRejectsDegenerateInput() {
        XCTAssertEqual(SpriteGeometry.fit(pixelSize: .zero, height: 18, maxWidth: 30), .zero)
        XCTAssertEqual(
            SpriteGeometry.fit(pixelSize: CGSize(width: 10, height: 10), height: 0, maxWidth: 30),
            .zero)
        XCTAssertEqual(
            SpriteGeometry.fit(pixelSize: CGSize(width: 10, height: 10), height: 18, maxWidth: 0),
            .zero)
    }

    // MARK: - Menu bar sizing constants

    /// The coupling that makes "just make it bigger" a trap.
    ///
    /// A sprite wider than the cap gives up height to respect it, so raising
    /// `height` without raising `maxWidth` makes wide species *smaller*. At 20pt
    /// tall the p95 sprite wants 32.2pt of width, so a 30pt cap (correct for the
    /// old 18pt height) would have clamped it.
    func testWidthCapClearsTheNinetyFifthPercentileAtTheChosenHeight() {
        let needed = MenuBarSprite.height * MenuBarSprite.p95Aspect
        XCTAssertGreaterThanOrEqual(
            MenuBarSprite.maxWidth, needed,
            "maxWidth must clear height * p95Aspect (\(needed)pt) or the cap bites 95% of the pool")
    }

    /// The status item's usable height is 22pt, measured via
    /// `NSStatusBar.system.thickness` on this machine. The visual menu bar is 33pt
    /// on a notched display, but that is safe-area inset and unavailable.
    func testHeightFitsInsideTheStatusItem() {
        XCTAssertLessThanOrEqual(MenuBarSprite.height, 22)
        XCTAssertGreaterThan(MenuBarSprite.height, 0)
    }

    /// The species Glaceon, at the shipping constants, as an end-to-end check that
    /// the numbers in the docs are the numbers the code produces.
    func testGlaceonAtShippingConstants() {
        let fitted = SpriteGeometry.fit(
            pixelSize: CGSize(width: 76, height: 54),
            height: MenuBarSprite.height,
            maxWidth: MenuBarSprite.maxWidth)
        XCTAssertEqual(fitted.height, 20, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 28.148, accuracy: 0.01)
    }

    /// The widest sprite in the pool still clears the cap at the shipping height,
    /// only just: 40.0pt wanted against a 33pt cap, so it does clamp, and loses
    /// height to 16.5pt. That is the documented trade, asserted rather than assumed.
    func testWidestSpriteAtShippingConstants() {
        let fitted = SpriteGeometry.fit(
            pixelSize: CGSize(width: 82, height: 41),
            height: MenuBarSprite.height,
            maxWidth: MenuBarSprite.maxWidth)
        XCTAssertEqual(fitted.width, 33, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 16.5, accuracy: 0.001)
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
