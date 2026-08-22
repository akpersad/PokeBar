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
    private(set) var lastUpdated: Date?

    /// True when some model in the totals has no known price, so the cost shown
    /// is a floor. Upstream reported $0.00 for unpriced models with no signal at
    /// all, which is how a brand new model reads as free.
    private(set) var costIsIncomplete = false

    // MARK: Dependencies

    private let scanner: UsageScanner
    private let catalog: PricingCatalog
    private let stateURL: URL
    private let calendar: Calendar

    private var ledger = UsageLedger()
    private var cursors: [String: FileCursor] = [:]
    private var pricing = ModelPricing()
    private var loop: Task<Void, Never>?

    init(
        scanner: UsageScanner = UsageScanner(),
        catalog: PricingCatalog = PricingCatalog(),
        stateURL: URL = UsageMonitor.defaultStateURL(),
        calendar: Calendar = .current
    ) {
        self.scanner = scanner
        self.catalog = catalog
        self.stateURL = stateURL
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
        let changes = DirectoryWatcher.changes(in: scanner.roots)
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
        // Off the main actor: a cold pass parses hundreds of megabytes.
        let result = await Task.detached(priority: .utility) {
            scanner.scan(cursors: cursors)
        }.value

        self.cursors = result.cursors
        let added = ledger.credit(result.entries, pricing: pricing)
        publish()

        if added.total > 0 || !result.entries.isEmpty {
            lastUpdated = Date()
            persist()
        }
    }

    // MARK: Derived values

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

        var incomplete = false
        todayCostUSD = Self.cost(of: byModelToday, pricing: pricing, incomplete: &incomplete)
        allTimeCostUSD = Self.cost(of: allByModel, pricing: pricing, incomplete: &incomplete)
        costIsIncomplete = incomplete
    }

    private static func cost(
        of byModel: [String: TokenCounts], pricing: ModelPricing, incomplete: inout Bool
    ) -> Double {
        var total = 0.0
        for (model, tokens) in byModel {
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
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        ledger = decoded.ledger
        cursors = decoded.cursors
    }

    private func persist() {
        let snapshot = PersistedState(ledger: ledger, cursors: cursors)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Atomic so a crash mid-write cannot leave a truncated ledger, which
        // would silently reset earned currency.
        try? data.write(to: stateURL, options: .atomic)
    }
}
