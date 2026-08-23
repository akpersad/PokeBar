import CoreGraphics

/// Menu bar sprite sizing, in points.
///
/// These two are coupled and must move together, which is why they live next to
/// each other with the ratio that ties them recorded. Raising `height` without
/// raising `maxWidth` makes the cap bite sprites it used to clear, and a clamped
/// sprite gives up height, so a naive "make it bigger" makes wide species
/// *smaller*. A test pins the relationship.
enum MenuBarSprite {

    /// Measured on this machine: `NSStatusBar.system.thickness` is 22pt, and a
    /// status item's button reports the same. The visual menu bar is 33pt on a
    /// notched display, but that extra space is safe-area inset and not available
    /// to a status item, so 22 is the real ceiling.
    ///
    /// 20 leaves 1pt of clearance above and below. System menu bar icons sit
    /// closer to 18; this is deliberately a little bolder than native, because the
    /// sprite is the point of the app rather than a control affordance.
    static let height: CGFloat = 20

    /// Width cap. See `SpriteGeometry.fit(pixelSize:height:maxWidth:)` for the
    /// measured aspect-ratio distribution behind it.
    static let maxWidth: CGFloat = 33

    /// 95th-percentile aspect ratio (width/height) over a 155-entry sample of the
    /// real pool. `maxWidth` must be at least `height * p95Aspect` or the cap stops
    /// clearing 95% of the pool.
    static let p95Aspect: CGFloat = 1.61
}

/// Pure sprite geometry. This is where the sprite display behaviour is pinned by
/// tests, for the same reason `UsageFormat` exists: a fact asserted in a view body
/// cannot be tested in this toolchain.
///
/// Both functions here exist because of a measured property of the sprite sets,
/// not as defensive padding.
enum SpriteGeometry {

    /// Aspect-preserving fit into a square box, the way `.fit` would.
    ///
    /// Needed because gen-V animated GIFs have a per-species canvas that is not
    /// square, while every static sprite is a uniform square. Measured on the
    /// live sets:
    ///
    /// | Entry | gen-V GIF | static PNG |
    /// |---|---|---|
    /// | Bulbasaur #1 | 37x38 | 96x96 |
    /// | Pikachu #25 | 50x46 | 96x96 |
    /// | Gengar #143 | 74x75 | 96x96 |
    /// | Spoink #325 | 36x66 | 96x96 |
    /// | Lucario #448 | 47x63 | 96x96 |
    ///
    /// So stretching to fill a square box is invisible on the static path and
    /// distorts only the animated one, which is the path the menu bar uses.
    /// Spoink at 36x66 would render 1.83x too wide.
    static func fit(pixelSize: CGSize, box: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0, box > 0 else {
            return CGSize(width: max(box, 0), height: max(box, 0))
        }
        let scale = min(box / pixelSize.width, box / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    /// Aspect-preserving fit to a target *height*, with width free up to a cap.
    ///
    /// This is what the menu bar uses, rather than the square `fit(pixelSize:box:)`
    /// above. A horizontal menu bar constrains height and has width to spare, so
    /// fitting to a square box shrinks every wide sprite for no reason: Glaceon's
    /// 76x54 canvas in a 20pt square box renders 20 x 14.2, while fitting to height
    /// gives 28.1 x 20.
    ///
    /// Measured over a 155-entry sample of the real pool, aspect ratio
    /// width/height, at the 20pt height in `MenuBarSprite`:
    ///
    /// | | ratio | width at 20pt tall |
    /// |---|---|---|
    /// | widest: Galarian Linoone 82x41 | 2.00 | 40.0pt |
    /// | p95 | 1.61 | 32.2pt |
    /// | median | 1.00 | 20.0pt |
    /// | tallest: Farigiraf 62x128 | 0.48 | 9.7pt |
    ///
    /// So a `maxWidth` of 33 leaves 95% of the pool at full height and bounds the
    /// status item for the handful of very wide sprites, which give up height
    /// rather than pushing the menu bar around.
    ///
    /// The cost of this over a square box is that the item's width now depends on
    /// which species is shown. That is acceptable because the species changes once
    /// a day, not once per usage update, so it does not reintroduce the per-update
    /// width shuffle that compact coin formatting exists to prevent.
    static func fit(pixelSize: CGSize, height: CGFloat, maxWidth: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0, height > 0, maxWidth > 0 else {
            return .zero
        }
        var scale = height / pixelSize.height
        // Only ever scales down: a sprite wider than the cap gives up height.
        if pixelSize.width * scale > maxWidth {
            scale = maxWidth / pixelSize.width
        }
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    /// Tight bounding box of non-transparent pixels, or nil if fully transparent.
    ///
    /// Needed because the static sets waste most of their canvas on transparent
    /// margin, so drawing them uncropped renders the subject at roughly half size.
    /// Measured content fill:
    ///
    /// | Sprite | canvas | content | fill | longest edge |
    /// |---|---|---|---|---|
    /// | Pikachu static PNG | 96x96 | 39x46 | 19% | 0.48 |
    /// | Spoink static PNG | 96x96 | 26x51 | 14% | 0.53 |
    /// | Pecharunt HOME PNG | 512x512 | 392x300 | 45% | 0.77 |
    /// | Pikachu gen-V GIF | 50x46 | 39x46 | 78% | 0.92 |
    /// | Spoink gen-V GIF | 36x66 | 26x51 | 56% | 0.77 |
    ///
    /// In a 20pt status item an uncropped static sprite gives a ~10pt subject.
    /// The gen-V GIFs are already tight (Glaceon's per-frame subject fills 93-100%
    /// of its canvas height across all 129 frames), so this matters most for the 14
    /// entries that fall back to HOME.
    ///
    /// Takes an alpha sampler rather than an image so the rule is testable without
    /// decoding anything.
    static func contentBox(
        width: Int,
        height: Int,
        alphaAt: (Int, Int) -> CGFloat
    ) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alphaAt(x, y) > 0.01 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX, y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1)
    }
}
