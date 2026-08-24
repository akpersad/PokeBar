# PokeBar

A macOS menu bar app that turns Claude Code and Codex token usage into a Pokémon
collection. Personal build, not distributed.

Inspired by [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar)
(MIT), which was audited in full first. Some Claude Code parsing logic is lifted
from it, marked in the source where it is.

## Status

Phases 1 through 4 are **complete**: usage engine, menu bar UI, the Pokédex data
layer, and the game. Live plan limits were considered and rejected, with reasons in
[DECISIONS.md](DECISIONS.md).

- [x] Bounded-memory JSONL streaming with resumable offsets
- [x] Claude Code and Codex usage parsers with incremental JSONL scanning
- [x] Incremental scanner (cold scan 17s, warm pass 0 bytes)
- [x] Accumulating ledger (survives relaunch, credits only growth)
- [x] FSEvents watchers replacing timer polling
- [x] Runtime model pricing with tier-weighted currency
- [x] Menu bar UI (coins in the status item, usage breakdown in the popover)
- [x] Pokédex data layer, 1,083 collectible entries (98.7% animated)
- [x] Permanent on-disk sprite cache, pinned to an immutable sprites commit
- [x] An animated species sprite in the status item
- [x] Evolution triggers, levels and items resolved into the manifest
- [x] Game layer: eggs, hatching, levels 1-100, evolution-by-XP, two currencies
- [x] Choose your first partner from the 27 starters, free and once
- [x] Pokédex view, browse and claim from the popover
- [x] Shop, notifications, and a floating desktop pet

What is left is tuning rather than building. The Dust prices are deliberately
generous and want a few days of real play; see "Still open" in
[DECISIONS.md](DECISIONS.md).

### The loop

Every weighted token does two things at once: it mints coins in the ledger and
grants XP to the Pokémon you are raising. They are parallel derivations, never a
shared pool, so there is no allocation choice and no week of training followed by a
week of saving.

- **Coins** buy volume: eggs at 300, Rare Candy, evolution stones, the Shiny Charm.
- **Dust** comes only from duplicate hatches and buys choice: name an entry and be
  given it, or re-roll a species you own for a variant you do not. That guaranteed
  path is what makes the dex finishable at all. Random draws alone need a median
  110,218 hatches.
- **Level 100 is graduation**, for every species, in about 4.6 days of this
  machine's usage. Evolution is an event along the climb rather than the goal of
  it, so a Pokémon that never evolves is not a special case.
- **Evolution is automatic** where the games give no choice, and asks where they
  do: an item, or a branch. An **Everstone** holds a Pokémon as it is, and queues
  rather than cancels, so taking it off fires everything the level passed.

## Requirements

macOS 26+, Swift 6.3+, and an Xcode.app containing XCTest (see below).

## Build and test

```bash
swift build
./scripts/check.sh              # build + tests
POKEBAR_CORPUS=1 ./scripts/check.sh   # also scan the live corpus and print totals
./scripts/bundle.sh && open dist/PokeBar.app   # run it and see the UI
./scripts/generate-dex.py       # regenerate the Pokédex manifest (rarely; not part of the build)
```

`swift run PokeBar` starts the engine but shows no menu bar item: SwiftUI needs a
bundle identifier to register one, and a bare SwiftPM executable has none. Always
launch through `scripts/bundle.sh`.

`scripts/check.sh` sets `DEVELOPER_DIR` to Xcode.app. Running `swift test`
directly fails with `no such module 'XCTest'` because `xcode-select -p` points at
the Command Line Tools, which do not ship XCTest.

## Contributing / picking this up again

Start with **[CLAUDE.md](CLAUDE.md)** — architecture map, current phase, next
actions, and the measured invariants that are silent if broken.

Then [DECISIONS.md](DECISIONS.md). Every directional call is recorded there with
the measurement or evidence behind it, including the ones that differ from
upstream and why.

Five worth knowing up front:

- **Dedup is load-bearing.** Claude Code logs the same turn repeatedly while
  streaming. No dedup over-counts tokens by 2.22x; keeping the first copy
  under-counts output by 26.5%. Only keep-max on `message.id|requestId` is right.
- **Nothing polls.** Upstream re-scanned on a timer. Here a warm pass over 481 MiB
  reads zero bytes, so idle costs nothing.
- **All nine generations.** Upstream caps at dex #649. Layering three sprite sets
  gets 100% of the National Dex, 98.7% of it animated.
- **The dex is a build-time manifest, and its sprite URLs are pinned to a commit.**
  Sprites are served with `cache-control: max-age=300`, so the disk cache is only
  correct because a pinned URL's bytes cannot change.
- **The collection is an append-only log**, the same shape as the usage ledger, so
  "what did I catch in July" and "what is my actual shiny rate" are answerable
  without changing what is stored. Completion is over the 2,368 sprites that exist,
  not 1,083 x 4: only 102 entries look different by gender.

## Privacy

Reads `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl` locally
to extract token counts. It holds no
credentials and reads no Keychain item.

It writes its own files under `~/Library/Application Support/PokeBar/`:
`usage-state.json`, the token ledger and scan cursors; `game-state.json`, the
collection; a `sprites/` cache; and, only if a save ever fails to decode,
`game-state.unreadable.json`, which is a copy kept so a collection cannot be lost
to a schema change. None of them is ever sent anywhere. Local notifications are posted through
`UNUserNotificationCenter`, which does not involve a server: PokeBar has no push
entitlement and no remote registration.

Two things are fetched over the network, both unauthenticated GETs of public
static files, and nothing is ever uploaded:

- The LiteLLM model-pricing snapshot from `raw.githubusercontent.com`, weekly,
  cached to disk.
- Pokémon sprites from the PokéAPI sprites repo on `raw.githubusercontent.com`,
  on first display, cached to disk permanently.

The Pokédex catalog itself is **not** fetched at runtime: it is a manifest
generated at build time by `scripts/generate-dex.py` and checked in, so a cold
first launch talks to PokéAPI not at all. Sprites are fetched rather than
redistributed, which is what keeps this a personal build with no asset
redistribution. Nothing else leaves the machine.
