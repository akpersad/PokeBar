import XCTest
@testable import PokeBar

/// Pins the bundled manifest's shape.
///
/// These are the same assertions `scripts/generate-dex.py` makes before it writes,
/// repeated here on the decoded side. The generator catches the source data
/// drifting; this catches the manifest failing to reach the binary, decoding
/// wrong, or being regenerated with different content by accident.
final class PokedexTests: XCTestCase {

    private var dex: Pokedex!

    override func setUpWithError() throws {
        // Not XCTUnwrap on a `try?`: if the resource bundle is missing, the
        // thrown error explains which of the two causes it is, and that message
        // is the whole point of the error existing.
        dex = try Pokedex.loadBundled()
    }

    /// The failure this exists to catch is the silent one: SwiftPM emits the
    /// resources into PokeBar_PokeBar.bundle, and if that is not next to the
    /// binary then `Bundle.module` finds nothing, every lookup returns nil, and
    /// the app runs perfectly with no Pokemon in it. Exactly the shape of the
    /// invisible-menu-bar-item bug this project already paid for once.
    func testBundledManifestLoads() {
        XCTAssertFalse(dex.entries.isEmpty)
        XCTAssertFalse(dex.spritesCommit.isEmpty)
    }

    func testPoolIs1083() {
        XCTAssertEqual(dex.count, 1083)
        XCTAssertEqual(dex.baseSpecies.count, 1025)
        XCTAssertEqual(dex.regionalForms.count, 58)
    }

    func testEveryBaseSpeciesIDIsPresentExactlyOnce() {
        let base = Set(dex.baseSpecies.map(\.id))
        XCTAssertEqual(base.count, 1025)
        XCTAssertEqual(base.min(), 1)
        XCTAssertEqual(base.max(), 1025)
    }

    func testIDsAreUnique() {
        XCTAssertEqual(Set(dex.entries.map(\.id)).count, dex.count)
        XCTAssertEqual(Set(dex.entries.map(\.slug)).count, dex.count)
    }

    /// The 14 with no animated sprite in any set. Everything else animates, which
    /// is the 98.7% figure the three-set layering exists to buy.
    func testOnlyFourteenEntriesAreStatic() {
        let still = dex.entries.filter { !$0.animated }
        XCTAssertEqual(still.map(\.id).sorted(),
                       [990, 991, 992, 993, 994, 995, 1006, 1008, 1010, 1017, 1022, 1023, 1024, 1025])
        XCTAssertTrue(still.allSatisfy { $0.spriteSet == .home })
    }

    func testAnimatedFlagAgreesWithSpriteSet() {
        for entry in dex.entries {
            XCTAssertEqual(entry.animated, entry.spriteSet.isAnimated, "\(entry.slug)")
        }
    }

    // MARK: - Rarity inheritance

    /// A regional form inherits its species' rarity for free, because capture rate
    /// lives on the species rather than the variety. Alolan Vulpix is exactly as
    /// common as Vulpix, with no special-casing anywhere.
    func testRegionalFormInheritsSpeciesRarity() throws {
        let vulpix = try XCTUnwrap(dex.entry(slug: "vulpix"))
        let alolan = try XCTUnwrap(dex.entry(slug: "vulpix-alola"))
        XCTAssertEqual(alolan.speciesID, vulpix.id)
        XCTAssertEqual(alolan.captureRate, vulpix.captureRate)
        XCTAssertEqual(alolan.captureRate, 190)
        XCTAssertEqual(alolan.rarity, vulpix.rarity)
    }

    func testEveryRegionalFormMatchesItsSpeciesRarity() throws {
        for form in dex.regionalForms {
            let species = try XCTUnwrap(dex.entry(id: form.speciesID), form.slug)
            XCTAssertEqual(form.captureRate, species.captureRate, form.slug)
            XCTAssertEqual(form.rarity, species.rarity, form.slug)
        }
    }

