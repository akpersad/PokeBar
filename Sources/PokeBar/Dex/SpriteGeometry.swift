import CoreGraphics

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
    /// In an 18pt status item an uncropped static sprite gives a ~9pt subject.
    /// The gen-V GIFs are already tight, so this matters most for the 14 entries
    /// that fall back to HOME.
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
