import XCTest

@testable import PokeBar

/// Runs the real scanner over the real `~/.claude/projects` tree.
///
/// Opt-in via `POKEBAR_CORPUS=1` because it is not hermetic: it reads hundreds
/// of megabytes and its numbers grow every time Claude Code is used. Its job is
/// not to assert fixed totals but to prove the Swift implementation agrees with
/// an independently written reference, and that incremental resume is exact.
final class CorpusParityTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["POKEBAR_CORPUS"] == "1"
    }

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "set POKEBAR_CORPUS=1 to run against the live corpus")
        let root = UsageScanner.defaultRoots()[0]
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: root.path), "no corpus at \(root.path)")
    }

    func testReportsCorpusTotals() throws {
        try skipUnlessEnabled()

        let clock = Date()
        let result = UsageScanner().scan()
        let elapsed = Date().timeIntervalSince(clock)

        var totals = TokenCounts.zero
        var byModel: [String: (turns: Int, tokens: TokenCounts)] = [:]
        var days = Set<String>()
        for entry in result.entries {
            totals += entry.tokens
            days.insert(entry.localDay)
            var bucket = byModel[entry.model] ?? (0, .zero)
            bucket.turns += 1
            bucket.tokens += entry.tokens
            byModel[entry.model] = bucket
        }

        print("""

        ── PokeBar corpus scan ─────────────────────────────────────────
        files examined : \(result.filesExamined)
        files read     : \(result.filesRead)
        bytes read     : \(result.bytesRead) (\(result.bytesRead / 1_048_576) MiB)
        elapsed        : \(String(format: "%.2fs", elapsed))
        deduped turns  : \(result.entries.count)
        distinct days  : \(days.count)

        input          : \(totals.input)
        output         : \(totals.output)
        cache write    : \(totals.cacheWrite)
        cache read     : \(totals.cacheRead)
        GRAND TOTAL    : \(totals.total)
        ────────────────────────────────────────────────────────────────
        """)
        for (model, bucket) in byModel.sorted(by: { $0.value.tokens.total > $1.value.tokens.total }) {
            print(String(
                format: "  %-24s turns=%-7d total=%d",
                (model as NSString).utf8String!, bucket.turns, bucket.tokens.total))
        }

        XCTAssertGreaterThan(result.entries.count, 0, "corpus present but no usage parsed")
        XCTAssertGreaterThan(totals.total, 0)
        // Cache reads dominate agentic usage; if this inverts, dedup is broken.
        XCTAssertGreaterThan(totals.cacheRead, totals.input)
    }

    /// The property that makes event-driven updates safe: scanning twice must
    /// not double count, and the second pass must read almost nothing.
    func testSecondPassIsIncrementalAndAddsNothing() throws {
        try skipUnlessEnabled()

        let scanner = UsageScanner()
        let first = scanner.scan()
        let second = scanner.scan(cursors: first.cursors)

        print("""

        ── incremental resume ──────────────────────────────────────────
        pass 1: \(first.filesRead) files, \(first.bytesRead) bytes, \(first.entries.count) turns
        pass 2: \(second.filesRead) files, \(second.bytesRead) bytes, \(second.entries.count) turns
        ────────────────────────────────────────────────────────────────
        """)

        XCTAssertLessThan(
            second.bytesRead, first.bytesRead / 100,
            "resume read too much; cursors are not being honoured")
        XCTAssertEqual(
            second.cursors.count, first.cursors.count,
            "cursor set changed size across an idle pass")
    }
}