    /// Legendary and mythical are a floor, not a band. Some legendaries have a
    /// capture rate that would otherwise place them in a common band, and a
    /// legendary labelled "Common" reads as a bug.
    func testLegendaryAndMythicalOverrideCaptureRate() {
        for entry in dex.entries where entry.mythical {
            XCTAssertEqual(entry.rarity, .mythical, entry.slug)
        }
        for entry in dex.entries where entry.legendary && !entry.mythical {
            XCTAssertEqual(entry.rarity, .legendary, entry.slug)
        }
    }

    // MARK: - Form selection

    /// The regional form that carries no regional suffix. A suffix-matching
    /// selector finds 57 of the 58 and silently drops this one.
    func testHisuianBasculinIsCollectible() throws {
        let entry = try XCTUnwrap(dex.entry(slug: "basculin-white-striped"))
        XCTAssertEqual(entry.region, "hisui")
        XCTAssertTrue(entry.isRegionalForm)
    }

    /// Excluded, with reasons in DECISIONS.md. Mega and Gigantamax are temporary
    /// transformations rather than creatures you own, Zen Mode is an in-battle
    /// state, Totem is battle staging, and a costumed Pikachu is a cosmetic swap
    /// that would undercut shiny as the rarity signal.
    func testExcludedFormsAreAbsent() {
        for slug in [
            "charizard-mega-x", "kyogre-primal", "charizard-gmax",
            "raticate-totem-alola", "darmanitan-galar-zen", "pikachu-alola-cap",
            "deoxys-attack", "minior-red",
        ] {
            XCTAssertNil(dex.entry(slug: slug), "\(slug) should not be collectible")
        }
    }

    /// Paldean Tauros keeps all three breeds because Combat, Blaze and Aqua are
    /// genuinely different types, so the breed has to survive into the name or
    /// three entries read identically in the dex.
    func testPaldeanTaurosKeepsAllThreeBreeds() {
        let breeds = dex.regionalForms.filter { $0.slug.hasPrefix("tauros-paldea") }
        XCTAssertEqual(breeds.count, 3)
        XCTAssertEqual(Set(breeds.map(\.name)).count, 3, "breed must be visible in the name")
        for breed in breeds {
            XCTAssertTrue(breed.name.contains("Paldean Tauros"), breed.name)
        }
    }

    /// Display names come from PokeAPI rather than title-casing the slug, because
    /// title-casing gets exactly these wrong.
    func testAwkwardNamesSurviveIntact() throws {
        // A typographic apostrophe (U+2019), not an ASCII one. Another thing a
        // hand-written name table gets wrong.
        XCTAssertEqual(try XCTUnwrap(dex.entry(slug: "farfetchd")).name, "Farfetch\u{2019}d")
        XCTAssertEqual(try XCTUnwrap(dex.entry(slug: "mr-mime")).name, "Mr. Mime")
        XCTAssertEqual(try XCTUnwrap(dex.entry(slug: "nidoran-f")).name, "Nidoran♀")
        XCTAssertEqual(try XCTUnwrap(dex.entry(slug: "vulpix-alola")).name, "Alolan Vulpix")
        XCTAssertEqual(try XCTUnwrap(dex.entry(slug: "growlithe-hisui")).name, "Hisuian Growlithe")
    }

    // MARK: - Evolution

    /// Regional evolution stays in-region with no hardcoded exception table,
    /// because the manifest recorded `evolved_form_id ?? evolved_species_id`.
    /// Some regionals evolve into a form, others into a plain species, and both
    /// fall out of that one expression.
    func testRegionalEvolutionStaysInRegion() throws {
        let cases: [(String, String)] = [
            ("vulpix-alola", "ninetales-alola"),      // resolved via form
            ("growlithe-hisui", "arcanine-hisui"),    // via form
            ("meowth-galar", "perrserker"),           // via species
            ("qwilfish-hisui", "overqwil"),           // via species, 3 raw rows deduped
            ("sneasel-hisui", "sneasler"),            // via species
        ]
        for (from, to) in cases {
            let entry = try XCTUnwrap(dex.entry(slug: from), from)
            let targets = dex.evolutions(of: entry).map(\.slug)
            XCTAssertEqual(targets, [to], from)
        }
    }

