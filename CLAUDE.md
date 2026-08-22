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
```

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
  App/PokeBarApp.swift          MenuBarExtra entry point (placeholder UI)
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
  Dex/  UI/                     empty; Phase 3 and 4
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
   makes a "today's usage" readout wrong.

10. **Claude Code is the only usage source.** Codex and Copilot were ruled out with
    reasons in DECISIONS.md. Do not propose re-adding providers unasked.

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

**Phase 1 (usage engine): complete.** 60 tests, 0 failures.

**Phase 2 is next.** Two tasks, either order:

- **Menu bar UI** (`Sources/PokeBar/UI/`). `UsageMonitor` already publishes
  `todayTokens`, `todayCostUSD`, `allTimeTokens`, `coins`, `byModelToday`,
  `state`, `lastUpdated`, `costIsIncomplete`. Nothing displays them yet — the
  current `PokeBarApp` is a placeholder with a dotted-circle icon. Build on native
  `MenuBarExtra` in `.window` style; no hand-rolled outside-click monitor needed on
  macOS 26. Sprite canvases are cropped per species, so aspect ratio needs handling.
- **Live Claude limits.** Hits `api.anthropic.com/api/oauth/usage` and `/profile`
  with the user's own OAuth token. This machine has **no**
  `~/.claude/.credentials.json`, so the token is Keychain-only. Plan: read
  `Claude Code-credentials` once with a prompt, copy into our own Keychain item
  under our own ACL, refresh silently after. This works only because we sign with
  a stable local cert; upstream had to delete their cache because each release
  changed the code signature. **Confirm the approach with the user before touching
  their Keychain** — it will raise a permission prompt.

Then Phase 3 (Pokédex data layer, 1,083 entries) and Phase 4 (game layer).

## Deferred, with reasons in DECISIONS.md

- Trends and burn-rate UI. Per-day data already accumulates in the ledger.
- Alternate forms beyond the 58 regionals (260 more sprites exist).
- Parallelising the cold scan. One-time cost per install.
- App bundle, code signing, LaunchAgent. Not needed until it actually runs daily.

## Open questions for the user

- Coin sinks and egg pricing (Phase 4 balance). Scale is fixed at 1 coin per
  100,000 weighted tokens: ~1,079 coins/day at current usage.
- Whether the floating desktop pet, notifications, and the shop survive from
  upstream's feature set.
- `_audit_poketokenbar/` still sits in the parent directory as reference for the
  PokéAPI client and sprite loader. Delete it once Phase 3 lands.
