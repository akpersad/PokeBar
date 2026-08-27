import XCTest

@testable import PokeBar

/// Runs the real scanner over the real Claude Code and Codex trees, and the
/// real Copilot parser over the real `~/.copilot/session-store.db`.
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

    /// Independent parity check for Codex's cumulative session counters.
    ///
    /// The production parser sums per-response `last_token_usage`; this reference
    /// instead takes the final `total_token_usage` snapshot from each rollout.
    /// Agreement proves that responses are neither skipped nor double-counted.
    func testCodexEntriesMatchCumulativeSessionTotals() throws {
        try skipUnlessEnabled()

        let codexRoot = UsageScanner.defaultRoots()[1]
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: codexRoot.path),
            "no Codex corpus at \(codexRoot.path)")

        var expected = TokenCounts.zero
        var expectedEvents = 0
        for file in UsageScanner.jsonlFiles(under: codexRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            var latest: [String: Any]?
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { continue }
                latest = total
                expectedEvents += 1
            }
            guard let latest else { continue }
            let input = latest["input_tokens"] as? Int ?? 0
            let read = latest["cached_input_tokens"] as? Int ?? 0
            let write = latest["cache_write_input_tokens"] as? Int ?? 0
            expected += TokenCounts(
                input: max(0, input - read - write),
                output: latest["output_tokens"] as? Int ?? 0,
                cacheWrite: write,
                cacheRead: read)
        }

        let entries = UsageScanner(roots: [codexRoot]).scan().entries
        let actual = entries.reduce(into: TokenCounts.zero) { $0 += $1.tokens }
        XCTAssertGreaterThan(expectedEvents, 0)
        XCTAssertEqual(actual, expected)
    }

    /// Prices the real corpus and reports the tier-weighted currency.
    ///
    /// Currency is raw token count (every class counted equally, matching what
    /// the Anthropic console reports) times a per-model tier multiplier. The
    /// dollar figure is API-equivalent, not money spent on a subscription.
    func testReportsCostAndWeightedCurrency() throws {
        try skipUnlessEnabled()

        let pricing = ModelPricing()
        let entries = UsageScanner().scan().entries
        let (totals, weighted) = pricing.totals(for: entries)

        print("""

        ── pricing ─────────────────────────────────────────────────────
        raw tokens        : \(totals.tokens.total)
        weighted currency : \(String(format: "%.0f", weighted))
        API-equiv cost    : $\(String(format: "%.2f", totals.costUSD))
        unpriced models   : \(totals.hasUnpricedModels ? "YES — cost is a floor" : "none")
        ────────────────────────────────────────────────────────────────
        """)
        let byWeight = totals.byModel.sorted { $0.value.total > $1.value.total }
        for (model, tokens) in byWeight {
            let tier = pricing.tierMultiplier(for: model)
            let rate = pricing.rate(for: model)
            print(String(
                format: "  %-20s tokens=%-14d tier=%-5s cost=$%.2f",
                (model as NSString).utf8String!, tokens.total,
                ((tier.map { String(format: "%.1f", $0) } ?? "??") as NSString).utf8String!,
                rate?.costUSD(for: tokens) ?? 0))
        }

        XCTAssertFalse(
            totals.hasUnpricedModels,
            "a model in this corpus is unpriced; the bundled table needs the entry")
        XCTAssertGreaterThan(totals.costUSD, 0)
        // Usage is ~81% fable-5 at tier 2.0, so weighting must exceed raw count.
        XCTAssertGreaterThan(weighted, Double(totals.tokens.total))
    }

    /// The runtime snapshot must actually resolve the models in this corpus,
    /// not just parse. Network-dependent, so a fetch failure skips rather than
    /// fails — the bundled table is the guarantee, this is the improvement.
    func testRuntimeSnapshotCoversThisCorpus() async throws {
        try skipUnlessEnabled()

        let catalog = PricingCatalog(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pokebar-pricing-\(UUID().uuidString).json"))
        let refreshed = await catalog.refreshIfNeeded(force: true)
        try XCTSkipUnless(refreshed, "pricing source unreachable")

        let pricing = await catalog.current()
        let models = Set(UsageScanner().scan().entries.map(\.model))
        print("\n── runtime snapshot ────────────────────────────────────────────")
        for model in models.sorted() {
            let rate = pricing.rate(for: model)
            print(String(
                format: "  %-20s %@",
                (model as NSString).utf8String!,
                rate.map { String(format: "$%.2f/$%.2f per MTok",
                                  $0.input * 1e6, $0.output * 1e6) } ?? "UNPRICED"))
            XCTAssertNotNil(rate, "\(model) unpriced after a live refresh")
        }
        print("────────────────────────────────────────────────────────────────")
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

    /// Reads the live Copilot database through the parser and checks it against
    /// the same figures computed independently with SQL through the `sqlite3`
    /// CLI. Two code paths, one answer, which is the only way to know the C API
    /// reads here are picking up the right columns.
    ///
    /// Also the only place the read-only-under-WAL open is exercised against a
    /// database another process is actively writing. The main file measured 272
    /// KiB against a 3.4 MiB WAL, so a reader that missed the WAL would come
    /// back nearly empty rather than fail, which a fixture cannot catch.
    func testCopilotParserAgreesWithSQL() throws {
        try XCTSkipUnless(enabled, "set POKEBAR_CORPUS=1 to run against the live corpus")
        let database = CopilotUsageParser.defaultDatabaseURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: database.path),
            "no Copilot CLI database at \(database.path)")

        let result = CopilotUsageParser.scan(databaseURL: database, cursor: 0)

        let reference = try sqlQuery(
            database,
            """
            SELECT count(*), max(id),
                   sum(input_tokens - cache_read_tokens - cache_write_tokens),
                   sum(output_tokens), sum(cache_write_tokens), sum(cache_read_tokens)
            FROM assistant_usage_events
            WHERE input_tokens > 0 OR output_tokens > 0
            """)
        let expected = reference.split(separator: "|").map { Int($0) ?? 0 }
        try XCTSkipUnless(expected.count == 6 && expected[0] > 0, "no rows recorded yet")

        var totals = TokenCounts.zero
        var byModel: [String: TokenCounts] = [:]
        for entry in result.entries {
            totals += entry.tokens
            byModel[entry.model, default: .zero] += entry.tokens
            XCTAssertEqual(entry.source, .copilotCLI)
        }

        print("""

        ── PokeBar Copilot scan ────────────────────────────────────────
        rows credited  : \(result.entries.count)
        cursor         : \(result.cursor)
        input          : \(totals.input)
        output         : \(totals.output)
        cache write    : \(totals.cacheWrite)
        cache read     : \(totals.cacheRead)
        GRAND TOTAL    : \(totals.total)
        models         : \(byModel.keys.sorted().joined(separator: ", "))
        ────────────────────────────────────────────────────────────────
        """)

        XCTAssertEqual(result.entries.count, expected[0], "row count")
        XCTAssertEqual(Int(result.cursor), expected[1], "cursor is the highest row id")
        XCTAssertEqual(totals.input, expected[2], "input net of both cache classes")
        XCTAssertEqual(totals.output, expected[3], "output, with no reasoning added in")
        XCTAssertEqual(totals.cacheWrite, expected[4])
        XCTAssertEqual(totals.cacheRead, expected[5])

        // Every model the CLI has actually used must resolve in the pricing
        // table, or its usage silently earns at the unknown-model floor.
        for model in byModel.keys {
            XCTAssertNotNil(
                ModelPricing().rate(for: model),
                "\(model) is in use through Copilot CLI but has no bundled rate")
        }

        // Rescanning from the returned cursor must not surface anything already
        // credited, which is the property the whole no-keep-max decision rests
        // on. Compared by id set, not by ordering: these ids sort
        // lexicographically, so "copilot|9" would look larger than
        // "copilot|108".
        let credited = Set(result.entries.map(\.id))
        let rescan = CopilotUsageParser.scan(databaseURL: database, cursor: result.cursor)
        XCTAssertTrue(
            rescan.entries.allSatisfy { !credited.contains($0.id) },
            "a rescan may only surface rows written since, never one already credited")
    }

    /// **Every live entry knows where it came from**, across all three sources.
    ///
    /// The reason this is a corpus test and not a fixture test: the claim being
    /// checked is about the *shape of the real logs*, that Claude Code writes
    /// `cwd` on every usage line, that Codex writes it on `turn_context` before
    /// any `token_count`, and that Copilot keeps it on the session row. A fixture
    /// would only prove the parsers read what I wrote into them.
    func testEveryLiveEntryCarriesItsProject() throws {
        try skipUnlessEnabled()

        let result = UsageScanner().scan()
        var byProject: [String: Int] = [:]
        var unattributed: [UsageSource: Int] = [:]
        for entry in result.entries {
            if let project = entry.project {
                byProject[Project.displayName(project), default: 0] += 1
            } else {
                unattributed[entry.source, default: 0] += 1
            }
        }

        print("projects: \(byProject.sorted { $0.value > $1.value }.prefix(20))")
        print("unattributed: \(unattributed)")

        XCTAssertFalse(byProject.isEmpty)
        XCTAssertTrue(
            unattributed.isEmpty,
            "every turn in the live corpus should name its working directory")
        XCTAssertTrue(
            byProject.keys.contains("PokeBar"),
            "this project's own turns should be attributed to it")
        XCTAssertFalse(
            byProject.keys.contains { $0.hasPrefix("-Users-") },
            "a name that still looks encoded means the path was never read")
    }

    /// **The two day tables agree, on the real corpus.**
    ///
    /// The Usage pane shows one day cut two ways, by model and by project, and
    /// each project's percentage is a fraction of the figure the *model* side
    /// totals. If the two tables can disagree about a day, every percentage in
    /// the project section is quietly wrong and nothing on screen says so.
    ///
    /// A corpus test rather than a fixture one because the interesting input is
    /// the mix: three sources, a month of local days, and turns rewritten
    /// mid-stream, all of which a fixture would have to imagine.
    func testTheLiveCorpusSplitsEachDayTheSameTwoWays() throws {
        try skipUnlessEnabled()

        var ledger = UsageLedger()
        ledger.credit(UsageScanner().scan().entries, pricing: ModelPricing())

        XCTAssertFalse(ledger.dailyByProject.isEmpty)
        for day in ledger.daily.keys.sorted() {
            let byModel = ledger.tokens(forDay: day).total
            let byProject = ledger.projects(forDay: day).values.reduce(0) { $0 + $1.total }
            XCTAssertEqual(byProject, byModel, "day \(day) does not add up")
        }

        // And the rows the pane would actually draw for the busiest day.
        let busiest = try XCTUnwrap(
            ledger.daily.keys.max { ledger.tokens(forDay: $0).total < ledger.tokens(forDay: $1).total })
        let rows = ProjectBreakdown.rows(
            from: ledger.projects(forDay: busiest),
            dayTotal: ledger.tokens(forDay: busiest).total)
        print("busiest day \(busiest): \(rows.map { "\($0.name) \($0.tokens)" })")

        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
        XCTAssertFalse(
            rows.contains { $0.key == ProjectBreakdown.beforeTrackingKey },
            "a ledger built in one pass has no pre-tracking gap: every day is whole")
        XCTAssertEqual(
            Set(rows.map(\.name)).count, rows.count,
            "two rows reading the same name would look like one project counted twice")
    }

    /// **The live save, decoded through the roster migration.**
    ///
    /// The only save that actually matters is the one on this disk, and no
    /// fixture can stand in for it: a fixture proves the code handles the shape
    /// I *expected*, and this proves it handles the file the app will read on its
    /// next launch. Same reason the Copilot parity test exists.
    ///
    /// Read-only, and the app's own `SaveBackup` has already copied this file
    /// aside, so there is nothing here that can cost the collection.
    func testTheLiveSaveMigratesIntoTheRoster() throws {
        try XCTSkipUnless(enabled, "set POKEBAR_CORPUS=1 to read the live save")
        // Built by hand rather than through `GameMonitor.defaultStateURL()`,
        // which is `@MainActor` and would drag this whole test onto the main
        // actor for a string.
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBar/game-state.json")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path), "no save at \(url.path)")

        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trainer = try JSONDecoder().decode(Trainer.self, from: data)

        if let legacy = raw["active"] as? [String: Any], raw["roster"] == nil {
            let individual = try XCTUnwrap(trainer.roster.first, "the legacy key was dropped")
            XCTAssertEqual(trainer.roster.count, 1)
            XCTAssertEqual(trainer.team, [individual.id], "and it is training, not benched")
            XCTAssertEqual(individual.id.uuidString, legacy["id"] as? String)
            XCTAssertEqual(individual.totalXP, legacy["totalXP"] as? Double)
            XCTAssertEqual(individual.entryID, legacy["entryID"] as? Int)
            print(
                "live save: migrated #\(individual.entryID) at level \(individual.level), "
                    + "\(individual.totalXP) XP, into team slot 1")
        } else {
            print("live save: already on the roster shape, \(trainer.roster.count) individual(s)")
        }

        // Round trips: what this build writes back, this build reads identically.
        let rewritten = try JSONEncoder().encode(trainer)
        XCTAssertEqual(try JSONDecoder().decode(Trainer.self, from: rewritten), trainer)
        let rewrittenRaw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        XCTAssertNil(rewrittenRaw["active"], "the legacy key is read, never written")
    }

    /// One value out of `sqlite3`, so the reference figures are computed by
    /// something other than the code under test.
    private func sqlQuery(_ database: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Read-only, so a live Copilot CLI session is never disturbed by a test.
        process.arguments = ["file:\(database.path)?mode=ro", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "reference query must succeed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