    /// Branching regional evolution is real content that falls out of the data,
    /// not a special case: Pikachu evolves into Raichu or Alolan Raichu.
    func testPikachuHasTwoEvolutionTargets() throws {
        let pikachu = try XCTUnwrap(dex.entry(slug: "pikachu"))
        XCTAssertEqual(Set(dex.evolutions(of: pikachu).map(\.slug)), ["raichu", "raichu-alola"])
    }

    /// A dex tile must never point at an entry that does not exist, so targets
    /// outside the collectible pool are dropped at generation time.
    func testEveryEvolutionTargetResolves() {
        for entry in dex.entries {
            for target in entry.evolvesTo {
                XCTAssertNotNil(dex.entry(id: target), "\(entry.slug) -> \(target)")
            }
        }
    }

    func testNothingEvolvesIntoItself() {
        for entry in dex.entries {
            XCTAssertFalse(entry.evolvesTo.contains(entry.id), entry.slug)
        }
    }

    /// The edge join reads a row's base from the row, and only falls back to the
    /// species table when the row declines to say. Getting that backwards is a
    /// species-space answer to a pokemon-space question and it is silent: it
    /// claims ordinary Meowth becomes Perrserker, which the app would happily
    /// act on. Both halves of the pair are asserted, because fixing one direction
    /// and breaking the other looks identical from the Perrserker side.
    func testOnlyTheRegionalFormTakesTheRegionalEvolution() throws {
        let meowth = try XCTUnwrap(dex.entry(slug: "meowth"))
        XCTAssertEqual(dex.evolutions(of: meowth).map(\.slug), ["persian"])
        let galarian = try XCTUnwrap(dex.entry(slug: "meowth-galar"))
        XCTAssertEqual(dex.evolutions(of: galarian).map(\.slug), ["perrserker"])
    }

    /// The mirror-image failure of the Meowth one, and the reason the generator
    /// asserts reachability: a regional evolution whose *base* is an ordinary
    /// species had no incoming edge at all, so nothing in the pool could produce
    /// it and no amount of play would ever fill the tile.
    func testRegionalEvolutionsOfOrdinaryBasesAreReachable() throws {
        let exeggcute = try XCTUnwrap(dex.entry(slug: "exeggcute"))
        XCTAssertEqual(
            Set(dex.evolutions(of: exeggcute).map(\.slug)), ["exeggutor", "exeggutor-alola"]
        )
    }

    /// Every entry is either hatchable or downstream of something hatchable.
    /// The hatch pool is "no incoming edge", so a wrong edge does not read as a
    /// wrong edge: it reads as a tile that can never be filled.
    func testEveryEntryIsReachableFromTheHatchPool() {
        var reachable = Set(dex.hatchable.map(\.id))
        var frontier = reachable
        while !frontier.isEmpty {
            let next = Set(frontier.compactMap { dex.entry(id: $0) }.flatMap(\.evolvesTo))
            frontier = next.subtracting(reachable)
            reachable.formUnion(frontier)
        }
        let unreachable = Set(dex.entries.map(\.id)).subtracting(reachable)
        XCTAssertEqual(unreachable, [], "\(unreachable.compactMap { dex.entry(id: $0)?.slug })")
    }

    func testHatchPoolExcludesEvolutionGatedEntries() throws {
        XCTAssertEqual(dex.hatchable.count, 570)
        XCTAssertEqual(dex.count - dex.hatchable.count, 513)
        let charmander = try XCTUnwrap(dex.entry(slug: "charmander"))
        let charizard = try XCTUnwrap(dex.entry(slug: "charizard"))
        XCTAssertFalse(dex.isEvolutionGated(charmander))
        XCTAssertTrue(dex.isEvolutionGated(charizard))
    }

