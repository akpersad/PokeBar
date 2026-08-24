import Foundation

/// Levels, and the one curve every species climbs.
///
/// `totalXP(forLevel:) = 100 * level^2`, so level 100 is 1,000,000 XP. Same
/// numbers for every Pokemon, which is what makes graduation at level 100 work
/// for a species that never evolves: evolution is an *event along the climb*, not
/// the goal of it. Lapras and Mewtwo climb the same ladder as Bulbasaur and
/// simply pass no thresholds on the way.
///
/// Cubic was tried first (the mainline "Medium Fast" n^3) and rejected: it
/// front-loads so hard that every evolution in the game is done inside the first
/// five hours of a 4.6-day climb, leaving four days of nothing. Squared keeps
/// per-level cost strictly increasing while spreading the interesting part out:
/// 300 XP for 1->2 up to 19,900 for 99->100, a 66x spread where cubic is 4,243x.
///
/// | Level | Total XP | Time from level 1 |
/// |---|---|---|
/// | 16 | 25,600 | 2.8 h |
/// | 36 | 129,600 | 14.4 h |
/// | 100 | 1,000,000 | 4.6 d |
///
/// See DECISIONS.md. The measured evolution levels (7 to 64, median 30) put the
/// first evolution inside a working session and the median one overnight.
enum XPCurve {

    /// Graduation. Every species, no exceptions.
    static let maxLevel = 100

    /// Weighted tokens per point of XP.
    ///
    /// At this machine's measured ~108M weighted tokens/day, 500 puts a full
    /// 1 to 100 climb at **4.63 days**, inside the 4-5 day target that set the
    /// curve in the first place.
    static let weightedTokensPerXP: Double = 500

    /// XP is a *parallel* derivation of the same tokens that mint coins, never a
    /// share of a pool. Training and saving happen at once, so there is no
    /// allocation choice to make and no week of training followed by a week of
    /// saving. See DECISIONS.md.
    static func xp(forWeightedTokens tokens: Double) -> Double {
        tokens / weightedTokensPerXP
    }

    /// Total XP an individual has when it reaches `level`.
    ///
    /// Note the baseline: a freshly hatched Pokemon is level 1 and therefore
    /// starts at 100 XP, not 0. Storing total XP rather than XP-since-hatch is
    /// what makes the table above the literal stored values, and the 100 never
    /// reaches the player because the UI shows progress *within* a level.
    static func totalXP(forLevel level: Int) -> Int {
        let clamped = min(max(level, 1), maxLevel)
        return 100 * clamped * clamped
    }

    /// The level `totalXP` buys. Inverse of the above, floored.
    static func level(forTotalXP totalXP: Double) -> Int {
        guard totalXP > 0 else { return 1 }
        let level = Int((totalXP / 100).squareRoot())
        return min(max(level, 1), maxLevel)
    }

    /// XP where this individual sits inside its current level, for a progress
    /// bar. `into == span` never happens: crossing the span is a level up.
    ///
    /// At level 100 there is no next level, so the bar reads full rather than
    /// dividing by a zero-width span.
    static func progress(totalXP: Double) -> (level: Int, into: Double, span: Double) {
        let level = self.level(forTotalXP: totalXP)
        guard level < maxLevel else { return (maxLevel, 1, 1) }
        let floor = Double(self.totalXP(forLevel: level))
        let ceiling = Double(self.totalXP(forLevel: level + 1))
        return (level, totalXP - floor, ceiling - floor)
    }

    /// XP still needed to reach `level`, or zero if it is already reached.
    static func xpRemaining(from totalXP: Double, toLevel level: Int) -> Double {
        max(0, Double(self.totalXP(forLevel: level)) - totalXP)
    }
}
