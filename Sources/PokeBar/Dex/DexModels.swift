import Foundation

/// Which of the three sprite sets an entry's art comes from.
///
/// Resolution order is gen5 -> showdown -> home, decided at manifest-generation
/// time and recorded per entry so the app never probes for a 404. Prefers
/// authentic Black/White pixel art where it exists, falls back to Showdown's
/// unified animated set, then to static HOME renders for the last 14. Measured:
/// 816 entries via gen5, 253 via showdown, 14 via home.
enum SpriteSet: String, Codable, Sendable, CaseIterable {
    case gen5
    case showdown
    case home

    /// Only `home` is a still image. 1,069 of 1,083 entries animate.
    var isAnimated: Bool { self != .home }

    /// Path segment under `sprites/pokemon/`, without the filename.
    var directory: String {
        switch self {
        case .gen5: "versions/generation-v/black-white/animated"
        case .showdown: "other/showdown"
        case .home: "other/home"
        }
    }

    /// Derived from the set, deliberately, rather than carried per entry in the
    /// manifest. One source of truth: an entry cannot claim `home` and `.gif`.
    var fileExtension: String { self == .home ? "png" : "gif" }
}

/// An individual's sex.
///
/// Recorded on every catch event because in an append-only log it costs nothing
/// and it keeps "I hatched a female Bulbasaur" answerable. It does **not** create
/// a collection slot on its own: only the 102 entries with a distinct female
/// sprite do that (DECISIONS.md).
enum Gender: String, Codable, Sendable, CaseIterable {
    case male
    case female
    case genderless

    var label: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .genderless: "Unknown"
        }
    }

    /// The sprite variant this gender should show for `entry`. Female only picks
    /// the female sprite where one exists, which is the whole point of the rule.
    func spriteVariant(shiny: Bool, for entry: DexEntry) -> SpriteVariant {
        SpriteVariant(shiny: shiny, female: self == .female && entry.female)
    }
}

/// Which of an entry's up to four sprites is meant.
///
/// A variant is ownable **if and only if its sprite file exists**, which is the
/// same data-driven rule sprite-set resolution already follows, and it matters
/// because the obvious model is wrong: the pool is not 1,083 x 4. Only 102
/// entries look different by gender and two have no shiny at all, so completion
/// is defined over **2,368 distinct sprites**. Treating male and female as slots
/// everywhere would show the identical image twice for 90% of the dex and inflate
/// the target with tiles nobody can tell apart. See DECISIONS.md.
struct SpriteVariant: Codable, Sendable, Hashable {
    var shiny: Bool
    var female: Bool

    init(shiny: Bool = false, female: Bool = false) {
        self.shiny = shiny
        self.female = female
    }

    static let normal = SpriteVariant()
    static let shiny = SpriteVariant(shiny: true)
    static let female = SpriteVariant(female: true)
    static let shinyFemale = SpriteVariant(shiny: true, female: true)

    /// Path suffix under the set's directory. Order matters: the sprites repo
    /// nests female inside shiny, not the reverse.
    var pathSuffix: String {
        (shiny ? "/shiny" : "") + (female ? "/female" : "")
    }

    /// Cache-key suffix. Empty for the plain sprite so the common case stays
    /// `1-gen5.gif`.
    var keySuffix: String {
        (shiny ? "-shiny" : "") + (female ? "-female" : "")
    }
}

/// Display rarity band, derived at generation time from the species'
/// `capture_rate`.
///
/// This is a *label*, not a weighting axis. `capture_rate` is quantized hard
/// (327 of 1,083 entries share the value 45, and 86% sit at 45 or above), so any
/// set of bands puts a ~30-45% lump in whichever band contains 45. Phase 4 should
/// weight the hatch pool on `DexEntry.captureRate` directly, where the raw number
/// behaves like a smooth weight, and use this only for the word shown to the
/// player. See DECISIONS.md.
enum Rarity: String, Codable, Sendable, CaseIterable {
    case common
    case uncommon
    case rare
    case epic
    case legendary
    case mythical

    /// User-facing word. Capitalised here rather than at each call site so the
    /// popover and the dex cannot disagree.
    var label: String {
        switch self {
        case .common: "Common"
        case .uncommon: "Uncommon"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        case .mythical: "Mythical"
        }
    }
}

/// What makes an evolution fire.
///
/// Four cases, resolved at manifest-generation time so the app compares a level
/// and checks an item and never has to know what a tower of darkness is. Two of
/// them are honest labels rather than mechanics: `substituted` marks the 54 edges
/// whose real trigger (friendship, time of day, spin, three critical hits) cannot
/// be modelled by a token counter, and `trade` marks the 26 that a single-player
/// menu bar app cannot offer. See DECISIONS.md.
enum EvolutionTrigger: String, Codable, Sendable, CaseIterable {
    /// The games' own `min_level`. 364 edges, levels 7 to 64, median 30.
    case level
    /// An evolution stone or equivalent. 69 edges across 23 distinct items.
    case item
    /// Trade in the games, a Linking Cord here, canonical since Gen 9. 26 edges.
    case trade
    /// Unmodellable, so it happens at the substitution level. 54 edges.
    case substituted