    /// The whole point of resolving triggers at generation time: the app compares
    /// a level and checks an item, and there is no fifth case to handle.
    func testEveryEdgeCarriesAUsableLevel() {
        for entry in dex.entries {
            for edge in entry.evolutions {
                XCTAssertTrue((1...100).contains(edge.minLevel), "\(entry.slug) -> \(edge.to)")
                switch edge.trigger {
                case .level:
                    XCTAssertTrue((7...64).contains(edge.minLevel), entry.slug)
                    XCTAssertNil(edge.item, entry.slug)
                case .item, .trade:
                    XCTAssertNotNil(edge.item, entry.slug)
                    XCTAssertNotNil(edge.itemName, entry.slug)
                case .substituted:
                    XCTAssertEqual(edge.minLevel, 36, entry.slug)
                    XCTAssertNil(edge.item, entry.slug)
                }
            }
        }
    }

    func testTriggerMixMatchesTheGenerator() {
        var counts: [EvolutionTrigger: Int] = [:]
        for entry in dex.entries {
            for edge in entry.evolutions { counts[edge.trigger, default: 0] += 1 }
        }
        XCTAssertEqual(counts, [.level: 364, .item: 69, .trade: 26, .substituted: 54])
    }

    /// Trading is the one trigger with no single-player equivalent, so it takes
    /// the item the mainline games added for exactly this in Gen 9. It must be
    /// one item, not 26 improvised ones, or the shop grows a page of nonsense.
    func testTradeEdgesAllTakeTheLinkingCord() {
        let items = Set(
            dex.entries.flatMap(\.evolutions).filter { $0.trigger == .trade }.compactMap(\.item)
        )
        XCTAssertEqual(items, ["linking-cord"])
    }

    /// 23 stones plus the Linking Cord. This is the shop's evolution stock, so it
    /// is a number the economy depends on rather than a curiosity.
    func testEvolutionItemsAreABoundedShopList() {
        let items = Set(dex.entries.flatMap(\.evolutions).compactMap(\.item))
        XCTAssertEqual(items.count, 24)
        XCTAssertTrue(items.contains("thunder-stone"))
        XCTAssertTrue(items.contains("linking-cord"))
    }

    /// An item edge is gated on the item, not on the level, and a missing item
    /// must not quietly degrade into "evolves at level 1".
    func testItemEdgesNeedTheItem() throws {
        let pikachu = try XCTUnwrap(dex.entry(slug: "pikachu"))
        XCTAssertEqual(dex.availableEvolutions(of: pikachu, atLevel: 100).count, 0)
        let held = dex.availableEvolutions(of: pikachu, atLevel: 1, items: ["thunder-stone"])
        XCTAssertEqual(Set(held.map(\.target.slug)), ["raichu", "raichu-alola"])
    }

    /// Branching is the player's choice, not the game's, so every satisfied edge
    /// comes back rather than the first one.
    func testLevelEdgesFireOnLevelAlone() throws {
        let bulbasaur = try XCTUnwrap(dex.entry(slug: "bulbasaur"))
        XCTAssertEqual(dex.availableEvolutions(of: bulbasaur, atLevel: 15).count, 0)
        XCTAssertEqual(
            dex.availableEvolutions(of: bulbasaur, atLevel: 16).map(\.target.slug), ["ivysaur"]
        )
    }

    /// Nincada is both cases at once: a real level-20 edge to Ninjask and a
    /// `shed` edge to Shedinja that nothing here can model. Classification is on
    /// `min_level` rather than the trigger name, which is what keeps the first
    /// one honest instead of substituting both.
    func testUnmodellableTriggersSubstituteRatherThanDisappear() throws {
        let nincada = try XCTUnwrap(dex.entry(slug: "nincada"))
        let byTarget = Dictionary(uniqueKeysWithValues: nincada.evolutions.map { ($0.to, $0) })
        let ninjask = try XCTUnwrap(dex.entry(slug: "ninjask"))
        let shedinja = try XCTUnwrap(dex.entry(slug: "shedinja"))
        XCTAssertEqual(byTarget[ninjask.id]?.trigger, .level)
        XCTAssertEqual(byTarget[ninjask.id]?.minLevel, 20)
        XCTAssertEqual(byTarget[shedinja.id]?.trigger, .substituted)
        XCTAssertEqual(byTarget[shedinja.id]?.minLevel, 36)
    }

