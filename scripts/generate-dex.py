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
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/PokeBar/Dex/Resources/pokedex.json"

GRAPHQL = "https://graphql.pokeapi.co/v1beta2"
GITHUB = "https://api.github.com/repos/PokeAPI/sprites"

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
    """Which ids exist in which sprite set, normal and shiny.

    Fetched per directory, deliberately. The recursive whole-repo tree is 62,142
    blobs and comes back `truncated: true`, which would silently drop sprites and
    report them as missing. A path-addressed subtree is complete.
    """
    ids: dict[str, set[int]] = {}
    for name, path, ext in SPRITE_SETS:
        for variant, sub in (("", ""), ("-shiny", "/shiny")):
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


def fetch_evolutions() -> list[dict]:
    """Evolution edges, both the species-level and the form-level ones.

    `evolved_form_id ?? evolved_species_id` is what keeps a regional evolution
    in-region without a hardcoded exception table: Alolan Vulpix carries a form
    target (10104, Alolan Ninetales) while Galarian Meowth carries only a species
    target (863, Perrserker). Both fall out of the same expression.
    """
    data = graphql(
        """{ pokemonevolution { evolved_species_id evolved_form_id base_form_id } }"""
    )
    edges = data["pokemonevolution"]
    species = graphql(
        f"""{{ pokemonspecies(where: {{id: {{_lte: {MAX_SPECIES}}}}}) {{
                  id evolves_from_species_id }} }}"""
    )["pokemonspecies"]
    return edges, species


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


def build() -> dict:
    commit = github_json(f"{GITHUB}/commits/master")["sha"]
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

    # --- evolution targets, deduped -------------------------------------------
    # qwilfish-hisui legitimately returns three rows for different version groups
    # and must collapse to one target. Pikachu legitimately returns two distinct
    # targets (Raichu and Alolan Raichu), which is real branching content.
    evo: dict[int, set[int]] = {}
    for e in edges:
        base = e["base_form_id"]
        if base is None:
            continue
        target = e["evolved_form_id"] or e["evolved_species_id"]
        if target is None:
            continue
        evo.setdefault(base, set()).add(target)
    for s in species_evo:
        parent = s["evolves_from_species_id"]
        if parent is not None:
            evo.setdefault(parent, set()).add(s["id"])

    ids_in_pool = {e["id"] for e in pool}

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
        entry["animated"] = chosen[0] != "home"
        if not entry["animated"]:
            static_only.append(pid)
        # Drop evolution targets outside the collectible pool (Megas, Gigantamax
        # and the other excluded forms) so the dex never points at an entry that
        # does not exist.
        entry["evolvesTo"] = sorted(t for t in evo.get(pid, set()) if t in ids_in_pool)
        entry["rarity"] = rarity_of(
            entry["captureRate"], entry["legendary"], entry["mythical"]
        )

    if sorted(static_only) != EXPECT_STATIC_ONLY:
        raise SystemExit(
            f"static-only set drifted.\n  got:      {sorted(static_only)}\n"
            f"  expected: {EXPECT_STATIC_ONLY}"
        )

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
    print(f"with evolution      {sum(1 for e in pool if e['evolvesTo'])}")
    from collections import Counter

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
    args = ap.parse_args()

    manifest = build()
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