    /// Whether this edge is a substitution rather than something the games do.
    /// Surfaced to the player, because a dex that quietly invents rules is worse
    /// than one that says which rules it had to invent.
    var isSubstituted: Bool { self == .substituted || self == .trade }
}

/// One evolution edge: what an entry turns into, and what that costs.
///
/// `minLevel` is always a real number, never nil, which is the point of resolving
/// this at generation time. An item edge carries level 1 because a Fire Stone
/// works on a level 1 Vulpix in the games too: the item is the gate, not the
/// level.
struct Evolution: Codable, Sendable, Hashable {
    /// Target `DexEntry.id`. Always in the pool; a test asserts it.
    let to: Int
    let trigger: EvolutionTrigger
    let minLevel: Int
    /// Item slug, e.g. `thunder-stone`, or nil when the edge needs no item.
    let item: String?
    /// Display name for `item`, e.g. "Thunder Stone".
    let itemName: String?

    /// Whether an individual at `level` holding `items` can take this edge.
    ///
    /// Both conditions, always. An item edge whose item is missing is not
    /// silently a level edge.
    func isAvailable(atLevel level: Int, items: Set<String>) -> Bool {
        guard level >= minLevel else { return false }
        guard let item else { return true }
        return items.contains(item)
    }
}

/// A collectible. One per base species plus one per regional form: 1,083 total.
///
/// `id` is PokeAPI's `pokemon.id`, which is the National Dex number for base
/// species (1...1025) and a synthetic id at or above 10000 for forms. `speciesID`
/// is the species the entry belongs to, and is where rarity comes from, so a
/// regional form inherits its rarity for free: Alolan Vulpix reports species 37
/// and capture rate 190, exactly like Vulpix, and is exactly as common.
struct DexEntry: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let speciesID: Int
    /// PokeAPI slug, e.g. `vulpix-alola`. Stable, and the cache key's basis.
    let slug: String
    /// User-facing name, e.g. "Alolan Vulpix". Taken from PokeAPI's English
    /// species name at generation time rather than title-cased off the slug,
    /// because title-casing gets `farfetchd`, `mr-mime` and `nidoran-f` wrong.
    let name: String
    /// `alola`, `galar`, `hisui`, `paldea`, or nil for a base species.
    let region: String?
    let generation: Int
    let captureRate: Int
    /// Eighths female, PokeAPI's `gender_rate`: -1 genderless, 0 male-only,
    /// 8 female-only, 4 the even split most species have. Recorded because a
    /// catch event records gender, and rolling one without this hands a
    /// Magnemite a sex it does not have. Measured over the 1,025 species:
    /// 155 genderless, 26 male-only, 37 female-only, 630 even.
    let genderRate: Int
    let legendary: Bool
    let mythical: Bool
    let spriteSet: SpriteSet
    /// Whether this entry has a shiny sprite in its resolved set. True for 1,081
    /// of 1,083, so the two exceptions must not render as a blank tile.
    let shiny: Bool
    /// Whether this entry has a *distinct* female sprite in its resolved set.
    /// True for 102 of 1,083. One flag covers both the female and shiny-female
    /// sprites, because no entry has one without the other, and the generator
    /// fails rather than guessing if that ever stops being true.
    let female: Bool
    let animated: Bool
    let rarity: Rarity
    /// Outgoing evolution edges, deduped, restricted to targets that are
    /// themselves in the pool. Usually 0 or 1; Pikachu has two (Raichu and Alolan
    /// Raichu) and Eevee eight, which is real branching content that falls out of
    /// the data for free. 477 of 1,083 entries have at least one.
    let evolutions: [Evolution]

    var isRegionalForm: Bool { region != nil }

    var evolvesTo: [Int] { evolutions.map(\.to) }

    /// The sprites that actually exist for this entry, and therefore the slots a
    /// collection can fill. One, two or four; 979 entries have two.
    var ownableVariants: [SpriteVariant] {
        var out: [SpriteVariant] = [.normal]
        if shiny { out.append(.shiny) }
        if female {
            out.append(.female)
            if shiny { out.append(.shinyFemale) }
        }
        return out
    }

    /// Genders this entry can hatch as. One element for 218 entries, two for the
    /// rest.
    var possibleGenders: [Gender] {
        switch genderRate {
        case ..<0: [.genderless]
        case 0: [.male]
        case 8...: [.female]
        default: [.male, .female]
        }
    }

    /// Clamps a requested variant to one this entry has, so a missing shiny
    /// renders the ordinary Pokemon rather than a blank tile.
    func resolve(_ variant: SpriteVariant) -> SpriteVariant {
        SpriteVariant(shiny: variant.shiny && shiny, female: variant.female && female)
    }
}

/// The bundled manifest, as generated by `scripts/generate-dex.py`.
struct DexManifest: Codable, Sendable {
    let version: Int
    /// The sprites repo commit every sprite URL is pinned to.
    ///
    /// Load-bearing, not decorative. `raw.githubusercontent.com` serves sprites
    /// with `cache-control: max-age=300`, so a branch-tracking URL would have the
    /// disk cache revalidating every five minutes. Pinning a commit makes each
    /// URL immutable, which is what lets a cached sprite be trusted forever and
    /// read with no network at all.
    let spritesCommit: String
    let maxSpeciesID: Int
    let entries: [DexEntry]
}