    // MARK: - Sprite URLs

    /// Pinning to a commit is what makes the disk cache permanent: sprites are
    /// served with `cache-control: max-age=300`, so a branch-tracking URL would
    /// have to revalidate every five minutes, and its bytes could change.
    func testSpriteURLsArePinnedToACommit() throws {
        let commit = dex.spritesCommit
        XCTAssertEqual(commit.count, 40, "expected a full git SHA")
        XCTAssertTrue(commit.allSatisfy(\.isHexDigit))

        let bulbasaur = try XCTUnwrap(dex.entry(id: 1))
        XCTAssertEqual(
            dex.spriteURL(for: bulbasaur).absoluteString,
            "https://raw.githubusercontent.com/PokeAPI/sprites/\(commit)"
                + "/sprites/pokemon/versions/generation-v/black-white/animated/1.gif")
        XCTAssertEqual(
            dex.spriteURL(for: bulbasaur, variant: .shiny).absoluteString,
            "https://raw.githubusercontent.com/PokeAPI/sprites/\(commit)"
                + "/sprites/pokemon/versions/generation-v/black-white/animated/shiny/1.gif")
    }

    func testStaticFallbackURLUsesHomePNG() throws {
        let pecharunt = try XCTUnwrap(dex.entry(id: 1025))
        XCTAssertEqual(pecharunt.spriteSet, .home)
        XCTAssertTrue(dex.spriteURL(for: pecharunt).absoluteString
            .hasSuffix("/sprites/pokemon/other/home/1025.png"))
    }

    func testEverySpriteURLIsHTTPSOnTheSpritesRepo() {
        for entry in dex.entries {
            let url = dex.spriteURL(for: entry)
            XCTAssertEqual(url.scheme, "https", entry.slug)
            XCTAssertEqual(url.host, "raw.githubusercontent.com", entry.slug)
        }
    }

    /// Two entries in the pool have no shiny sprite, and a missing shiny must
    /// render as the ordinary Pokemon rather than as a blank tile.
    func testShinyFallsBackToNormalWhenAbsent() {
        let withoutShiny = dex.entries.filter { !$0.shiny }
        XCTAssertEqual(withoutShiny.count, 2)
        for entry in withoutShiny {
            XCTAssertEqual(
                dex.spriteURL(for: entry, variant: .shiny),
                dex.spriteURL(for: entry),
                entry.slug)
            XCTAssertFalse(dex.cacheKey(for: entry, variant: .shiny).contains("shiny"), entry.slug)
        }
    }

    /// The cache key carries the sprite set, so regenerating the manifest and
    /// moving an entry between sets cannot leave the old art cached under a
    /// reused name in a cache that never expires.
    /// Completion is defined over the sprites that exist, not over 1,083 x 4.
    /// If this drifts, the dex advertises a target no play can reach, or quietly
    /// stops counting tiles it should.
    func testOwnableVariantsAre2368() {
        let total = dex.entries.reduce(0) { $0 + $1.ownableVariants.count }
        XCTAssertEqual(total, 2368)
        XCTAssertEqual(dex.entries.filter(\.female).count, 102)
        XCTAssertEqual(dex.entries.filter { $0.ownableVariants.count == 4 }.count, 102)
        XCTAssertEqual(dex.entries.filter { $0.ownableVariants.count == 2 }.count, 979)
        XCTAssertEqual(dex.entries.filter { $0.ownableVariants.count == 1 }.count, 2)
    }

