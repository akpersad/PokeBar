# PokeBar

A macOS menu bar app that turns Claude Code token usage into a Pokémon
collection. Personal build, not distributed.

Inspired by [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar)
(MIT), which was audited in full first. Some Claude Code parsing logic is lifted
from it, marked in the source where it is.

## Status

Phase 1 usage engine and the Phase 2 menu bar UI: **complete**. Live Claude
limits are next, then the Pokédex.

- [x] Bounded-memory JSONL streaming with resumable offsets
- [x] Claude Code usage parser with keep-max dedup
- [x] Incremental scanner (cold scan 17s, warm pass 0 bytes)
- [x] Accumulating ledger (survives relaunch, credits only growth)
- [x] FSEvents watchers replacing timer polling
- [x] Runtime model pricing with tier-weighted currency
- [x] Menu bar UI (coins in the status item, usage breakdown in the popover)
- [ ] Live Claude limits
- [ ] Pokédex data layer, 1,083 collectible entries
- [ ] Game layer

## Requirements

macOS 26+, Swift 6.3+, and an Xcode.app containing XCTest (see below).

## Build and test

```bash
swift build
./scripts/check.sh              # build + tests
POKEBAR_CORPUS=1 ./scripts/check.sh   # also scan the live corpus and print totals
```

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
  gets 100% of the National Dex, 98.6% of it animated.

## Privacy

Reads `~/.claude/projects/**/*.jsonl` locally to extract token counts. Talks to
PokéAPI and `raw.githubusercontent.com` for sprites, and `api.anthropic.com` for
your own plan limits using your own OAuth token. Nothing else leaves the machine.
