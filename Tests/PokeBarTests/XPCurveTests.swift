import XCTest
@testable import PokeBar

/// Pins the curve to the figures it was derived from.
///
/// These are not arbitrary: the shape was chosen so that a full climb takes 4-5
/// days at this machine's measured throughput and the measured evolution levels
/// (7 to 64, median 30) spread across it rather than all landing in the first
/// evening. Change a constant and one of these will say which promise broke.
final class XPCurveTests: XCTestCase {

    /// The table in DECISIONS.md, literally.
    func testTotalXPMatchesTheRecordedCurve() {
        XCTAssertEqual(XPCurve.totalXP(forLevel: 1), 100)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 10), 10_000)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 16), 25_600)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 30), 90_000)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 36), 129_600)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 64), 409_600)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 100), 1_000_000)
    }

    /// Squared rather than cubic, and this is the number that decides it.
    /// Cubic's spread is 4,243x, which front-loads every evolution into the first
    /// five hours of a four-day climb.
    func testPerLevelCostSpreadIs66x() {
        let first = XPCurve.totalXP(forLevel: 2) - XPCurve.totalXP(forLevel: 1)
        let last = XPCurve.totalXP(forLevel: 100) - XPCurve.totalXP(forLevel: 99)
        XCTAssertEqual(first, 300)
        XCTAssertEqual(last, 19_900)
        XCTAssertEqual(last / first, 66)
    }

    func testPerLevelCostIsStrictlyIncreasing() {
        for level in 1..<XPCurve.maxLevel {
            let step = XPCurve.totalXP(forLevel: level + 1) - XPCurve.totalXP(forLevel: level)
            let previous = level == 1
                ? 0 : XPCurve.totalXP(forLevel: level) - XPCurve.totalXP(forLevel: level - 1)
            XCTAssertGreaterThan(step, previous, "level \(level)")
        }
    }

    func testLevelIsTheInverseOfTotalXP() {
        for level in 1...XPCurve.maxLevel {
            let total = Double(XPCurve.totalXP(forLevel: level))
            XCTAssertEqual(XPCurve.level(forTotalXP: total), level)
            // One XP short is still the previous level.
            if level > 1 {
                XCTAssertEqual(XPCurve.level(forTotalXP: total - 1), level - 1)
            }
        }
    }

    func testLevelClampsAtBothEnds() {
        XCTAssertEqual(XPCurve.level(forTotalXP: 0), 1)
        XCTAssertEqual(XPCurve.level(forTotalXP: -5), 1)
        XCTAssertEqual(XPCurve.level(forTotalXP: 99), 1)
        XCTAssertEqual(XPCurve.level(forTotalXP: 50_000_000), 100)
        XCTAssertEqual(XPCurve.totalXP(forLevel: 500), XPCurve.totalXP(forLevel: 100))
    }

    /// The constraint the rate was solved for: a full 1 to 100 climb inside the
    /// 4-5 day target, at this machine's measured ~108M weighted tokens/day.
    func testAFullClimbTakesAboutFourAndAHalfDays() {
        let weightedPerDay = 108_000_000.0
        let xpPerDay = XPCurve.xp(forWeightedTokens: weightedPerDay)
        let days = Double(XPCurve.totalXP(forLevel: 100)) / xpPerDay
        XCTAssertEqual(days, 4.63, accuracy: 0.02)
    }

    /// 1 XP per 500 weighted tokens, and the same tokens still mint coins. The
    /// two are parallel derivations, never a shared pool, so a coin is worth 200
    /// XP of accrual and that is what prices a Rare Candy.
    func testXPAndCoinsComeFromTheSameTokensWithoutCompeting() {
        XCTAssertEqual(XPCurve.xp(forWeightedTokens: 500), 1)
        let perCoin = XPCurve.xp(forWeightedTokens: UsageLedger.tokensPerCoin)
        XCTAssertEqual(perCoin, 200)
        // A full climb passively earns about 5,000 coins while it happens.
        let coinsPerClimb = Double(XPCurve.totalXP(forLevel: 100)) / perCoin
        XCTAssertEqual(coinsPerClimb, 5_000, accuracy: 1)
    }

    /// The team multiplier, pinned. This is the number the whole v2 throughput
    /// argument rests on: a full team absorbs 5.0x one credit, which is
    /// affordable only because what it accelerates is graduation and graduation
    /// pays out nothing.
    func testAFullTeamMultipliesACreditByFive() {
        let full = XPCurve.leadShare + 5 * XPCurve.benchShare
        XCTAssertEqual(full, 5.0, accuracy: 0.000_1)
        XCTAssertEqual(XPCurve.share(forSlot: 0), XPCurve.leadShare)
        for slot in 1...5 {
            XCTAssertEqual(XPCurve.share(forSlot: slot), XPCurve.benchShare, "slot \(slot)")
        }
    }

    /// A share multiplies, it never splits. If the bench were paid out of the
    /// lead's share, filling the team would be a *downgrade*, which is the
    /// reading the user rejected.
    func testABenchSlotNeverCostsTheLeadAnything() {
        XCTAssertEqual(XPCurve.leadShare, 1.0, "the lead always takes the whole credit")
        XCTAssertGreaterThan(XPCurve.benchShare, 0)
        XCTAssertLessThanOrEqual(XPCurve.benchShare, XPCurve.leadShare, "and never more")
    }

    /// Graduation gets 5x faster, and that is the cost being accepted. 4.63 days
    /// of one Pokemon becomes 0.93 days of team-wide climbing.
    func testTheTeamCompressesAFullClimbToUnderADay() {
        let perDay = 108_000_000.0 / XPCurve.weightedTokensPerXP
        let solo = Double(XPCurve.totalXP(forLevel: 100)) / perDay
        let team = solo / (XPCurve.leadShare + 5 * XPCurve.benchShare)
        XCTAssertEqual(solo, 4.63, accuracy: 0.01)
        XCTAssertEqual(team, 0.93, accuracy: 0.01)
    }

    func testProgressWithinALevel() {
        let (level, into, span) = XPCurve.progress(totalXP: Double(XPCurve.totalXP(forLevel: 10)))
        XCTAssertEqual(level, 10)
        XCTAssertEqual(into, 0)
        XCTAssertEqual(span, 2_100)  // 12,100 - 10,000
    }

    /// At the ceiling there is no next level, so the bar must read full rather
    /// than divide by a zero-width span.
    func testProgressAtGraduationReadsFull() {
        let (level, into, span) = XPCurve.progress(totalXP: 1_000_000)
        XCTAssertEqual(level, 100)
        XCTAssertEqual(into / span, 1)
    }
}