    /// Asking for a variant an entry does not have must fall back rather than
    /// point at a 404, which would render as a blank tile forever given the cache
    /// never expires.
    func testMissingVariantsFallBack() throws {
        let venusaur = try XCTUnwrap(dex.entry(slug: "venusaur"))  // has a female sprite
        XCTAssertTrue(venusaur.female)
        XCTAssertTrue(dex.spriteURL(for: venusaur, variant: .female).path.contains("/female/"))

        let bulbasaur = try XCTUnwrap(dex.entry(slug: "bulbasaur"))  // does not
        XCTAssertFalse(bulbasaur.female)
        XCTAssertEqual(
            dex.spriteURL(for: bulbasaur, variant: .shinyFemale),
            dex.spriteURL(for: bulbasaur, variant: .shiny))
        XCTAssertEqual(dex.cacheKey(for: bulbasaur, variant: .female), "1-gen5.gif")
    }

    /// The repo nests female inside shiny. Getting the order backwards is a 404
    /// on 102 entries and silent everywhere else.
    func testShinyFemalePathOrder() throws {
        let venusaur = try XCTUnwrap(dex.entry(slug: "venusaur"))
        XCTAssertTrue(
            dex.spriteURL(for: venusaur, variant: .shinyFemale).path.hasSuffix(
                "/shiny/female/3.gif"))
        XCTAssertEqual(dex.cacheKey(for: venusaur, variant: .shinyFemale), "3-gen5-shiny-female.gif")
    }

    func testCacheKeyIncludesSpriteSet() throws {
        let bulbasaur = try XCTUnwrap(dex.entry(id: 1))
        XCTAssertEqual(dex.cacheKey(for: bulbasaur), "1-gen5.gif")
        XCTAssertEqual(dex.cacheKey(for: bulbasaur, variant: .shiny), "1-gen5-shiny.gif")
        XCTAssertEqual(dex.cacheKey(for: try XCTUnwrap(dex.entry(id: 1025))), "1025-home.png")
    }

    func testCacheKeysAreUniqueAcrossThePool() {
        var keys = Set<String>()
        for entry in dex.entries {
            XCTAssertTrue(keys.insert(dex.cacheKey(for: entry)).inserted, entry.slug)
            if entry.shiny {
                XCTAssertTrue(keys.insert(dex.cacheKey(for: entry, variant: .shiny)).inserted, entry.slug)
            }
        }
        XCTAssertEqual(keys.count, 1083 + 1081)
    }

    // MARK: - Featured pick

    /// Stable within a day so the menu bar does not change Pokemon on relaunch,
    /// and different across days so it is visibly alive. Phase 4 replaces this
    /// with the player's active Pokemon.
    func testFeaturedIsStableWithinADayAndMovesAcrossDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        let morning = Date(timeIntervalSince1970: 1_787_400_000)
        let later = morning.addingTimeInterval(3600)
        XCTAssertEqual(
            dex.featured(on: morning, calendar: calendar)?.id,
            dex.featured(on: later, calendar: calendar)?.id)

        // Distinct across a run of consecutive days. Not all-distinct in general
        // (1,083 slots, so collisions are expected eventually), but a week that
        // repeats would mean the seed is not moving.
        let week = (0..<7).compactMap {
            dex.featured(
                on: morning.addingTimeInterval(Double($0) * 86_400),
                calendar: calendar)?.id
        }
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(Set(week).count, 7, "featured pick should differ day to day")
    }

    /// The index arithmetic multiplies by a large constant, which overflows into
    /// negatives. Swift's `%` keeps the dividend's sign, so without the
    /// non-negative modulo this crashes on some dates rather than some of the time.
    func testFeaturedNeverGoesOutOfBoundsOverAFullYear() {
        let start = Date(timeIntervalSince1970: 0)
        for day in 0..<400 {
            XCTAssertNotNil(dex.featured(on: start.addingTimeInterval(Double(day) * 86_400)))
        }
        // And for dates before the epoch, where the day ordinal itself is negative.
        for day in 1...50 {
            XCTAssertNotNil(dex.featured(on: start.addingTimeInterval(Double(-day) * 86_400)))
        }
    }
}
