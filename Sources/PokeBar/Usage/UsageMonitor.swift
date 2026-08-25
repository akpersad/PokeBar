import Foundation
import Observation

/// Everything the UI binds to, and the only place the pieces are wired together:
/// cold scan, then filesystem watch, crediting each result into a durable ledger.
///
/// Deliberately a single `@MainActor` observable object rather than the upstream
/// arrangement of a `Timer`, several stores, and three hand-rolled generation
/// counters (`activeGeneration`, `menuLoadGen`, `customScanMatchGeneration`) to
/// guard against async races. One actor and one sequential loop removes that
/// whole class of bug instead of patching instances of it.
@MainActor
@Observable
final class UsageMonitor {

    enum State: Equatable {
        case idle
        /// First scan of a launch. Cold cost is ~17s for 481 MiB; warm relaunches
        /// read almost nothing because cursors persist.
        case scanning
        /// Watching. Costs nothing while the tree is quiet.
        case watching
        case failed(String)
    }

    // MARK: Published state

    private(set) var state: State = .idle
    private(set) var todayTokens: TokenCounts = .zero
    private(set) var todayCostUSD: Double = 0
    private(set) var allTimeTokens: TokenCounts = .zero
    private(set) var allTimeCostUSD: Double = 0
    private(set) var byModelToday: [String: TokenCounts] = [:]
    private(set) var coins: Int = 0
    /// Today's tier-weighted tokens. Display only, and recomputed at publish
    /// time from current pricing, which is why it is not the ledger's frozen
    /// figure: it feeds a "how long until the next level" projection, and a
    /// projection should track today's rates.
    private(set) var todayWeightedTokens: Double = 0
    private(set) var lastUpdated: Date?

    /// True when some model in the totals has no known price, so the cost shown
    /// is a floor. Upstream reported $0.00 for unpriced models with no signal at
    /// all, which is how a brand new model reads as free.
    private(set) var costIsIncomplete = false

    // MARK: Dependencies

    /// The game half, set once at app start. Weak and unobserved: this is a
    /// one-way hand-off of credited tokens, not a thing the usage UI reads.
    ///
    /// The direction matters. Coins are minted here and frozen; XP is derived
    /// from the *same* weighted tokens on the other side, never from a share of
    /// a pool, so there is no allocation to negotiate between the two.
    @ObservationIgnored weak var game: GameMonitor?

    private let scanner: UsageScanner
    private let catalog: PricingCatalog
    private let stateURL: URL
    private let calendar: Calendar

    private var ledger = UsageLedger()
    private var cursors: [String: FileCursor] = [:]
    /// Highest Copilot CLI `assistant_usage_events.id` already credited. An
    /// `Int64` cursor rather than a byte offset, matching invariant 24's
    /// reasoning in reverse: here the source itself guarantees a stable,
    /// monotonic id, so there is no positional-fallback trap to guard against.
    private var copilotCursor: Int64 = 0
    private var pricing = ModelPricing()
    private var loop: Task<Void, Never>?
    private let copilotDatabaseURL: URL

    init(
        scanner: UsageScanner = UsageScanner(),
        catalog: PricingCatalog = PricingCatalog(),
        stateURL: URL = UsageMonitor.defaultStateURL(),
        copilotDatabaseURL: URL = CopilotUsageParser.defaultDatabaseURL(),
        calendar: Calendar = .current
    ) {
        self.scanner = scanner
        self.catalog = catalog
        self.stateURL = stateURL
        self.copilotDatabaseURL = copilotDatabaseURL
        self.calendar = calendar
    }

