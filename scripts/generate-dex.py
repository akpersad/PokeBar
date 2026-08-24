#!/usr/bin/env python3
"""Generates Sources/PokeBar/Dex/Resources/pokedex.json, the bundled Pokedex manifest.

Run this by hand, not on every build. The dex is static data: a new generation is
a years-scale event, and pinning the output means a cold first launch needs no
network and no third-party service to be up. See DECISIONS.md for why this is a
build-time manifest rather than a runtime fetch.

    ./scripts/generate-dex.py            # regenerate and verify
    ./scripts/generate-dex.py --check    # verify the committed manifest, write nothing

Every figure this script depends on is asserted before it writes. If PokeAPI or
the sprites repo changes shape underneath us, this fails loudly at the desk of
whoever ran it instead of silently shipping a dex with holes in it.

Two upstream data-model traps, both verified against live data and both easy to
get wrong:

  * `pokemonform.id` is a different id space from `pokemon.id`. Alolan Vulpix is
    pokemon 10103 and form 10205. The evolution table's `base_form_id` and
    `evolved_form_id` are in the *pokemon* space, so joining on form id silently
    returns zero rows for every regional form.
  * A regional form does not have to carry a regional suffix. Hisuian Basculin is
    `basculin-white-striped`, so a suffix regex finds 57 of the 58 regionals.

Evolution edges carry three resolved fields, because 47% of the pool is reachable
only by evolving something and the game layer has to know *when* each edge fires:

  * `trigger`   - level / item / trade / substituted
  * `minLevel`  - always a real number, so the app can compare a level and never
                  has to know what a tower of darkness is
  * `item`      - the slug of the item the edge requires, or null

Two of those values are **substitutions and are labelled as such**, because there
is no honest way to model friendship or a tower of darkness in a token counter and
silently dropping the 54 edges behind them would be worse:

  * `level-up` with no `min_level` (friendship, time of day, location) and the
    exotic one-offs (spin, tower-of-darkness, three-critical-hits, take-damage,
    shed, agile/strong-style-move, ...) both become `substituted` at level 36.
    Classification is on `min_level` rather than on the trigger name, which is
    why Nincada -> Shedinja (`shed`, level 20) and Tandemaus -> Maushold
    (`other`, level 25) keep their real levels instead of being substituted.
  * `trade` keeps its own trigger and gains a Linking Cord requirement, canonical
    since Gen 9. That is a substitution in mechanism, not in spirit.

THE EDGE JOIN IS THE THIRD DATA-MODEL TRAP, and it is the one that bit hardest.
`base_form_id` is null on 495 of 553 rows, so an earlier version of this file fell
back to `pokemonspecies.evolves_from_species_id` for the *whole edge*, which is a
species-space answer to a pokemon-space question. It got 11 edges wrong in each
direction: it claimed ordinary Meowth evolves into Perrserker (it is Galarian
Meowth that does) and it left Alolan Exeggutor with no incoming edge at all, so
nothing in the pool could reach it. The fix is to fall back only for the *base* of
a row that has one, and keep the row's own pokemon-space target:

    base   = row.base_form_id ?? species[row.evolved_species_id].evolves_from_species_id
    target = row.evolved_form_id ?? row.evolved_species_id

The species table is still consulted, but only as a backstop for a species that
evolves from something and has no evolution row at all. Exactly one does:
Meltan -> Melmetal.

Thirteen edges carry more than one row (different version groups) and twelve of
those disagree. `_resolve_edge` picks deliberately: lowest real `min_level` first,
then an item row, then the lowest row id. That preference is what turns Kubfu into
a Scroll of Darkness purchase rather than a level-36 substitution, and Eevee into
eight stones rather than eight guesses.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/PokeBar/Dex/Resources/pokedex.json"

GRAPHQL = "https://graphql.pokeapi.co/v1beta2"
GITHUB = "https://api.github.com/repos/PokeAPI/sprites"

# The sprites-repo commit every sprite URL is pinned to, and therefore the thing
# that makes the app's permanent on-disk sprite cache correct (DECISIONS.md,
# invariant 13). Pinned here rather than read from master on every run: resolving
# master would mean a routine regeneration silently re-pins the whole dex, which
# is a decision, not a side effect. Pass --repin to make that decision on purpose.
SPRITES_COMMIT = "c10459b9b0129eaca5c5d9b1cac65336debb1d08"

# The National Dex ceiling this manifest covers. Raising it is the one-line part
# of adding a generation; the assertions below are the rest.
MAX_SPECIES = 1025

# Sprite sets, in resolution order. Prefer authentic Black/White pixel art, fall
# back to Showdown's unified animated set, then to static HOME renders. Layering
# these gets 100% of the National Dex playable and 98.6% of it animated, against
# 63.2% if we only ever used gen-v. The cost is up to three visible art styles in
# one Pokedex, accepted knowingly (DECISIONS.md).
SPRITE_SETS = [
    ("gen5", "sprites/pokemon/versions/generation-v/black-white/animated", "gif"),
    ("showdown", "sprites/pokemon/other/showdown", "gif"),
    ("home", "sprites/pokemon/other/home", "png"),
]

# Excluded from the collectible pool, with reasons in DECISIONS.md. Mega, Primal
# and Gigantamax are temporary transformations rather than creatures you own;
# Totem is a one-off battle staging; Zen Mode is an in-battle state.
#
# `-cap` is here because `pikachu-alola-cap` is a costumed Pikachu, not an Alolan
# regional form, and it matches a regional-suffix search. Cosmetic swaps entering
# at base rarity would undercut shiny as the rarity signal, which is the whole
# reason DECISIONS.md excludes the 26 costumed Pikachu and Minior colours. The
# regional-form count assertion below is what caught this.
FORM_EXCLUSIONS = ("-totem", "-cap", "darmanitan-galar-zen")

# The regional form that carries no regional suffix.
BASCULIN_HISUI = "basculin-white-striped"

REGIONS = {"alola": "Alolan", "galar": "Galarian", "hisui": "Hisuian", "paldea": "Paldean"}

# The level every unmodellable trigger evolves at. The user's call: 36 is the
# second most common real evolution level in the data and the canonical
# second-stage level, so it lands on a number the games already use, and at 14.4 h
# into the climb it puts these after the ordinary first-stage crowd rather than
# mixed in with them. See DECISIONS.md; 30 was proposed first and rejected.
SUBSTITUTE_LEVEL = 36

# Trading is not a thing a single-player menu bar app can do, so a trade edge
# takes the item the mainline games added for exactly this in Gen 9.
LINKING_CORD = ("linking-cord", "Linking Cord")

# --- Expected figures. These are the assertions, not documentation. -----------
# Measured 2026-08-22. Each one is a property of the source data that this
# manifest depends on, so drift should stop the generator rather than reach code.
EXPECT_SPECIES = 1025
EXPECT_REGIONAL_FORMS = 58
EXPECT_POOL = EXPECT_SPECIES + EXPECT_REGIONAL_FORMS  # 1083
EXPECT_GEN5_BASE = 780  # 76.1% of 1-1025
EXPECT_SHOWDOWN_BASE = 1011  # 98.6%
EXPECT_HOME_BASE = 1025  # 100%
# The species with no animated sprite in any set, so they resolve to static HOME.
EXPECT_STATIC_ONLY = [990, 991, 992, 993, 994, 995, 1006, 1008, 1010, 1017, 1022, 1023, 1024, 1025]
# Evolution, measured 2026-08-23 after the edge join was corrected. Every one of
# these is load-bearing for the game layer: the hatch pool is the entries with no
# incoming edge, and everything else has to be reachable by evolving.
EXPECT_EDGES = 513
EXPECT_GATED = 513  # entries reachable only by evolving. 47.4% of the pool
EXPECT_HATCHABLE = EXPECT_POOL - EXPECT_GATED  # 570
EXPECT_WITH_EVOLUTION = 477
EXPECT_TRIGGERS = {"level": 364, "item": 69, "trade": 26, "substituted": 54}
EXPECT_LEVEL_RANGE = (7, 64)
EXPECT_EVOLUTION_ITEMS = 23  # distinct stones etc. 24 shop lines with the Cord
# Ownable variants. A variant exists iff its sprite file does, so completion is
# defined over these 2,368 sprites and not over 1,083 x 4: only 102 entries look
# different by gender, and two have no shiny at all.
EXPECT_FEMALE_FORMS = 102
EXPECT_OWNABLE_SPRITES = 2368


def _curl(args: list[str]) -> dict:
    """HTTP via curl rather than urllib, on purpose.

    The python.org framework build on this machine has no CA bundle wired up
    (`ssl.get_default_verify_paths()` points at a cert.pem that was never
    installed), so urllib fails every HTTPS handshake with
    CERTIFICATE_VERIFY_FAILED. curl uses the system trust store and works. The
    alternative was running Python's `Install Certificates.command`, which is a
    global machine change, and this project already declines those (see the
    `sudo xcode-select -s` note in CLAUDE.md).
    """
    proc = subprocess.run(
        ["curl", "-sS", "--fail-with-body", "--max-time", "60", *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"fetch failed: {proc.stderr.strip() or proc.stdout[:300]}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise SystemExit(f"non-JSON response: {proc.stdout[:300]}")


def graphql(query: str) -> dict:
    payload = _curl(
        [
            "-X", "POST", GRAPHQL,
            "-H", "Content-Type: application/json",
            "--data-binary", json.dumps({"query": query}),
        ]
    )
    if "errors" in payload:
        raise SystemExit(f"PokeAPI GraphQL error: {json.dumps(payload['errors'])[:500]}")
    return payload["data"]


def github_json(url: str) -> dict:
    payload = _curl([url, "-H", "Accept: application/vnd.github+json"])
    if "message" in payload and "tree" not in payload and "sha" not in payload:
        # Most likely the 60/hr unauthenticated rate limit. Worth naming, because
        # it is one of the reasons the dex is generated here and not at runtime.
        raise SystemExit(f"GitHub API: {payload['message']}")
    return payload


def sprite_manifest(commit: str) -> dict[str, set[int]]:
    """Which ids exist in which sprite set, per variant.

    Four variants per set, because a variant is ownable if and only if its sprite
    file exists (DECISIONS.md). Female is the interesting one: only about a tenth
    of the pool *looks* different by gender, and the per-set counts disagree
    (gen-v has 104 female and 98 shiny female, showdown 102 and 102, home 103 and
    103), so this has to be resolved per entry against the set that entry actually
    uses rather than assumed from any one directory listing.

    Fetched per directory, deliberately. The recursive whole-repo tree is 62,142
    blobs and comes back `truncated: true`, which would silently drop sprites and
    report them as missing. A path-addressed subtree is complete.
    """
    ids: dict[str, set[int]] = {}
    for name, path, ext in SPRITE_SETS:
        for variant, sub in (
            ("", ""), ("-shiny", "/shiny"), ("-female", "/female"),
            ("-shiny-female", "/shiny/female"),
        ):
            tree = github_json(f"{GITHUB}/git/trees/{commit}:{path}{sub}")
            if tree.get("truncated"):
                raise SystemExit(f"subtree {path}{sub} came back truncated; cannot trust it")
            pattern = re.compile(rf"^(\d+)\.{ext}$")
            found = set()
            for entry in tree["tree"]:
                if entry["type"] != "blob":
                    continue
                m = pattern.match(entry["path"])
                if m:
                    found.add(int(m.group(1)))
            ids[name + variant] = found
    return ids


def fetch_species() -> list[dict]:
    data = graphql(
        f"""{{ pokemonspecies(where: {{id: {{_lte: {MAX_SPECIES}}}}}, order_by: {{id: asc}}) {{
                 id name capture_rate is_legendary is_mythical generation_id
                 pokemonspeciesnames(where: {{language_id: {{_eq: 9}}}}) {{ name }}
               }} }}"""
    )
    return data["pokemonspecies"]


def fetch_varieties() -> list[dict]:
    """Non-default varieties, which is where the regional forms live."""
    data = graphql(
        """{ pokemon(where: {is_default: {_eq: false}}, order_by: {id: asc}) {
                 id name pokemon_species_id } }"""
    )
    return data["pokemon"]


def fetch_evolutions() -> tuple[list[dict], list[dict]]:
    """Evolution rows, plus the species table used to resolve a row's base.

    Both are needed and they are in different id spaces, which is the trap
    documented at the top of this file. The rows are authoritative for *what an
    edge requires*; the species table only ever answers "what does this evolve
    from", and only for rows that decline to say.
    """
    edges = graphql(
        """{ pokemonevolution {
                 id base_form_id evolved_form_id evolved_species_id
                 min_level evolution_item_id
                 evolutiontrigger { name }
                 item { name itemnames(where: {language_id: {_eq: 9}}) { name } }
             } }"""
    )["pokemonevolution"]
    species = graphql(
        f"""{{ pokemonspecies(where: {{id: {{_lte: {MAX_SPECIES}}}}}) {{
                  id evolves_from_species_id }} }}"""
    )["pokemonspecies"]
    return edges, species


def _resolve_edge(rows: list[dict]) -> dict:
    """Collapse the rows for one edge into the single thing the game reads.

    Thirteen edges carry several rows, one per version group, and twelve of those
    disagree with each other. The preference order is deliberate and it is what
    keeps interesting content out of the substitution bucket:

      1. a real `min_level`, lowest wins   (Cyndaquil takes 14, not Legends' 17)
      2. an item, lowest item id wins      (Kubfu becomes a Scroll of Darkness
                                            rather than a tower of darkness;
                                            Sinistea takes the Cracked Pot)
      3. lowest row id, for determinism    (Feebas and Hisuian Qwilfish, which
                                            offer nothing modellable either way)
    """
    levelled = [r for r in rows if r["min_level"] is not None]
    if levelled:
        row = min(levelled, key=lambda r: (r["min_level"], r["id"]))
        return {"trigger": "level", "minLevel": row["min_level"], "item": None, "itemName": None}

    with_item = [r for r in rows if r["evolution_item_id"] is not None]
    if with_item:
        row = min(with_item, key=lambda r: (r["evolution_item_id"], r["id"]))
        item = row["item"]
        if item is None or not item["itemnames"]:
            raise SystemExit(f"evolution item {row['evolution_item_id']} has no English name")
        # No level gate: a Fire Stone works on a level 1 Vulpix in the games too.
        return {
            "trigger": "item",
            "minLevel": 1,
            "item": item["name"],
            "itemName": item["itemnames"][0]["name"],
        }

    row = min(rows, key=lambda r: r["id"])
    if row["evolutiontrigger"]["name"] == "trade":
        slug, name = LINKING_CORD
        return {"trigger": "trade", "minLevel": 1, "item": slug, "itemName": name}

    # Friendship, time of day, location, and the exotic one-offs. Labelled as a
    # substitution rather than dressed up as a level requirement.
    return {"trigger": "substituted", "minLevel": SUBSTITUTE_LEVEL, "item": None, "itemName": None}


def display_name(slug: str, species_name: str, region: str | None) -> str:
    """Human-facing name. The species name comes from PokeAPI rather than being
    title-cased off the slug, because title-casing gets `farfetchd`, `mr-mime`
    and `nidoran-f` wrong, and those are names a user reads."""
    if region is None:
        return species_name
    adjective = REGIONS[region]
    # Paldean Tauros ships three breeds that are genuinely different types, so the
    # breed has to survive into the name or three entries read identically.
    breed = re.search(r"-(combat|blaze|aqua)-breed$", slug)
    if breed:
        return f"{adjective} {species_name} ({breed.group(1).title()})"
    return f"{adjective} {species_name}"


def region_of(slug: str) -> str | None:
    if slug == BASCULIN_HISUI:
        return "hisui"
    for key in REGIONS:
        if re.search(rf"-{key}(-|$)", slug):
            return key
    return None


def rarity_of(capture_rate: int, legendary: bool, mythical: bool) -> str:
    """Rarity band from the species' own `capture_rate`.

    Rarity is read off official capture difficulty rather than invented, and it
    lives on the *species*, so a regional form inherits it for free: Alolan Vulpix
    reports capture_rate 190 exactly like Vulpix, and is exactly as common. Shiny
    is the only modifier layered on top (DECISIONS.md).

    Legendary and mythical are a floor, not a band. Some legendaries are catchable
    enough to land in a common band on capture_rate alone, and a legendary that
    shows up as "common" reads as a bug.
    """
    if mythical:
        return "mythical"
    if legendary:
        return "legendary"
    if capture_rate >= 190:
        return "common"
    if capture_rate >= 90:
        return "uncommon"
    if capture_rate >= 45:
        return "rare"
    return "epic"


def build(repin: bool = False) -> dict:
    commit = github_json(f"{GITHUB}/commits/master")["sha"] if repin else SPRITES_COMMIT
    if repin and commit != SPRITES_COMMIT:
        print(f"re-pinning sprites: {SPRITES_COMMIT} -> {commit}")
        print("  update SPRITES_COMMIT and DECISIONS.md in the same change.")
    sprites = sprite_manifest(commit)

    # Sprite-set coverage is the claim the whole three-set layering rests on, so
    # verify it before using it rather than trusting the numbers in DECISIONS.md.
    for name, expected in (
        ("gen5", EXPECT_GEN5_BASE),
        ("showdown", EXPECT_SHOWDOWN_BASE),
        ("home", EXPECT_HOME_BASE),
    ):
        actual = len({i for i in sprites[name] if 1 <= i <= MAX_SPECIES})
        if actual != expected:
            raise SystemExit(
                f"sprite set {name}: {actual} base sprites, expected {expected}. "
                "The sprites repo changed coverage; update the expectation deliberately."
            )

    species = fetch_species()
    if len(species) != EXPECT_SPECIES:
        raise SystemExit(f"got {len(species)} species, expected {EXPECT_SPECIES}")
    by_species_id = {s["id"]: s for s in species}

    varieties = fetch_varieties()
    edges, species_evo = fetch_evolutions()

    # --- collectible pool: every base species, plus the 58 regional forms ------
    pool: list[dict] = []
    for s in species:
        names = s["pokemonspeciesnames"]
        if not names:
            raise SystemExit(f"species {s['id']} has no English name")
        pool.append(
            {
                "id": s["id"],
                "speciesID": s["id"],
                "slug": s["name"],
                "name": names[0]["name"],
                "region": None,
                "generation": s["generation_id"],
                "captureRate": s["capture_rate"],
                "legendary": s["is_legendary"],
                "mythical": s["is_mythical"],
            }
        )

    for v in varieties:
        slug = v["name"]
        if any(x in slug for x in FORM_EXCLUSIONS):
            continue
        region = region_of(slug)
        if region is None:
            continue
        parent = by_species_id.get(v["pokemon_species_id"])
        if parent is None:
            raise SystemExit(f"form {slug} points at species {v['pokemon_species_id']}, absent")
        pool.append(
            {
                "id": v["id"],
                "speciesID": parent["id"],
                "slug": slug,
                "name": display_name(slug, parent["pokemonspeciesnames"][0]["name"], region),
                "region": region,
                "generation": parent["generation_id"],
                "captureRate": parent["capture_rate"],
                "legendary": parent["is_legendary"],
                "mythical": parent["is_mythical"],
            }
        )

    regional = [e for e in pool if e["region"] is not None]
    if len(regional) != EXPECT_REGIONAL_FORMS:
        got = sorted(e["slug"] for e in regional)
        raise SystemExit(
            f"got {len(regional)} regional forms, expected {EXPECT_REGIONAL_FORMS}\n{got}"
        )
    if len(pool) != EXPECT_POOL:
        raise SystemExit(f"pool is {len(pool)}, expected {EXPECT_POOL}")

    # --- evolution edges -------------------------------------------------------
    # base comes from the row where the row has one, and only otherwise from the
    # species table. Getting this backwards is the third data-model trap; see the
    # module docstring. qwilfish-hisui legitimately returns three rows for
    # different version groups and must collapse to one edge, while Pikachu
    # legitimately returns two distinct targets (Raichu and Alolan Raichu), which
    # is real branching content.
    evolves_from = {s["id"]: s["evolves_from_species_id"] for s in species_evo}
    edge_rows: dict[tuple[int, int], list[dict]] = {}
    targets_with_rows: set[int] = set()
    for e in edges:
        target = e["evolved_form_id"] or e["evolved_species_id"]
        if target is None:
            continue
        targets_with_rows.add(target)
        base = e["base_form_id"] or evolves_from.get(e["evolved_species_id"])
        if base is None:
            continue
        edge_rows.setdefault((base, target), []).append(e)

    # Backstop for a species that evolves from something and has no row at all.
    # Exactly one does, and it is asserted, because a second one appearing means
    # the source changed shape rather than that the backstop is working.
    rowless = sorted(
        (parent, s["id"])
        for s in species_evo
        if (parent := s["evolves_from_species_id"]) is not None
        and s["id"] not in targets_with_rows
    )
    if rowless != [(808, 809)]:
        raise SystemExit(f"expected only Meltan -> Melmetal to have no evolution row, got {rowless}")

    ids_in_pool = {e["id"] for e in pool}

    # Resolve each edge to the single (trigger, level, item) triple the game
    # reads, and index it by base. Targets outside the collectible pool (Megas,
    # Gigantamax and the other excluded forms) are dropped here, so the dex can
    # never point at an entry that does not exist.
    resolved_edges: dict[int, list[dict]] = {}

    def _add(base: int, edge: dict) -> None:
        if base in ids_in_pool and edge["to"] in ids_in_pool:
            resolved_edges.setdefault(base, []).append(edge)

    for (base, target), rows in edge_rows.items():
        _add(base, {"to": target, **_resolve_edge(rows)})
    for base, target in rowless:
        # No row means nothing to read a requirement off, which is the same
        # position the exotic triggers leave us in. Melmetal costs 400 candy in
        # Pokemon GO; there is no candy here either.
        _add(base, {"to": target, "trigger": "substituted", "minLevel": SUBSTITUTE_LEVEL,
                    "item": None, "itemName": None})
    for group in resolved_edges.values():
        group.sort(key=lambda e: e["to"])

    # --- sprite resolution, per entry -----------------------------------------
    static_only: list[int] = []
    for entry in pool:
        pid = entry["id"]
        chosen = None
        for name, _, ext in SPRITE_SETS:
            if pid in sprites[name]:
                chosen = (name, ext)
                break
        if chosen is None:
            raise SystemExit(f"no sprite in any set for {entry['slug']} ({pid})")
        entry["spriteSet"] = chosen[0]
        entry["shiny"] = pid in sprites[chosen[0] + "-shiny"]
        female = pid in sprites[chosen[0] + "-female"]
        if female != (pid in sprites[chosen[0] + "-shiny-female"]):
            raise SystemExit(
                f"{entry['slug']} has a female sprite in {chosen[0]} but not a shiny one, "
                "or the reverse. The manifest stores one flag for both; split it."
            )
        entry["female"] = female
        entry["animated"] = chosen[0] != "home"
        if not entry["animated"]:
            static_only.append(pid)
        entry["evolutions"] = resolved_edges.get(pid, [])
        entry["rarity"] = rarity_of(
            entry["captureRate"], entry["legendary"], entry["mythical"]
        )

    if sorted(static_only) != EXPECT_STATIC_ONLY:
        raise SystemExit(
            f"static-only set drifted.\n  got:      {sorted(static_only)}\n"
            f"  expected: {EXPECT_STATIC_ONLY}"
        )

    # --- evolution assertions --------------------------------------------------
    # The hatch pool is "every entry with no incoming edge", so a wrong edge does
    # not read as a wrong edge. It reads as a species that can never be obtained,
    # or as one that hatches when it should have to be earned.
    all_edges = [(e["id"], edge) for e in pool for edge in e["evolutions"]]
    gated = {edge["to"] for _, edge in all_edges}
    triggers = Counter(edge["trigger"] for _, edge in all_edges)
    levels = [edge["minLevel"] for _, edge in all_edges if edge["trigger"] == "level"]
    evo_items = {edge["item"] for _, edge in all_edges if edge["trigger"] == "item"}

    for label, actual, expected in (
        ("edges", len(all_edges), EXPECT_EDGES),
        ("evolution-gated entries", len(gated), EXPECT_GATED),
        ("hatchable entries", len(pool) - len(gated), EXPECT_HATCHABLE),
        ("entries with an evolution", sum(1 for e in pool if e["evolutions"]), EXPECT_WITH_EVOLUTION),
        ("distinct evolution items", len(evo_items), EXPECT_EVOLUTION_ITEMS),
    ):
        if actual != expected:
            raise SystemExit(f"{label}: {actual}, expected {expected}")
    if dict(triggers) != EXPECT_TRIGGERS:
        raise SystemExit(f"trigger mix drifted.\n  got:      {dict(triggers)}\n"
                         f"  expected: {EXPECT_TRIGGERS}")
    if (min(levels), max(levels)) != EXPECT_LEVEL_RANGE:
        raise SystemExit(f"min_level range {(min(levels), max(levels))}, "
                         f"expected {EXPECT_LEVEL_RANGE}")
    # Every gated entry must be reachable from something hatchable, or the dex
    # advertises entries no amount of play can produce.
    reachable = ids_in_pool - gated  # the hatchable seeds
    frontier = set(reachable)
    while frontier:
        nxt = {edge["to"] for e in pool if e["id"] in frontier for edge in e["evolutions"]}
        frontier = nxt - reachable
        reachable |= frontier
    unreachable = ids_in_pool - reachable
    if unreachable:
        raise SystemExit(f"unreachable entries: {sorted(unreachable)}")

    female_forms = sum(1 for e in pool if e["female"])
    ownable = sum(1 + e["shiny"] + 2 * e["female"] for e in pool)
    for label, actual, expected in (
        ("entries with a distinct female sprite", female_forms, EXPECT_FEMALE_FORMS),
        ("ownable sprites", ownable, EXPECT_OWNABLE_SPRITES),
    ):
        if actual != expected:
            raise SystemExit(f"{label}: {actual}, expected {expected}")

    animated = len(pool) - len(static_only)
    print(f"pool                {len(pool)}")
    print(f"  base species      {EXPECT_SPECIES}")
    print(f"  regional forms    {len(regional)}")
    print(f"animated            {animated} ({100 * animated / len(pool):.1f}%)")
    print(f"  static fallback   {len(static_only)}")
    for name, _, _ in SPRITE_SETS:
        n = sum(1 for e in pool if e["spriteSet"] == name)
        print(f"  via {name:<13s} {n}")
    print(f"shiny available     {sum(1 for e in pool if e['shiny'])}")
    print(f"female sprite       {female_forms}")
    print(f"ownable variants    {ownable}")
    print(f"with evolution      {sum(1 for e in pool if e['evolutions'])}")
    print(f"evolution edges     {len(all_edges)}")
    print(f"  triggers          {dict(triggers)}")
    print(f"  min_level         {min(levels)}-{max(levels)}, median {statistics.median(levels):.0f}")
    print(f"  distinct items    {len(evo_items)}")
    print(f"hatchable           {len(pool) - len(gated)} (the rest are evolution-gated)")
    print("rarity              " + str(dict(Counter(e["rarity"] for e in pool))))
    print(f"sprites commit      {commit}")

    return {
        "version": 1,
        "spritesCommit": commit,
        "maxSpeciesID": MAX_SPECIES,
        "entries": sorted(pool, key=lambda e: e["id"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="verify the committed manifest against live sources, write nothing",
    )
    ap.add_argument(
        "--repin",
        action="store_true",
        help="re-pin sprite URLs to the sprites repo's current master (a decision, "
             "not routine: it invalidates nothing but changes every sprite URL)",
    )
    args = ap.parse_args()

    manifest = build(repin=args.repin)
    encoded = json.dumps(manifest, indent=1, ensure_ascii=False, sort_keys=True) + "\n"

    if args.check:
        if not OUT.exists():
            print(f"\n✗ {OUT.relative_to(ROOT)} does not exist", file=sys.stderr)
            return 1
        if OUT.read_text() != encoded:
            print(f"\n✗ {OUT.relative_to(ROOT)} is stale", file=sys.stderr)
            return 1
        print(f"\n✓ {OUT.relative_to(ROOT)} matches live sources")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(encoded)
    print(f"\n✓ wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
