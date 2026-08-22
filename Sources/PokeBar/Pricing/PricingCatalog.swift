import Foundation

/// Resolves model rates, preferring a cached runtime snapshot over the bundled
/// table, and refreshing that snapshot in the background.
///
/// The point is that a model launched after this binary was built still gets
/// priced. The upstream project required a source-code commit per model, which
/// is how `claude-opus-5` came to be worth $0.00 there.
actor PricingCatalog {

    /// Community-maintained snapshot. Verified 2026-08-22 to agree exactly with
    /// the Anthropic pricing reference on every model this machine uses.
    static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/"
            + "model_prices_and_context_window.json")!

    /// Refresh cadence. Model launches are the trigger and they are not frequent;
    /// a stale-by-a-week rate is harmless because the bundled table backs it.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    struct Snapshot: Sendable, Codable {
        var fetchedAt: Date
        var rates: [String: ModelRate]
    }

    private var pricing: ModelPricing
    private var snapshot: Snapshot?
    private let cacheURL: URL

    init(cacheURL: URL = PricingCatalog.defaultCacheURL()) {
        self.cacheURL = cacheURL
        // Bundled first so pricing is never unavailable, even offline on a
        // machine that has never completed a refresh.
        self.pricing = ModelPricing()
        if let cached = Self.loadCache(at: cacheURL) {
            self.snapshot = cached
            self.pricing = ModelPricing(
                table: ModelPricing.bundled.merging(cached.rates) { _, fetched in fetched })
        }
    }

    static func defaultCacheURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-pricing.json")
    }

    /// Current resolver. Safe to call before any refresh has happened.
    func current() -> ModelPricing { pricing }

    var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > Self.refreshInterval
    }

    /// Fetch and merge, if the cache is stale. Failure is not an error: the
    /// bundled table plus whatever was last cached remains in effect.
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Bool {
        guard force || isStale else { return false }
        guard let fetched = await Self.fetch() else { return false }

        let merged = Snapshot(fetchedAt: Date(), rates: fetched)
        snapshot = merged
        pricing = ModelPricing(
            table: ModelPricing.bundled.merging(fetched) { _, new in new })
        Self.writeCache(merged, to: cacheURL)
        return true
    }

    // MARK: - Fetch and parse

    private static func fetch() async -> [String: ModelRate]? {
        var request = URLRequest(url: sourceURL, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(data)
    }

    /// Extracts bare `claude-*` keys only.
    ///
    /// The source carries provider-prefixed and regional duplicates — ten for
    /// `claude-opus-5` alone, including `au.anthropic.claude-opus-5` at a 10%
    /// markup and `azure_ai/` / `vertex_ai/` / `openrouter/` forms. Claude Code
    /// writes the bare id, so anything containing a `.` or `/` is discarded
    /// rather than risking a marked-up regional rate.
    static func parse(_ data: Data) -> [String: ModelRate]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: ModelRate] = [:]
        for (key, value) in root {
            guard key.hasPrefix("claude-"),
                  !key.contains("."), !key.contains("/"),
                  let entry = value as? [String: Any],
                  let input = entry["input_cost_per_token"] as? Double,
                  let output = entry["output_cost_per_token"] as? Double,
                  input > 0, output > 0
            else { continue }

            // Cache fields are occasionally absent. Every current Claude model
            // prices cache write at 1.25x input and cache read at 0.1x input, so
            // that ratio is the fallback — applied only per-missing-field, never
            // in place of a published number.
            let cacheWrite = entry["cache_creation_input_token_cost"] as? Double ?? input * 1.25
            let cacheRead = entry["cache_read_input_token_cost"] as? Double ?? input * 0.1

            out[key] = ModelRate(
                input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Disk cache

    private static func loadCache(at url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func writeCache(_ snapshot: Snapshot, to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