    static func defaultStateURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-state.json")
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        persist()
    }

    private func run() async {
        load()
        // Publish restored totals before scanning so a relaunch shows real
        // numbers immediately rather than zeros.
        publish()

        state = .scanning
        await refreshPricing()

        // Arm the watcher *before* the cold scan, not after.
        //
        // The cold pass takes ~17s over 481 MiB. If the stream were created
        // afterwards, any turn completing during those seconds would write its
        // bytes with nobody listening, and would not surface until some later,
        // unrelated write happened to fire an event. Arming first means such a
        // change is buffered by the AsyncStream and drained immediately below.
        // Draining a few redundant ticks is free: cursors make a no-op pass read
        // zero bytes.
        //
        // The Copilot database's containing directory is watched too, so a
        // WAL write there ticks the same stream. It is not one of `scanner.roots`:
        // that scanner only ever walks for `*.jsonl`, and folding a SQLite tree
        // into it would just be dead enumeration.
        let watchedRoots = scanner.roots + [copilotDatabaseURL.deletingLastPathComponent()]
        let changes = DirectoryWatcher.changes(in: watchedRoots)
        await scanAndCredit()

        state = .watching
        for await _ in changes {
            if Task.isCancelled { break }
            await scanAndCredit()
        }
        state = .idle
    }

    /// Best-effort. A failed refresh leaves the bundled table plus whatever was
    /// last cached in effect, so pricing is never unavailable.
    private func refreshPricing() async {
        await catalog.refreshIfNeeded()
        pricing = await catalog.current()
    }

    private func scanAndCredit() async {
        let scanner = self.scanner
        let cursors = self.cursors
        let copilotDatabaseURL = self.copilotDatabaseURL
        let copilotCursor = self.copilotCursor
        // Off the main actor: a cold pass parses hundreds of megabytes.
        let (result, copilotResult) = await Task.detached(priority: .utility) {
            (
                scanner.scan(cursors: cursors),
                CopilotUsageParser.scan(databaseURL: copilotDatabaseURL, cursor: copilotCursor)
            )
        }.value

        self.cursors = result.cursors
        self.copilotCursor = copilotResult.cursor
        let entries = result.entries + copilotResult.entries
        // The weighted delta, read across the credit rather than returned by it.
        // `credit` already reports the raw tokens added; XP needs the tier-
        // weighted figure, which is the one coins are minted from, and taking it
        // this way leaves the ledger's signature and its tests alone.
        let weightedBefore = ledger.weightedTokens
        let projectsBefore = ledger.weightedByProject
        let added = ledger.credit(entries, pricing: pricing)
        let weightedAdded = ledger.weightedTokens - weightedBefore
        // The per-project split of that same delta, taken the same way and for
        // the same reason. Diffing the ledger rather than summing `entries`
        // matters: the ledger credits *growth* on a turn it has seen before, so
        // summing the entries here would attribute a rewritten turn's whole
        // total to its project on every scan.
        var addedByProject: [String: Double] = [:]
        for (project, total) in ledger.weightedByProject {
            let delta = total - (projectsBefore[project] ?? 0)
            if delta > 0 { addedByProject[project] = delta }
        }
        publish()
        game?.credit(
            weightedTokens: weightedAdded, byProject: addedByProject, coinsEarned: ledger.coins)

        if added.total > 0 || !entries.isEmpty {
            lastUpdated = Date()
            persist()
        }
    }

    // MARK: Derived values

    /// Re-derives the published values from the ledger without touching the disk.
    ///
    /// The UI calls this when the menu bar window opens. Needed because
    /// `todayTokens` is bucketed by local day *at publish time*: if the tree stays
    /// quiet across midnight, nothing republishes and the popover keeps labelling
    /// yesterday's usage "Today". Free to call, and it credits nothing, so it
    /// cannot disturb earned currency.
    func refreshDisplayedTotals() { publish() }


    /// Recomputes displayed values from the ledger.
    ///
    /// Note the asymmetry, and it is intentional: **cost** is recomputed from
    /// current pricing every time (it is an informational estimate, so it should
    /// track today's rates), while **coins** are read straight off the ledger's
    /// frozen total and never re-derived. Recomputing currency would let a price
    /// change take earned coins away.
    private func publish() {
        let today = ClaudeUsageParser.localDayKey(Date(), calendar: calendar)
        byModelToday = ledger.totals(forDay: today)
        todayTokens = ledger.tokens(forDay: today)

        let allByModel = ledger.allTimeByModel()
        allTimeTokens = allByModel.values.reduce(into: .zero) { $0 += $1 }
        coins = ledger.coins

        todayWeightedTokens = byModelToday.reduce(into: 0.0) { total, pair in
            let model = UsageSource.model(fromLedgerKey: pair.key)
            let multiplier = pricing.tierMultiplier(for: model)
                ?? ModelPricing.unknownModelTierMultiplier
            total += Double(pair.value.total) * multiplier
        }

        // Push the restored balance before the first scan, so a relaunch can
        // spend coins immediately rather than waiting for a turn to finish.
        game?.coinsEarned = coins

        var incomplete = false
        todayCostUSD = Self.cost(of: byModelToday, pricing: pricing, incomplete: &incomplete)
        allTimeCostUSD = Self.cost(of: allByModel, pricing: pricing, incomplete: &incomplete)
        costIsIncomplete = incomplete
    }

    private static func cost(
        of byModel: [String: TokenCounts], pricing: ModelPricing, incomplete: inout Bool
    ) -> Double {
        var total = 0.0
        for (key, tokens) in byModel {
            // `key` may carry the Copilot ledger marker; pricing is keyed on
            // the real, unprefixed model id (invariant 4).
            let model = UsageSource.model(fromLedgerKey: key)
            if let rate = pricing.rate(for: model) {
                total += rate.costUSD(for: tokens)
            } else if tokens.total > 0 {
                incomplete = true
            }
        }
        return total
    }

    // MARK: Persistence

    struct PersistedState: Codable {
        var ledger: UsageLedger
        var cursors: [String: FileCursor]
        var copilotCursor: Int64 = 0
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        ledger = decoded.ledger
        cursors = decoded.cursors
        copilotCursor = decoded.copilotCursor
    }

    private func persist() {
        let snapshot = PersistedState(ledger: ledger, cursors: cursors, copilotCursor: copilotCursor)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Atomic so a crash mid-write cannot leave a truncated ledger, which
        // would silently reset earned currency.
        try? data.write(to: stateURL, options: .atomic)
    }
}

/// `copilotCursor` decodes with `decodeIfPresent` and a default, per invariant
/// 23: a state file written before Copilot support existed has no such key, and
/// the synthesized decoder throws on a missing key even where the property has a
/// default. `load()` cannot tell "unreadable" from "no state yet", so that throw
/// would silently restart the ledger, and the earned coin balance, from zero.
///
/// In an extension rather than in the type on purpose: declaring `init(from:)`
/// inside the struct suppresses the memberwise initialiser `persist()` uses, and
/// hand-writing that back is two more places for a new field to be forgotten.
extension UsageMonitor.PersistedState {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ledger = try container.decode(UsageLedger.self, forKey: .ledger)
        cursors = try container.decode([String: FileCursor].self, forKey: .cursors)
        copilotCursor = try container.decodeIfPresent(Int64.self, forKey: .copilotCursor) ?? 0
    }
}
