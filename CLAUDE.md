# PokeBar — project instructions

macOS 26 menu bar app that turns Claude Code token usage into a Pokémon
collection. Personal build for one machine, never distributed.

**Read [DECISIONS.md](DECISIONS.md) before proposing any change.** Every
directional call is recorded there with the measurement behind it. If a decision
looks wrong, change it there first, then the code.

---

## Build and test

```bash
./scripts/check.sh                     # build + tests. Use this, not `swift test`.
POKEBAR_CORPUS=1 ./scripts/check.sh    # also scans the live ~/.claude tree
swift build                            # build only
./scripts/bundle.sh && open dist/PokeBar.app   # the only way to see the UI
```

`swift run PokeBar` **cannot show the menu bar item.** SwiftUI registers a
`MenuBarExtra` status item only for a process with a bundle identifier, and a bare
SwiftPM executable reports `CFBundleIdentifier = NULL`. It fails silently: the
engine scans, coins accrue, the process looks healthy, and nothing is drawn. Use
`scripts/bundle.sh`.

`swift test` on its own **fails** with `no such module 'XCTest'`: `xcode-select -p`
points at CommandLineTools, which ships no test framework. `scripts/check.sh` sets
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per invocation. Do not
"fix" this with `sudo xcode-select -s`; it is a global machine setting.

XCTest, not swift-testing. `import Testing` does not resolve in this toolchain.

## Workflow

- Remote `git@github.com-personal:akpersad/PokeBar.git`, authenticates as `akpersad`.
- **Push directly to `main`.** Standing permission for this project only.
- Run `./scripts/check.sh` before pushing.
- No GitHub Actions. macOS runners burn free minutes.

---

## Architecture

```
Sources/PokeBar/
  App/PokeBarApp.swift          MenuBarExtra scene + AppDelegate (.accessory)
  Usage/
    JSONLStreamer.swift         chunked reads, resumable byte offsets
    ClaudeUsageParser.swift     one JSONL line -> UsageEntry, keep-max dedup
    UsageScanner.swift          walks roots, inode-keyed cursors
    DirectoryWatcher.swift      FSEvents -> AsyncStream<Void>
    UsageLedger.swift           durable accumulation, growth-only credit
    UsageMonitor.swift          @MainActor @Observable; the UI binds to this
    UsageModels.swift           TokenCounts, UsageEntry, UsageTotals
  Pricing/
    ModelPricing.swift          bundled rate table, tier multipliers
    PricingCatalog.swift        weekly LiteLLM refresh, disk cache
  UI/
    MenuBarLabel.swift          status item: icon + coin count
    UsagePopover.swift          the menu bar window, all of it
    UsageFormat.swift           pure display logic; where the UI tests live
  Dex/                          empty; Phase 3
```

Data flow: `DirectoryWatcher` tick → `UsageScanner.scan(cursors:)` → new entries →
`UsageLedger.credit(_:pricing:)` → `UsageMonitor.publish()` → UI.

---

## Invariants — do not "simplify" these

Each one is load-bearing and each was measured. Breaking any is silent.

1. **Dedup is keep-max on `message.id|requestId`.** Streaming rewrites the same
   turn as output grows. Measured on the real corpus: no dedup over-counts
   **2.22x**; keeping the first copy under-counts output by **26.5%**. Only
   keep-max is correct.

2. **The ledger credits per-class growth only, clamped at zero.** A turn can
   straddle two scans. Naive accumulation gives 2,705 tokens where the truth is
   1,700. A negative delta must never subtract earned currency.

3. **Coins are frozen at credit time. Cost is recomputed from current pricing.**
   The asymmetry is deliberate. Prices move (the live snapshot reports
   `claude-sonnet-5` at its intro rate while the bundled table holds list), and
   recomputing currency would take earned coins away from the player.

4. **Pricing lookup is exact-key only.** The source carries ten prefixed variants
   of `claude-opus-5`, including `au.anthropic.claude-opus-5` at a 10% markup.
   Any substring match silently picks up a marked-up regional rate.

5. **The watcher arms before the cold scan.** Armed after, a turn finishing during
   the ~17s cold pass writes with nobody listening.

6. **Cursors key on real inode (`systemFileNumber`).** Not
   `fileResourceIdentifierKey`, whose hash is stable only within one process run;
   using it makes every relaunch look like a rotation and forces a full 481 MiB
   re-read.

7. **`JSONLStreamer` withholds a trailing line with no newline**, and the returned
   offset excludes it. Claude Code appends to live files; a half-written line must
   not parse as truncated JSON.

8. **`<synthetic>` model lines are skipped.** Locally generated placeholders, not
   API turns. Measured at 19 lines / 0 tokens, so this is cosmetic, but it keeps a
   bogus row out of the per-model breakdown.

