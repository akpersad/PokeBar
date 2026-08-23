# PokeBar

A macOS menu bar app that turns Claude Code token usage into a Pokémon
collection. Personal build, not distributed.

Inspired by [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar)
(MIT), which was audited in full first. Some Claude Code parsing logic is lifted
from it, marked in the source where it is.

## Status

Phases 1, 2 and 3 are **complete**: usage engine, menu bar UI, and the Pokédex
data layer. The game layer is next. Live plan limits were considered and rejected,
with reasons in [DECISIONS.md](DECISIONS.md).

- [x] Bounded-memory JSONL streaming with resumable offsets
- [x] Claude Code usage parser with keep-max dedup
- [x] Incremental scanner (cold scan 17s, warm pass 0 bytes)
- [x] Accumulating ledger (survives relaunch, credits only growth)
- [x] FSEvents watchers replacing timer polling
- [x] Runtime model pricing with tier-weighted currency
- [x] Menu bar UI (coins in the status item, usage breakdown in the popover)
- [x] Pokédex data layer, 1,083 collectible entries (98.7% animated)
- [x] Permanent on-disk sprite cache, pinned to an immutable sprites commit
- [x] An animated species sprite in the status item
- [ ] Pokédex browser UI
- [ ] Game layer (eggs, hatching, coin sinks)

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

Three worth knowing up front:

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

## Privacy

Reads `~/.claude/projects/**/*.jsonl` locally to extract token counts. It holds no
credentials and reads no Keychain item.

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
