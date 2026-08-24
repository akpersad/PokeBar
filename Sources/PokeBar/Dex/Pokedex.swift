import Foundation

/// The collectible catalog: 1,083 entries, loaded from the bundled manifest.
///
/// The manifest is generated at build time by `scripts/generate-dex.py` and
/// checked in, rather than fetched from PokeAPI at runtime. See DECISIONS.md for
/// the reasoning; the short version is that a cold first launch needs no network
/// and no third-party service to be up, and the generator can assert the
/// invariants (1,083 entries, 58 regionals, 14 static-only) where a runtime
/// fetch could only hope for them.
struct Pokedex: Sendable {

    /// Sprite host. Every URL is pinned to `spritesCommit`, so a fetched file is
    /// immutable and a cached one never needs revalidating.
    static let spriteHost = "https://raw.githubusercontent.com/PokeAPI/sprites"

    let spritesCommit: String
    let entries: [DexEntry]

    private let byID: [Int: DexEntry]
    private let bySlug: [String: DexEntry]
    private let gatedIDs: Set<Int>

    init(manifest: DexManifest) {
        self.spritesCommit = manifest.spritesCommit
        self.entries = manifest.entries
        self.byID = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        self.bySlug = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.slug, $0) })
        self.gatedIDs = Set(manifest.entries.flatMap(\.evolvesTo))
    }

    // MARK: - Loading

    enum LoadError: Error, CustomStringConvertible {
        case resourceMissing
        case undecodable(any Error)

        var description: String {
            switch self {
            case .resourceMissing:
                return """
                    pokedex.json is not in the bundle. Either scripts/generate-dex.py has \
                    never been run, or the SwiftPM resource bundle was not copied next to \
                    the executable (see scripts/bundle.sh).
                    """
            case .undecodable(let error):
                return "pokedex.json did not decode: \(error)"
            }
        }
    }

    /// Loads the bundled manifest.
    ///
    /// Throwing rather than returning an empty dex on failure, and a test asserts
    /// this succeeds. A silently empty catalog is precisely the failure mode that
    /// cost this project a debugging round with the invisible menu bar item: the
    /// app looks healthy and simply never shows a Pokemon.
    static func loadBundled() throws -> Pokedex {
        guard let url = Bundle.module.url(forResource: "pokedex", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        do {
            let data = try Data(contentsOf: url)
            return Pokedex(manifest: try JSONDecoder().decode(DexManifest.self, from: data))
        } catch {
            throw LoadError.undecodable(error)
        }
    }

    // MARK: - Lookup

    var count: Int { entries.count }

    func entry(id: Int) -> DexEntry? { byID[id] }
    func entry(slug: String) -> DexEntry? { bySlug[slug] }

    /// Base species only, excluding the 58 regional forms.
    var baseSpecies: [DexEntry] { entries.filter { !$0.isRegionalForm } }

    var regionalForms: [DexEntry] { entries.filter(\.isRegionalForm) }

    /// Entries with no incoming evolution edge: what an egg can produce.
    ///
    /// 570 of 1,083. The other 513 are reachable only by evolving something, so
    /// they must never enter the hatch pool or the evolution half of the game has
    /// nothing left to give. This is derived rather than flagged per entry,
    /// because "gated" is a property of the edge set and a stored flag could
    /// disagree with it.
    var hatchable: [DexEntry] { entries.filter { !gatedIDs.contains($0.id) } }

    /// Whether `entry` can only be obtained by evolving something else.
    func isEvolutionGated(_ entry: DexEntry) -> Bool { gatedIDs.contains(entry.id) }

    /// What `entry` evolves into, resolved through the pool.
    ///
    /// Regional evolution stays in-region without a hardcoded exception table,
    /// because the manifest recorded `evolved_form_id ?? evolved_species_id`:
    /// Alolan Vulpix resolves to Alolan Ninetales via a form target, Galarian
    /// Meowth to Perrserker via a species target.
    func evolutions(of entry: DexEntry) -> [DexEntry] {
        entry.evolvesTo.compactMap { byID[$0] }
    }

    /// The edges an individual at `level` holding `items` could take right now,
    /// paired with what they lead to.
    ///
    /// Returns every satisfied edge rather than picking one, because branching is
    /// real: Eevee at level 1 holding a Water Stone and a Fire Stone has two
    /// legitimate answers and choosing between them is the player's.
    func availableEvolutions(
        of entry: DexEntry, atLevel level: Int, items: Set<String> = []
    ) -> [(edge: Evolution, target: DexEntry)] {
        entry.evolutions.compactMap { edge in
            guard edge.isAvailable(atLevel: level, items: items),
                  let target = byID[edge.to] else { return nil }
            return (edge, target)
        }
    }

    // MARK: - Sprite URLs

    /// Remote URL for an entry's sprite, pinned to the manifest's commit.
    ///
    /// Falls back to a variant the entry actually has. Two entries in the pool
    /// have no shiny and 981 have no distinct female sprite, and a missing
    /// variant must render as the ordinary Pokemon rather than as a blank tile.
    func spriteURL(for entry: DexEntry, variant: SpriteVariant = .normal) -> URL {
        let set = entry.spriteSet
        let path = "\(Self.spriteHost)/\(spritesCommit)/sprites/pokemon/\(set.directory)"
            + entry.resolve(variant).pathSuffix
            + "/\(entry.id).\(set.fileExtension)"
        // Every component is either a fixed literal, a hex commit from the
        // manifest, or an integer id, so this cannot fail to parse.
        return URL(string: path)!
    }

    /// Stable cache filename for an entry's sprite.
    ///
    /// Includes the sprite set because an entry's set could change when the
    /// manifest is regenerated, and a stale file under a reused name would render
    /// the wrong art forever.
    func cacheKey(for entry: DexEntry, variant: SpriteVariant = .normal) -> String {
        let set = entry.spriteSet
        return "\(entry.id)-\(set.rawValue)\(entry.resolve(variant).keySuffix)"
            + ".\(set.fileExtension)"
    }

    // MARK: - Featured pick

    /// A deterministic entry for the given day, used by the menu bar until the
    /// game layer has an opinion.
    ///
    /// Phase 4 replaces this with the player's active or most recently hatched
    /// Pokemon. It exists so the status item shows real dex data driven through
    /// the real sprite cache, rather than a placeholder glyph. Seeded on the local
    /// day so it is stable across relaunches within a day and changes overnight,
    /// which matches how the usage totals already bucket (DECISIONS.md).
    func featured(on date: Date = Date(), calendar: Calendar = .current) -> DexEntry? {
        guard !entries.isEmpty else { return nil }
        let day = calendar.startOfDay(for: date)
        let ordinal = Int(day.timeIntervalSince1970 / 86_400)
        // Multiply by a large odd constant before reducing so consecutive days
        // land far apart in the list instead of walking the dex in order.
        let index = (ordinal &* 2_654_435_761) %% entries.count
        return entries[index]
    }
}

/// Non-negative modulo. Swift's `%` keeps the sign of the dividend, so a negative
/// hash would index out of bounds.
infix operator %%: MultiplicationPrecedence
func %% (lhs: Int, rhs: Int) -> Int {
    let r = lhs % rhs
    return r < 0 ? r + rhs : r
}