9. **Day bucketing is local calendar, not UTC.** A naive `timestamp[:10]` is what
   makes a "today's usage" readout wrong. The bucket is also chosen *at publish
   time*, which is why the UI calls `refreshDisplayedTotals()` when the window
   opens: without it, a quiet run across midnight keeps labelling yesterday's
   usage "Today". A test pins that re-publishing credits nothing.

10. **Claude Code is the only usage source.** Codex and Copilot were ruled out with
    reasons in DECISIONS.md. Do not propose re-adding providers unasked.

11. **The UI exists only inside an app bundle.** SwiftUI registers a
    `MenuBarExtra` status item only for a process that has a bundle identifier.
    `swift run PokeBar` reports `CFBundleIdentifier = NULL`: the engine scans, the
    ledger credits, `pgrep` finds a healthy process, and the menu bar stays empty.
    Launch through `scripts/bundle.sh`. Measured, at the cost of a wasted
    debugging round.

---

## UI copy rules

Phase 2 onward is user-facing. **No em dashes in anything a user reads** — UI
strings, empty states, tooltips, notifications, screen-reader text. Use a period,
comma, colon, or two sentences. Code comments and commit messages are exempt.

---

## Reference figures

Measured 2026-08-22 against the live corpus. These grow with use; the *properties*
are what matter, not the exact numbers.

| Quantity | Value |
|---|---|
| Corpus | 1,029 files, 481 MiB, `~/.claude/projects` |
| Deduped turns | 13,243 |
| Raw tokens | 1.85B (92.6% cache read) |
| Cold scan | ~17s. Warm pass: **0 files, 0 bytes** |
| Weighted tokens | 3.36B → 33,456 coins at 100K/coin |
| API-equivalent cost | $3,513.84 for 31 days |
| Models in use | fable-5 81%, opus-5 19%, opus-4-8 and sonnet-5 trace |

Tier multipliers: fable 2.0, opus 1.0, sonnet 0.6, haiku 0.2 (input rate relative
to `claude-opus-5`). Within-model ratios are uniform across every Claude model:
output 5x input, cache write 1.25x, cache read 0.1x. A test asserts this.

To re-verify parity independently, `Tests/PokeBarTests/CorpusParityTests.swift`
prints live totals under `POKEBAR_CORPUS=1`.

---

## State

**Phase 1 (usage engine): complete. Phase 2: complete.** 79 tests, 0 failures.
**Phase 3, the Pokédex data layer, is next.**

The app runs: `swift run PokeBar` puts a coin count in the menu bar and the
popover shows coins, today's tokens with a per-model breakdown and the four token
classes, all-time tokens, and the API-equivalent dollar figure. Verified against
the live corpus, which had grown to 33,799 coins over 1.88B tokens by the time the
UI landed. The reference table above is the same day, measured earlier; the corpus
grows while you work, which is the point of the properties-not-digits note.

Views hold no logic. Everything they render goes through `UsageFormat`,
`ModelIdentity` and `ModelBreakdown`, which is where the display behaviour is
pinned by tests. Keep it that way: a fact asserted in a view body cannot be
tested in this toolchain.

**Live plan limits: rejected, not deferred.** Do not propose it again, and do not
add code that reads any Keychain item. `Claude Code-credentials` on this machine
holds only `mcpOAuth`, there is no account token in it, and the user confirmed this
API plan has no meaningful limits to show. Full reasoning, including the incident
that came out of the original plan, is in DECISIONS.md.

Then Phase 3 (Pokédex data layer, 1,083 entries) and Phase 4 (game layer).

## Deferred, with reasons in DECISIONS.md

- Trends and burn-rate UI. Per-day data already accumulates in the ledger.
- Alternate forms beyond the 58 regionals (260 more sprites exist).
- Parallelising the cold scan. One-time cost per install.
- Code signing with a stable identity, and a LaunchAgent. The app bundle itself
  is no longer deferred: `scripts/bundle.sh` builds it, because the UI is
  invisible without one. Ad-hoc signing is enough for a local launch.

## Open questions for the user

- **Phase 3, decide before writing the dex:** is the catalog fetched from PokéAPI
  once at runtime and cached to disk, or generated into a bundled manifest at
  build time? And do sprite files get an on-disk cache, or is the URL cache
  enough? Raised with the user 2026-08-22; they had not answered by session end
  and said either way is fine to decide unilaterally. Blocks nothing: pick one,
  record it here, and go.
- Coin sinks and egg pricing (Phase 4 balance). Scale is fixed at 1 coin per
  100,000 weighted tokens: ~1,079 coins/day at current usage. Note the shape of
  the problem: egg price decides whether 1,083 entries fill in a month or a
  decade.
- Whether the floating desktop pet, notifications, and the shop survive from
  upstream's feature set.
- `_audit_poketokenbar/` still sits in the parent directory as reference for the
  PokéAPI client and sprite loader. Delete it once Phase 3 lands.
