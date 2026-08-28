# PokeBar decisions

Every directional call, with the evidence behind it. If a decision here looks
wrong later, change it here first and then change the code.

Prior art: [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) (MIT).
Audited in full before starting. No malicious code, no telemetry, no third-party
dependencies. Parts of the Claude Code parsing logic are lifted from it and
noted as such in the source.

---

## Scope

**Personal use only, not distributed.** This is the decision everything else
hangs off. It removes the Pokémon IP problem entirely: sprites are fetched at
runtime from PokéAPI, nothing is redistributed, nothing is sold. The upstream
project's legal exposure came from shipping a public product built on ripped
game assets, which does not apply here.

**Claude Code, Codex, and Copilot CLI are the usage sources.** Reversed again
2026-08-24, hours after the entry below was written: Copilot CLI usage now
exists on this machine (this very session), so the premise that ruled it out
("that file does not exist... nothing to read") no longer holds. Cursor and the
other upstream providers remain out of scope.

- Copilot CLI logs to `~/.copilot/session-store.db`, a live SQLite database in
  WAL mode, not append-only JSONL like the other two sources. Its
  `assistant_usage_events` table carries `model`, `input_tokens`, `output_tokens`,
  `cache_read_tokens`, `cache_write_tokens` and `created_at` per completed
  request, plus an autoincrement `id`.
- Verified against this machine's live session: `id`, once written, is never
  rewritten. Row 8's 44,036 input tokens read back identically 40+ minutes and
  ten more rows later. A Claude Code turn is rewritten ~2.4 times as it streams,
  which is why *that* parser needs keep-max dedup on `(message.id, requestId)`;
  Copilot needs only a cursor on the monotonic `id`, since a row is written once,
  after the request finishes.
- `input_tokens` reports the whole request, cache classes included, the same
  shape Codex's field has: `claude-sonnet-5` rows measured input_tokens minus
  (cache_read + cache_write) landing at 2-3 on every row, i.e. a handful of
  tokens outside both cache classes, never negative. Same treatment as Codex:
  subtract both cache classes from the total to get ordinary input.
- Scoped **globally**, not to sessions run inside this repository, at the user's
  explicit choice: Claude Code and Codex are not filtered to
  "sessions opened inside PokeBar" either, so scoping only Copilot would be an
  inconsistency, not a parity.
- Pricing reuses the existing bundled table unmodified, keyed on the source's
  exact model string (`claude-sonnet-5`, `gpt-5.6-luna`, ...), which already
  covers every model observed in Copilot CLI's own events on this machine.
- **The same model from two sources must not merge into one ledger row.** The
  user's explicit requirement: `claude-opus-5` used through Claude Code and
  through Copilot CLI should read as two lines, one tagged. Claude Code and
  Codex render identically to today (bare model name, no change to their copy).
  Solved with a ledger-grouping key, not a new field on `TokenCounts`: Copilot
  entries group under `"copilot:" + model` instead of the bare model id, while
  `entry.model` itself stays the exact, unprefixed id pricing needs (invariant 4
  is about the pricing lookup, not the ledger's dictionary key). `ModelIdentity`
  recognises the prefix and renders `"<name> (Copilot)"`; every other caller of
  the ledger key strips it back to the real model id before looking up a rate.
- **The key-to-model function does not return a `UsageSource`, and that is the
  decision, not an omission.** The first cut of this was a `splitLedgerKey(_:)`
  returning `(model, source)`, which meant answering "which source" for every
  unprefixed key by returning `.claudeCode`, including for Codex keys, where it
  is simply false. Nothing read that field, so nothing broke, which is the
  problem: a plausible wrong value sitting in a tuple is what a later reader
  trusts. Replaced with `model(fromLedgerKey:)` and `isCopilotLedgerKey(_:)`,
  which between them answer exactly what a ledger key can answer and nothing
  more. Claude Code and Codex keys are deliberately identical, so "which of
  those two" is not a question the key has the information to settle.
- **A failed read is reported, a missing database is not.** No database is the
  ordinary state of a machine that has never run Copilot CLI, so that is silent.
  Anything past it prints, because the visible symptom of a failed open or a
  failed query is Copilot usage that simply never appears, which is the exact
  silent-failure shape this project keeps getting bitten by. `print` rather than
  a log subsystem, matching how `GameMonitor` reports an unreadable save.
- **On a mid-read failure the cursor still advances to the highest row seen.**
  The tempting alternative, leaving it where it was so the rest is retried, is
  wrong twice over. `ORDER BY id` means the rows read form a contiguous prefix,
  so everything unread is still `> maxID` and arrives on the next tick anyway;
  and a cursor that did not move would re-offer the same rows every tick, which
  is harmless only until they age past the ledger's 2 day growth window, after
  which the re-offer is credited a second time and the coins are frozen. A row
  that cannot be parsed is skipped for the same reason: wedging the cursor on one
  bad row would block every later row for good.
- **`reasoning_tokens` is deliberately dropped.** It is a subset of
  `output_tokens`, not a fifth class. Over the 108 live rows no row has
  reasoning > output, and the row's own `token_details_json` prices input, cache
  read, cache write and output only, with no reasoning line. Adding it in would
  double-count thinking tokens and mint coins for them twice. There is a test,
  because the field is sitting right there in the schema looking like an
  omission.
- **Opened read-only, never `immutable=1`.** Read-only means a concurrent CLI
  write under WAL is never blocked or corrupted by this process. `immutable=1`
  would skip the WAL, and measured here the main database file was 4 KiB against
  a 3.4 MiB WAL, so ignoring the WAL means reading essentially nothing. A
  read-only connection does still create the `-shm` index file when no other
  process holds the database open, which is fine: it is the user's own
  `~/.copilot`.
- Codex was originally excluded because this machine had no rollout JSONL and
  its SQLite `threads.tokens_used` field lacked an input/output/cache split.
  Current Codex now persists `~/.codex/sessions/**/*.jsonl` with a `token_count`
  event after each response. Its `last_token_usage` carries input, cached input,
  cache-write input, output and reasoning output, so it can be integrated without
  SQLite or estimates. `input_tokens` includes both cache classes and reasoning
  is included in output; the parser subtracts the former and does not re-add the
  latter, producing the same four non-overlapping classes as Claude usage.

  Both halves of that were **measured**, not assumed, over the live tree on
  2026-08-24: 3 rollouts, 132 `token_count` events. `input_tokens` minus
  `cached_input_tokens` minus `cache_write_input_tokens` is small and
  non-negative on every event (632 ordinary input tokens across 13.1M total), and
  `total_tokens` equals `input_tokens + output_tokens` on every event, which is
  only true if reasoning is already inside output. The per-response
  `last_token_usage` values sum exactly to the session's final cumulative
  `total_token_usage`, which is what proves no response is skipped or counted
  twice. `CorpusParityTests.testCodexEntriesMatchCumulativeSessionTotals` is that
  check, run against the real tree rather than a fixture.

  Volume is small next to Claude Code: 13.1M tokens, 0.7% of corpus, 97.2% of it
  cache read. That is $7.47 of API-equivalent cost and about 104 coins of
  back-credit, against a standing balance of 33,456. The
  reason to do it properly anyway is that the ratio can change any week, and
  coins are frozen at credit time so a wrong weight can never be corrected.

**No `UsageProvider` protocol, still.** Three sources now, still no shared
protocol. Claude Code and Codex are append-only JSONL and normalize directly
into `UsageEntry`; Copilot is a live SQLite table read through its own parser
with its own (id-based, not byte-offset) cursor type. The three do not share
enough lifecycle behavior to make an abstraction pay for itself, and forcing one
would mean designing a cursor type able to represent both "byte offset in a
file" and "highest row id in a table", which is not a real abstraction, just a
sum type wearing a protocol.

**SQLite dependency added, scoped narrowly.** Reversed from the entry below.
`libsqlite3` ships with the OS, so this is `.linkedLibrary("sqlite3")` in
`Package.swift`, not a package dependency: no new supply chain, no version to
track. Confined to `CopilotUsageParser.swift`; nothing else in the usage layer
knows SQLite exists.

**GPT rates are bundled and never refreshed, and Sol's is a promotional rate.**
Two departures from how the Claude rows work, both deliberate, both with a cost.

`PricingCatalog.parse` keeps bare `claude-` keys only, so the weekly LiteLLM
refresh cannot reach a GPT row. That is the right call for the reason the filter
exists at all (the source carries provider-prefixed and regional duplicates at
marked-up rates), but it means a GPT rate is only ever as fresh as the last
person to edit the table.

That matters more than usual because OpenAI publishes no list price for
`gpt-5.6-sol`. It cut Sol on 2026-08-22 and labels the result promotional
"at least through 2026-11-21", so the promo is the only published number and the
bundled entry carries it. This is the opposite of the `claude-sonnet-5` call
above, where list was chosen over the intro rate precisely so the tier multiplier
would not shift when the promo lapsed. Here there is no list to choose. When the
promo ends, Sol's multiplier goes stale silently and a human has to notice.

Rates re-verified 2026-08-24 against developers.openai.com: Sol $4 / $20 with
cache write $5 and cache read $0.40; Terra $2 / $12; Luna $0.20 / $1.20. Cache
write is 1.25x input and cache read 0.1x input on all three, the same structure
Anthropic uses. Output is not: 5x on Sol, 6x on Terra and Luna, which is why
`testWithinModelRatiosAreUniform` is now scoped to Claude.

The first cut of this branch carried every GPT figure at **half** its real value.
The dollar readout would have been understated by a third, which is cosmetic, but
the Sol tier multiplier came out 0.5 instead of 0.8, which is not: coins are
frozen at credit time. `testCodexTierMultiplierIsDerivedFromTheOpusBaseline`
pins the multiplier rather than only the rates, because the multiplier is the
load-bearing derivation and a rate table can be wrong in a way that looks right.

**macOS 26 floor.** Upstream targets macOS 14 to serve strangers. This targets
one machine (macOS 26.6, Swift 6.3.3), which buys native `MenuBarExtra`,
SwiftData, and the deletion of upstream's hand-rolled outside-click monitor.

---

## Theme and content

**Pokémon, kept.** Once distribution is off the table the risk is gone, so this
is a taste decision rather than a risk decision.

**All nine generations, not the upstream cap of 649.**

Upstream hardcodes `animatedSpeciesIDs = 1...649`. That number comes from Black
and White being the last games with 2D animated pixel sprites; Gen 6 moved to 3D
models. But the cap is more conservative than the assets require. Exact manifests
from the GitHub trees API:

| Sprite set | Base species | Coverage of 1-1025 | Shinies |
|---|---|---|---|
| `versions/generation-v/black-white/animated` | 780 | 76.1% | 784 |
| `other/showdown` | 1011 | 98.6% | 1011 |
| `other/home` | 1025 | 100% | yes |

The gen-v directory holds 780 sprites, not 649, because the community backfilled
Gen 7 (83%) and Gen 8 (60%) in Black/White style. Gen 6 (650-721) and Gen 9
(906-1025) are at 0%. So upstream discards 131 species it could already render.

**Sprite resolution is layered: gen-v, then showdown, then home.** Prefers
authentic Black/White pixel art where it exists, falls back to Showdown's unified
animated set, then to static HOME renders for the last 14. Result: 100% of the
National Dex playable, 98.6% animated, shinies throughout. The cost is up to
three visible art styles in one Pokédex, accepted knowingly.

The 14 species with no animated sprite in any set:
`990-995, 1006, 1008, 1010, 1017, 1022-1025`.

**58 regional forms are separate collectible Pokémon.** Alolan, Galarian,
Hisuian, Paldean. Excluded: Mega and Primal (99), Gigantamax (34), Totem (11),
cosmetic palette swaps such as Minior colours and costumed Pikachu (26), and
transient battle forms. Two reasons: Mega and Gigantamax are temporary
transformations rather than creatures you own, and cosmetic swaps entering at
base rarity would undercut shiny as the rarity signal.

Judgment call inside that set: `darmanitan-galar-standard` is kept,
`darmanitan-galar-zen` is dropped, because Zen Mode is an in-battle state.
Paldean Tauros keeps all three breeds (Combat, Blaze, Aqua are different types).

**Rarity comes from species `capture_rate`; shiny is the only rarity modifier.**
Forms inherit rarity for free, because `capture_rate` lives on the species, not
the variety. Verified: `vulpix-alola` reports species 37, `capture_rate` 190,
BST 299, identical to Vulpix. So Alolan Vulpix is exactly as common as Vulpix,
as intended, with no special-casing.

**Each form is an independent hatch pool entry.** Pool size 1025 + 58 = 1083.
Safe here because only four species have more than one regional form, so the
worst-case line inflation is Paldean Tauros at 4x a single-form peer. This would
not have been safe had Megas and costumed Pikachu been included.

**Evolution stays in-region via `evolved_form_id ?? evolved_species_id`.**
No hardcoded exception table needed. Verified:

| Variety | Target | Resolved via |
|---|---|---|
| `vulpix-alola` | `10104` Alolan Ninetales | form |
| `growlithe-hisui` | `10230` Hisuian Arcanine | form |
| `meowth-galar` | `863` Perrserker | species |
| `qwilfish-hisui` | `904` Overqwil | species |
| `sneasel-hisui` | `903` Sneasler | species |

Targets must be deduped: `qwilfish-hisui` returns three rows for different
version groups. Pikachu legitimately has two targets, `26` Raichu and `10100`
Alolan Raichu, so branching regional evolution is real content that falls out of
the data for free.

---

## Architecture

**Event-driven, not polled.** Upstream re-scans on a 1/2/5/15 minute `Timer`.
This machine's corpus is 481 MiB across 1,029 files. Measured here: a cold scan
is 17s, and a second pass with warm cursors reads **0 files and 0 bytes**. So an
idle minute costs nothing instead of re-reading half a gigabyte, and a finished
turn surfaces in about a second rather than up to fifteen minutes later.

**FSEvents coalescing window is 1 second, not something snappier.** A single
assistant turn produces many writes, not one: streaming rewrites the same
`(message.id, requestId)` as output grows, which is the same behaviour that makes
keep-max dedup necessary. 31,228 raw rows for 13,243 turns is ~2.4 writes per
turn. `kFSEventStreamCreateFlagNoDefer` still delivers the first event of a burst
immediately, so responsiveness does not suffer.

**Ticks carry no payload.** FSEvents coalesces and can drop detail under load, so
an event means "rescan from your cursors", never "this file changed". The scanner
is already a pure function of (roots, cursors), which makes that safe.

**The watcher arms before the cold scan, not after.** The cold pass takes ~17s;
if the stream were created afterwards, a turn completing during those seconds
would write with nobody listening and would not surface until some later,
unrelated write fired an event. Arming first buffers the change and drains it
immediately. Draining redundant ticks is free.

**An accumulating ledger is mandatory, for two independent reasons.** This was
not in the original plan; building the monitor surfaced both.

1. Cursors persist, so a scan only ever returns *newly appended* lines. Totals
   cannot be derived from the latest scan or all-time usage resets to zero on
   every relaunch.
2. A turn can straddle two scans. Dedup within one pass cannot see the partial
   copy the previous pass already counted, so naive accumulation double-counts.
   Measured on the two-pass case: naive gives 2,705 tokens where the true figure
   is 1,700.

The ledger therefore records what was already credited per turn and applies only
the growth, clamped at zero so a shrinking later copy can never subtract earned
currency.

**Growth tracking is retained for 2 days, then dropped.** A turn grows only while
its response streams, so two days is generous. It keeps the in-flight table at
~900 entries rather than ~155,000 for a year of turns. Credited tokens survive
the prune; only growth tracking is lost. Accepted consequence, pinned by a test:
an entry that somehow grew after aging out would be credited twice.

**Per-day history exists as a side effect.** It was deprioritised as a feature,
but per-day/per-model rollup is the natural storage shape for the ledger, so the
data is there if it is ever wanted.

**Cost is recomputed from current pricing; coins are never recomputed.** A
deliberate asymmetry. Cost is an informational estimate and should track today's
rates. Coins are earned, so they are read off the ledger's frozen total.

**Cursors keyed on real inode, not `fileResourceIdentifierKey`.** The latter is
documented as opaque and its `hash` is stable only within a process run, which
would make every relaunch look like a file rotation and force a full re-read.

**Dedup is keep-max on `message.id|requestId`.** Lifted from upstream, and the
single most important correctness rule in the parser. Streaming and session
resume log the same turn many times; `input` and `cacheRead` are fixed across
copies but `output` grows as the response completes. Measured on this corpus:

| Strategy | Grand total | Verdict |
|---|---|---|
| no dedup | 4,096,695,971 | 2.22x over-count |
| keep first copy | 1,844,881,134 | under-counts output by 26.5% |
| **keep max total** | **1,848,085,379** | correct |

Both naive strategies are badly wrong, in opposite directions. This is the
knowledge that justified lifting the parser rather than rewriting it.

**Fixed upstream bug:** the dedup key was
`(message.id ?? "") + "|" + (requestId ?? "")`, which yields `"|"` when both are
absent and collapses every id-less line in the corpus into one entry. Replaced
with a caller-supplied per-line fallback identity.

**`<synthetic>` turns are skipped.** Claude Code writes that model name for
locally generated placeholders. Measured at 19 lines carrying 0 tokens, so this
changes no total; it only keeps a bogus row out of the per-model breakdown.

**Day bucketing is local calendar, not UTC.** Deliberately differs from a naive
`timestamp[:10]`, which is what makes a "today's usage" readout correct.

**Pricing is fetched at runtime with a bundled fallback.** Upstream hand-maintains
a table and ships a commit per new model. On this machine that table has no
`claude-opus-5` and no `claude-sonnet-5` entry, covering **342,492,125 tokens,
18.5% of total volume, silently priced at $0.00**. Unpriced models must surface
as unknown, never as free; an unknown model still earns, at baseline tier.

Source: the LiteLLM snapshot, verified 2026-08-22 to agree exactly with the
Anthropic pricing reference on every model in use. Refreshed weekly, cached to
disk, bundled table as the floor.

**Lookup is exact-key only, never fuzzy.** The source carries ten prefixed
variants of `claude-opus-5` alone — `au.anthropic.claude-opus-5` at a 10% markup,
plus `azure_ai/`, `vertex_ai/`, `openrouter/`, and regional `us.` / `eu.` / `jp.`
forms. Claude Code writes the bare id, so any key containing `.` or `/` is
discarded rather than risking a marked-up regional rate.

**The bundled `claude-sonnet-5` entry is list price ($3/$15), not the
introductory $2/$10 that lapses 2026-08-31**, so the tier multiplier does not
shift underneath us when the promo ends.

---

## Currency

**The currency is raw token count, every class weighted equally.** Not
cost-weighted across token classes. Rationale, in the user's words: the Anthropic
console reports these tokens regardless of where they came from, so they count.

Known and accepted property: **92.6% of raw volume is cache reads**, so currency
accrues fastest during long-context sessions. Measured on this corpus:

| Token class | Tokens | % of tokens | % of cost |
|---|---|---|---|
| input | 11,155,938 | 0.60% | 3.16% |
| output | 12,092,882 | 0.65% | 16.06% |
| cache write | 113,579,486 | 6.15% | 36.57% |
| cache read | 1,711,257,073 | **92.60%** | 44.21% |

A cost-weighted alternative would have given output 24.5x more influence. Chosen
against, deliberately: the goal is to mirror reported consumption, not to model
effort.

**Models earn at different rates, by tier.** Multiplier = model input rate
divided by `claude-opus-5`'s. Fable 2.0, Opus 1.0, Sonnet 0.6, Haiku 0.2.
This is the reason the pricing table is load-bearing rather than cosmetic.

Useful fact that makes this cheap: **within-model ratios are uniform across every
current Claude model** — output is always 5x input, cache write 1.25x, cache read
0.1x. Only the per-model multiplier differs. A test asserts this, and the snapshot
parser uses it as a per-missing-field fallback only.

**Scale: 1 coin per 100,000 weighted tokens.** Locked. 31 days of real usage =
1.86B raw tokens, 3.36B weighted, ~108M weighted/day, which reads as ~33,456
coins lifetime and ~1,079 coins/day. Raw weighted counts are far too large to
display directly; per-1M was too coarse and 1:1 unusable.

**Currency must be frozen at earn time, not recomputed.** Prices change: the
runtime snapshot currently reports `claude-sonnet-5` at the introductory $2,
while the bundled entry is list $3, so a refresh moves that tier from 0.6 to 0.4.
Recomputing historical currency from live pricing would take coins away from the
player. The persisted game state increments as new entries are observed, using
the pricing in effect at that moment, and never re-derives.

**The dollar readout ships as an optional stat, clearly labelled hypothetical.**
31 days = **$3,513.84** API-equivalent. On a subscription that is not money
spent; it is subscription value realised.

**Live plan limits: rejected 2026-08-22.** Not deferred. No limits readout, no
Keychain access, no `api.anthropic.com` call, and no credential handling anywhere
in the app.

Two independent reasons, either sufficient:

1. **The token is not there.** The plan assumed `Claude Code-credentials` held a
   `claudeAiOauth` blob. Inspected on this machine, that item has exactly one
   top-level key, `mcpOAuth`, holding per-server OAuth state for the user's MCP
   servers. There is no Anthropic account token in it, so there is nothing to
   authenticate `/api/oauth/usage` with.
2. **This plan has no meaningful limits to display.** The user's answer when asked
   what the feature was for: there are no real limits on this API plan. A gauge of
   a limit that does not bind is a gauge of nothing, which also explains reason 1.
   Consumer OAuth is not how this machine authenticates.

It was never load-bearing either way: currency is tier-weighted token count frozen
at credit time, so the dex and the game layer are indifferent to rate limits. And
`/usage` in Claude Code already shows this number in the terminal the user is
already in. Against that: an undocumented internal endpoint that can change shape
without notice, plus the only credential-handling code in the app.

**Incident, kept as the lesson.** Pursuing the original plan, a one-time
`security` handoff copied that item into `PokeBar-claude-oauth` created with `-A`,
which put unrelated MCP client secrets and refresh tokens somewhere any process
running as the user could read without a prompt. It existed for about four minutes
and was deleted; the source item was never modified. The mistake was writing the
plan around an assumed credential shape instead of inspecting the shape first.
Inspect the data before designing around it, which is the same rule the rest of
this document is built on.

**If limits are ever wanted anyway**, the blocker to solve first is the Keychain
ACL being bound to the requesting binary's code signature: an unsigned binary
relinked by every `swift build` re-prompts forever, which is the same wall upstream
hit from the other side when each release changed their signature. A stable local
signing certificate is the fix, and it is available precisely because this is not
distributed.

---

## Pokedex data layer

Both open questions from the Phase 2 close-out are settled here. The user
delegated them explicitly, so they were decided on measurement.

**The catalog is a build-time manifest, not a runtime fetch.**
`scripts/generate-dex.py` produces `Sources/PokeBar/Dex/Resources/pokedex.json`,
381 KiB, checked in. Four reasons, in descending weight:

1. **A cold first launch needs no network and nothing third-party to be up.**
   A runtime fetch makes the dex, and therefore the whole game layer, depend on
   PokeAPI *and* the GitHub trees API answering. Upstream needed a GraphQL path, a
   REST fallback, a session-scoped rebuild flag, a partial-index guard and a
   self-healing disk cache to paper over exactly this. A manifest deletes all of
   it.
2. **The generator can assert what a fetch could only hope for.** It verifies
   1,083 entries, 58 regional forms, 14 static-only species and the per-set sprite
   coverage before it writes anything. This already paid for itself: the
   regional-form assertion caught `pikachu-alola-cap`, a costumed Pikachu that a
   regional-suffix match happily accepts as an Alolan form.
3. **The sprite manifest is not fetchable cheaply at runtime anyway.** Which
   sprite files exist per set comes from the GitHub trees API, which is 60
   requests/hour unauthenticated, and whose recursive whole-repo tree is 62,142
   blobs returned with `truncated: true`. Truncation is silent, and would report
   real sprites as missing. Build time fetches six path-addressed subtrees
   instead, each complete, and fails loudly if any comes back truncated.
4. **The data is static.** A new generation is a years-scale event. When one
   lands, raise `MAX_SPECIES`, re-run the generator, and update the expectations
   deliberately.

Metadata is bundled; **sprites are still fetched at runtime and never
redistributed**, which is what kept the IP question closed in the first place.

**Sprites get an explicit permanent disk cache, not `URLCache`.** Measured: every
sprite in all three sets is served by `raw.githubusercontent.com` with
`cache-control: max-age=300`. Five minutes. A URL-cache-backed dex would
re-download the entire wall of sprites every five minutes of browsing and would
show nothing at all offline.

What makes a *permanent* cache safe is that sprite URLs are pinned to a sprites-repo
commit SHA (`c10459b9b0129eaca5c5d9b1cac65336debb1d08`), so a given URL's bytes can
never change: no revalidation, no ETag round-trip, no expiry. Upstream cached to
disk too, but against `master`, so its cached files could silently drift from the
branch they were named after. Cache keys carry the sprite set (`471-gen5.gif`), so
regenerating the manifest and moving an entry between sets cannot serve stale art
under a reused name. Writes are atomic, because a torn write is the one corruption
a never-expiring cache would otherwise never repair.

**The commit is a constant in the generator, not `master` resolved at run time.**
Changed 2026-08-23. The generator used to fetch `master` on every run, which makes
re-pinning the entire dex a side effect of any routine regeneration: every sprite
URL changes, and whether that is safe depends on the disk cache, which keys on the
sprite set rather than the commit. Re-pinning is a decision, so `--repin` makes it
one and prints the old and new SHAs. The pin has not moved: `master` was still at
`c10459b9` when this was written, so nothing about the shipped dex changed.

Nothing is prefetched. At 1,083 entries x 2 variants a full prefetch is ~2,166
files, so sprites load on first display instead.

**Every figure in this document's content section reproduced exactly**, which is
why the manifest is trusted: 1,025 species, 58 regional forms, pool 1,083, gen-v
780 base sprites (76.1%), showdown 1,011 (98.6%), home 1,025 (100%), and the 14
with no animated sprite in any set at `990-995, 1006, 1008, 1010, 1017, 1022-1025`.
Resolution lands 816 entries on gen5, 253 on showdown, 14 on home: **98.7%
animated**. Two entries in the pool have no shiny sprite.

Three data-model traps found while verifying, each of which silently produces a
wrong dex rather than an error:

- **`pokemonform.id` is a different id space from `pokemon.id`.** Alolan Vulpix is
  pokemon 10103 and form 10205. The evolution table's `base_form_id` and
  `evolved_form_id` are in the *pokemon* space, so joining on form id returns zero
  rows for every regional form. The first attempt here did exactly that and
  reported no regional evolutions at all.
- **A regional form need not carry a regional suffix.** Hisuian Basculin is
  `basculin-white-striped`. A suffix match finds 57 of the 58.
- **Names carry typography.** `Farfetch’d` uses U+2019, and `Nidoran♀` a gender
  sign. Display names are taken from PokeAPI rather than title-cased off the slug,
  which gets `farfetchd`, `mr-mime` and `nidoran-f` all wrong.

`evolved_form_id ?? evolved_species_id` was re-verified row by row and holds:
Alolan Vulpix and Hisuian Growlithe resolve through a form target, Galarian Meowth,
Hisuian Qwilfish and Hisuian Sneasel through a species target, `qwilfish-hisui`
returns three rows that dedupe to one, and Pikachu returns two genuinely distinct
targets (Raichu and Alolan Raichu).

**Rarity bands are a display label, not the hatch weighting.** Bands come from the
species' `capture_rate` with legendary and mythical as a floor rather than a band,
because some legendaries are catchable enough to land in a common band on capture
rate alone, and a legendary labelled "Common" reads as a bug. The measured
distribution: common 238, uncommon 187, rare 493, epic 68, legendary 74, mythical
23.

That `rare` bucket being the largest is a property of the source, not a mistake.
`capture_rate` is quantized hard: 327 of 1,083 entries share the value 45, and 86%
sit at 45 or above, so *any* set of bands puts a 30-45% lump in whichever band
contains 45. Three schemes were evaluated and all three did. **Phase 4 should
therefore weight the hatch pool on the raw `captureRate`, where the number behaves
like a smooth weight, and use the band only for the word shown to the player.**

**The status item animates, which is a deliberate exception to the no-polling
rule.** Measured: a gen-V sprite is 51 to 129 frames with 60 to 200 ms delays, so
animating redraws the status item at 5 to 16 fps for as long as the app runs. In a
project whose usage engine reads 0 bytes on an idle minute, that deserves naming
rather than hiding. It is accepted because the moving sprite is the point of the
app, and an 18pt bitmap blit is cheap in a way that re-reading 481 MiB of JSONL is
not. Two concessions: frames are cropped and scaled once at decode time so each
tick is a pointer swap rather than an image resize, and Low Power Mode drops to a
single still frame.

**Sprite geometry is two rules, both measured, both silent if broken.**

*Aspect-preserving fit is mandatory, and the menu bar fits to height rather than to
a square box.* Two separate points.

First, aspect ratio must be preserved at all: gen-V animated GIFs have a
per-species canvas that is not square, while every static sprite is a uniform
96x96. So stretching to fill a square box is invisible on the static path and
distorts only the animated one, which is the path the menu bar uses:

| Entry | gen-V GIF | static PNG |
|---|---|---|
| Bulbasaur #1 | 37x38 | 96x96 |
| Pikachu #25 | 50x46 | 96x96 |
| Gengar #143 | 74x75 | 96x96 |
| Spoink #325 | **36x66** | 96x96 |
| Lucario #448 | 47x63 | 96x96 |
| Glaceon #471 | 76x54 | 96x96 |

Spoink stretched to square renders 1.83x too wide.

Second, the *box* was the wrong constraint. A square box preserves aspect ratio but
still shrinks every wide sprite, because a horizontal menu bar limits height and has
width to spare. Glaceon's 76x54 canvas in an 18pt square box renders 18 x 12.79 and
fills 12.79pt of a 22pt bar. This shipped that way and the user caught it on screen
immediately, which is the argument for asking someone to look rather than inferring
from a populated cache.

The fix is to fit to a height and let width run free up to a cap. Shipping values
are 20pt and 33pt, in `MenuBarSprite`. Measured over a 155-entry sample, aspect
ratio width/height:

| | ratio | width at 20pt tall |
|---|---|---|
| widest: Galarian Linoone 82x41 | 2.00 | 40.0pt |
| p95 | 1.61 | 32.2pt |
| median | 1.00 | 20.0pt |
| tallest: Farigiraf 62x128 | 0.48 | 9.7pt |

A 33pt cap leaves 95% of the pool at full height; the few wider sprites give up
height rather than pushing the menu bar around. The cap only ever scales down, so a
narrow sprite is never stretched to reach it.

**Height and cap are coupled, and the coupling is a trap.** A sprite wider than the
cap gives up height, so raising the height alone makes wide species *smaller*. The
invariant is `maxWidth >= height * p95Aspect`; a test asserts it. This is why the
18 -> 20 bump moved the cap 30 -> 33 in the same change.

**The ceiling on height is 22pt, and it is not the visible menu bar.** Measured:
`NSStatusBar.system.thickness` is 22, and a status item button reports 22. The
visual menu bar on this notched display is 33pt with a 32pt safe-area inset, but
that space belongs to the system, not to status items. 20pt therefore leaves 1pt of
clearance each side. System menu bar icons sit nearer 18; 20 is deliberately a
little bolder than native because the sprite is the app's whole point rather than a
control affordance.

**Not cropping animation frames costs nothing here, and that was checked rather
than assumed.** Glaceon's per-frame content height is 50-54px against a 54px canvas
across all 129 frames, so 93-100%, mean 96%. The canvas really is the union of the
animation, so the no-crop rule leaves no visible margin to reclaim.

**Approved by the user on screen, 2026-08-22, and therefore closed.** Two rounds
were reviewed: the original 18pt square-box fit, which the user correctly read as
too small, and the 20pt height-fitted version, which was approved as shipped. The
sizing constants are settled. Reopen them only on request.

The process point worth keeping: the first round was reported as working on the
strength of a populated sprite cache, which proved the plumbing and said nothing
about how it looked. `screencapture` is blocked for the terminal on this machine,
so the only way to verify rendered pixels is to ask the user to look, and the
first round did not. That is the third instance in this project of something being
called verified on weaker evidence than the wording implied, after the invisible
menu bar item and the unexamined Keychain blob. Same lesson each time: name what
was actually checked.

The cost is that the status item's width now depends on which species is shown.
Accepted: the species changes once a day, not once per usage update, so this does
not reintroduce the per-update width shuffle that compact coin formatting exists to
prevent. The square-box fit is kept in `SpriteGeometry` because a dex grid, if one
is ever built, genuinely does tile squares.

*Cropping applies to stills only.* On every gen-V sprite measured, the union of the
per-frame content boxes is exactly the full canvas, so cropping an animation buys
nothing, and cropping each frame to *its own* box would be actively wrong: the
per-frame boxes differ (10 to 57 distinct boxes within one sprite) and the sprite
would visibly jitter as its bounds moved under it. Stills are the opposite case:

| Sprite | canvas | content | fill |
|---|---|---|---|
| Pikachu static PNG | 96x96 | 39x46 | **19%** |
| Spoink static PNG | 96x96 | 26x51 | **14%** |
| Pecharunt HOME PNG | 512x512 | 392x300 | 45% |
| Pikachu gen-V GIF | 50x46 | 39x46 | 78% |
| Spoink gen-V GIF | 36x66 | 26x51 | 56% |

An uncropped static sprite in an 18pt status item draws a ~9pt subject.

Scaling uses nearest-neighbour. These are pixel-art sprites and smoothing them
turns crisp pixels to mush, most visibly at menu bar sizes.

**Frame extraction is index-by-index, which is safe here and would not be in
general.** Every gen-V sprite measured stores full-canvas frames with no disposal
metadata. An optimised GIF storing partial frames would need compositing, and
these do not.

**The featured pick is a placeholder with a deliberate seam.** Until the game layer
exists there is no "active" Pokemon, so the status item shows a species chosen
deterministically from the local day: stable across relaunches within a day,
different tomorrow. Phase 4 replaces `Pokedex.featured(on:)` with the player's
active or most recently hatched Pokemon and nothing else has to change. The day
ordinal is multiplied by a large constant, which overflows into negatives, so the
index uses a non-negative modulo; a test walks 450 days including pre-epoch dates
because `%` in Swift keeps the dividend's sign.

**The dex is loaded through `Bundle.module`, and a test asserts it loads.** SwiftPM
emits resources as `PokeBar_PokeBar.bundle` beside the binary, and `scripts/bundle.sh`
copies it into `Contents/Resources`. Miss that step and `Bundle.module` finds
nothing: the app launches, scans, credits coins, and shows no Pokemon at all. That
is the same silent shape as the missing-bundle-identifier bug this project already
paid a debugging round for, so it is pinned by a test rather than trusted.

**Generator HTTP goes through `curl`, not `urllib`.** The python.org framework build
on this machine has no CA bundle installed, so every `urllib` HTTPS handshake fails
with `CERTIFICATE_VERIFY_FAILED`. `curl` uses the system trust store. The
alternative was running Python's `Install Certificates.command`, a global machine
change, and this project already declines those for the same reason it scopes
`DEVELOPER_DIR` per invocation instead of running `sudo xcode-select -s`.

---

## Game layer (Phase 4)

Decided 2026-08-23 with the user, before writing any of it. Balance knobs that
remain open are listed at the end rather than guessed at.

**Completion must be reachable, so acquisition is not purely random.** This is the
decision the measurement forced. Filling the dex by weighted random draw is the
coupon-collector problem, and `capture_rate` weighting is brutal: the rarest
entries are ~85x less likely than the commonest, since the rate spans 3 to 255.

| Draw model | Median draws to see all 1,083 |
|---|---|
| Uniform | 7,830 |
| Capture-rate weighted | **168,729** (21.5x worse) |

At ~1,080 coins/day that is 4.3 years even at 10 coins per egg, and 43 years at
100. (Hatching actually draws only from the 570 hatchable entries, since 513 are
evolution-gated. That is measured further down and it barely helps: 110,218 hatches,
a mere 1.5x improvement, because the rarest entries are largely non-evolving
legendaries that stay in the hatchable pool. The conclusion is the same either way.) So "collect all of them" is not achievable by random draws at any sane price,
and no amount of price tuning fixes it. Three exits were considered: abandon
completion as a goal (which is upstream's answer, see below), flatten the rarity
weighting, or add a non-random path. **The non-random path was chosen**, because it
keeps `capture_rate` meaningful as rarity while still letting a patient player
finish.

The mechanism: a hatch that yields a variant already owned converts into a
currency, and that currency buys a *chosen* entry outright. Rarity scales the
conversion, so a duplicate legendary is worth more than a duplicate Caterpie. Luck
sets the pace early, and the guaranteed path closes out the tail that luck never
would.

**Targeted re-roll is the shiny hunt.** Any already-captured species can be
re-rolled, paying to hatch that same species again for a chance at a variant not
yet owned. This is what makes shiny hunting a deliberate activity rather than
something you wait for, and it is the same mechanism as the non-random path pointed
at one species instead of the whole pool.

**Reference odds:** upstream hatches shiny at 1/64, and 1/48 holding the Shiny
Charm, with the explicit note that the mainline 1/4096 would mean never seeing one
in a desktop app's lifetime. That reasoning holds here and the rates are a
reasonable starting point.

### What "caught" means

**An append-only log of catch events, with the per-species view derived from it.**
Not a `Set<Int>` of ids and not a per-species record struct.

The reason is local: this is exactly the shape `UsageLedger` already uses, which
accumulates append-only and derives its views at publish time, and which got
per-day history "as a side effect" for free. The same bet pays off twice. A boolean
set answers one question and loses everything else; a per-species struct needs a
migration for every question nobody thought of yet; a log can answer "what did I
catch in July", "what is my actual shiny rate", or "how long between duplicates"
without changing the stored shape.

**Upstream's shape, for reference,** since it is the same idea and worth not
reinventing. Their `DexEntry` carries a `UUID` per *raise* rather than per species,
plus `baseID`, `finalID`, `chainOrder`, `rarity`, `caughtAt`, `isShiny` and
`nature`, and a separate accumulator folds those rows by species into
`isGraduated` / `isRaising` / `isShiny`. Their dex is a log of completed raises with
a derived species view.

**`nature` is dropped.** Upstream stores a nature per Pokemon because natures feed
stat growth. PokeBar has no stat raising, so a nature would be recorded, displayed
nowhere, and affect nothing. Dead data, and it is easier to add later than to
explain now.

### Variants: what counts as a distinct thing to own

**A variant exists if and only if its sprite file exists.** Data-driven, no
special-casing, which is the same rule the sprite-set resolution already follows.

The user's model was up to four per species: a male/female pair and a shiny
male/female pair. That is real, but it applies to far less of the pool than it
sounds, and the data had to be checked before designing around it. Measured against
the pinned sprites commit and cross-checked against PokeAPI:

| Variants available | Entries | |
|---|---|---|
| 4 (normal, shiny, female, shiny female) | **102** | 9.4% of the pool |
| 2 (normal, shiny) | **979** | 90.4% |
| 1 (normal only, no shiny) | 2 | |
| | **2,368** | total distinct ownable sprites |

Two independent sources agree on the 102: the `female/` sprite directories hold
102-104 files, and PokeAPI reports `has_gender_differences` for exactly 102 species.

**Confirmed against the manifest, 2026-08-23**, and it needed resolving per entry
rather than per directory: the female directories disagree across sets (gen-v holds
104 female and 98 shiny female, showdown 102 and 102, home 103 and 103), so the
answer depends on which set an entry actually resolves to. Resolved that way the
totals land exactly on the figures above: 102 entries with four variants, 979 with
two, 2 with one, **2,368 ownable sprites**. No entry has a female sprite without a
shiny female one, so the manifest carries a single `female` flag and the generator
fails rather than guessing if that ever stops being true.
Of 1,025 species, 155 are genderless outright, 26 are male-only and 37 female-only;
807 have both genders but only 102 of those *look* different.

So for 90% of the dex there is no separate female sprite, and treating male and
female as distinct collectible slots would show the identical image twice and
inflate the completion target with entries that are visually indistinguishable.
**Completion is therefore defined over the 2,368 distinct sprites, not over
1,083 x 4.**

Gender is still recorded on every catch event, because in an append-only log that
costs nothing and it keeps "I hatched a female Bulbasaur" answerable. It simply does
not create a slot to fill unless a distinct sprite backs it.

### Levels, XP and graduation

Decided 2026-08-23. Evolution-by-XP is **in**; stats are out.

**Graduation is level 100, for everyone.** This answers the awkward case directly:
a Pokemon that never evolves is not a special case, because evolution is an *event
along the climb*, not the goal of it. Lapras and Mewtwo climb the same ladder as
Bulbasaur; they simply pass no evolution thresholds on the way. Dex entries unlock
as thresholds are crossed, and the hatched species unlocks the moment it hatches.

**One shared curve: `totalXP(level) = 100 x level^2`, so level 100 is 1,000,000 XP.**
Same numbers for every species, as requested. Cubic (the mainline "Medium Fast"
n^3) was tried first and rejected: it front-loads so hard that every evolution is
done in the first 5 hours of a 4.6-day climb, leaving four days of nothing. Squared
keeps per-level cost strictly increasing while spreading the interesting part out.

**Rate: 1 XP per 500 weighted tokens.** At this machine's measured ~108M weighted
tokens/day that puts a full 1 to 100 climb at **4.63 days**, inside the 4-5 day
target.

| Level | Total XP | Time from level 1 | XP for next level |
|---|---|---|---|
| 10 | 10,000 | 1.1 h | 2,100 |
| 16 | 25,600 | 2.8 h | 3,300 |
| 20 | 40,000 | 4.4 h | 4,100 |
| 30 | 90,000 | 10.0 h | 6,100 |
| 36 | 129,600 | 14.4 h | 7,300 |
| 50 | 250,000 | 27.8 h | 10,100 |
| 64 | 409,600 | 45.5 h | 12,900 |
| 100 | 1,000,000 | 4.6 d | - |

Per-level cost runs 300 XP for 1->2 up to 19,900 for 99->100, a 66x spread. Cubic
would have been 4,243x.

This lines up with the measured evolution levels (365 edges carry a `min_level`;
earliest 7, median 30, latest 64): first evolution inside a working session, the
median evolution overnight, every evolution in the game done by day two, then
2.7 days of optional climbing for a favourite.

**XP and coins are parallel derivations of the same tokens, never a shared pool.**
This is the structural answer to "don't make me train for a week and then save for
another week." Every weighted token simultaneously grants XP to the active Pokemon
*and* mints coins. They do not compete, there is no allocation choice, and a full
climb passively earns ~5,000 coins while it happens. Mechanically this is the same
move `UsageLedger` already makes for coins, so XP is a second credit on the existing
event rather than a new subsystem.

**The binding constraint is raising time, not coins.** Worth stating plainly because
it corrects an earlier assumption in this document that egg price is the pacing
knob. It is not. Only one Pokemon is active at a time, so throughput caps at roughly
1.7 raises/day if swapping at level 36, no matter how many coins are banked. Coins
therefore accumulate faster than eggs can consume them, and the useful sinks are the
ones that buy *time* (Rare Candy) or *certainty* (targeted pick), not the ones that
buy more eggs.

**Still true after the team landed, and 5x weaker.** Six members raising at once
means six evolution lines progressing at once, so the cap is nearer 8.5 raises/day
than 1.7. Raising time is still the bottleneck and coins still outrun eggs, but by
less, and Rare Candy is relatively weaker for it. Watch it; do not pre-emptively
reprice it. The reason the inflation is affordable is directly below.

**Switching Pokemon is free and unrestricted, with no level gate.** A gate at level
20 was considered and rejected. With 570 hatchable entries drawn at random, hatching
something you do not care about is the common case, not the exception, and a gate
punishes the player for the game's own randomness. The real cost is already built
in and needs no rule: swapping abandons that individual's levels, and the next
hatch starts at 1. Whatever was reached stays in the log, so switching is never
destructive to the collection, only to the individual. Shiny re-rolling is governed
by the re-roll price, which is a separate knob from swapping.

**The abandon-levels half of that is reversed, and shipped 2026-08-24.** The
gate rejection stands; what does not is treating lost levels as the cost. The
user's words: "I shouldn't lose my progress on Charizard if I want to switch out
to another pokemon for a week." Levels now persist per individual, in
`Trainer.roster`, and switching costs *nothing at all*. Details under "the roster"
below.

### Evolution triggers: two thirds are levels, one third needs a rule

Measured over the 513 evolution edges that land in the collectible pool. **513 pool
entries, 47.4% of the dex, are reachable only by evolving something**, so these
rules are load-bearing rather than edge-case tidying. The hatch pool is therefore
the other 570.

| Trigger | Edges | Rule |
|---|---|---|
| `level` | 364 | The games' own `min_level`. Range 7 to 64, median 30 |
| `item` | 69 | Requires the item. **23 distinct stones**, so the shop has real stock |
| `trade` | 26 | No trading in a single-player menu bar app. **Requires a Linking Cord**, which is canonical since Gen 9 |
| `substituted` | 54 | Friendship, time of day, location, and the exotic one-offs. **Evolves at level 36** |

**The substitution level is 36.** The user's call, and a defensible one: 36 is the
second most common real evolution level in the data (27 edges, behind 30's 31) and is
the canonical second-stage level, so it lands on a number the games already use
rather than an invented one. It also sits at 14.4 h into the climb, which puts these
evolutions after the ordinary first-stage crowd at 16 to 30 rather than mixed in with
them. That ordering is the right one: friendship, trade and tower-of-darkness
evolutions are late or deliberate acts in the games, not things that happen to you on
the way past level 16.

30 was the first proposal, on the grounds that it is the measured median. Rejected in
favour of 36 for the reasons above.

Substitution is labelled in the data rather than folded in silently: there is no
honest way to model friendship or a tower of darkness in a token counter, and
silently dropping 54 edges from a dex that advertises 1,083 entries would be worse.
`trade` keeps its own trigger for the same reason, even though mechanically it is
just an item requirement.

**Three refinements fell out of building it, each of which moves content out of the
substitution bucket and into something real.**

*Multi-row edges are resolved by preference, not by first-wins.* Thirteen edges carry
several rows (one per version group) and twelve of those disagree. The order is: a
real `min_level` (lowest) beats an item, an item beats nothing. That is what turns
Kubfu into a Scroll of Darkness purchase rather than a tower-of-darkness
substitution, Eevee's Leafeon and Glaceon into a Leaf Stone and an Ice Stone rather
than two location guesses, and Magnezone and Probopass into Thunder Stones.

*Classification is on `min_level`, not on the trigger name.* Nincada -> Shedinja is
trigger `shed` and Tandemaus -> Maushold is trigger `other`, but both carry real
levels (20 and 25), so both keep them.

*The edge join was wrong, and it was wrong silently.* `base_form_id` is null on 495
of 553 rows, and the original generator fell back to
`pokemonspecies.evolves_from_species_id` for the *whole edge*, which is a
species-space answer to a pokemon-space question. It got 11 edges wrong in each
direction:

- It claimed ordinary **Meowth evolves into Perrserker**. It is Galarian Meowth that
  does. Same for Farfetch'd, Mr. Mime, Wooper, Qwilfish, Sneasel, Corsola, Linoone,
  Basculin and Yamask: ten ordinary species carrying their regional form's evolution.
- It left **Alolan Exeggutor with no incoming edge at all**, along with Alolan
  Marowak, Galarian Weezing, Hisuian Typhlosion, Galarian Mr. Mime, Hisuian Samurott,
  Hisuian Lilligant, Hisuian Braviary, Hisuian Sliggoo, Hisuian Avalugg and Hisuian
  Decidueye. These evolve from an *ordinary* base, so under the old join nothing in
  the pool could produce them and no amount of play would ever fill those tiles.

Neither half shows up as an error. The fix is to take the base from the row where the
row has one, and consult the species table only as a backstop for a row that declines
to say. Exactly one species evolves from something and has no evolution row at all
(Meltan -> Melmetal), and that is asserted rather than assumed. The generator now
also asserts that every entry is reachable from a hatchable seed, which is the
property both halves of the bug violated.

This is why the pool figures moved: hatchable 581 -> 570, gated 502 -> 513.

**Done, 2026-08-23.** `pokedex.json` replaces the old bare-target-id `evolvesTo`
with an `evolutions` array carrying `to`, `trigger`, `minLevel`, `item` and
`itemName` per edge, with the substitutions applied at generation time, so the app
compares a level and checks an item and never has to know what a tower of darkness
is. The manifest grew 325 -> 381 KiB. `Evolution.isAvailable(atLevel:items:)` and
`Pokedex.availableEvolutions(of:atLevel:items:)` are the read side, and
`Pokedex.hatchable` is the 570-entry draw pool.

### Prices, v1

Starting values, not final. The XP curve above is derived from a stated constraint
and should hold; these are a coherent first pass and want revisiting once the loop
is actually playable.

| Thing | Price | Reasoning |
|---|---|---|
| Egg | **300 coins** | ~6.7 h of usage. Cheap on purpose: eggs must never be the bottleneck, since raising time already is. Leaves ~580 coins/day for everything else at level-36 swapping |
| Rare Candy | **250 coins** for 10,000 XP | The most important sink, because it buys the scarce resource. 1 coin of accrual equals 200 XP, so 10,000 XP is "worth" 50 coins; the 5x markup is upstream's, and makes candy a luxury. Naturally strong early (+4.1 levels at L10) and weak late (+0.6 at L90), like the games |
| Evolution stones | **400 coins** | Superseded. 23 items, gating 69 edges. Cut to 100 on 2026-08-28; see "Evolution items are 100 coins" below |
| Linking Cord | **400 coins** | Superseded. Gates 26 edges. Cut to 100 at the same time |
| Shiny Charm | **30,000 coins** | Upstream's price, ~28 days. Passive, permanent, so it should be a genuine commitment |
| Targeted pick | **Dust, priced on the band** | Superseded. Priced in coins here at 200 x (255 / captureRate); the currency and the scale both changed when the user settled duplicates, and the table that shipped is in "Settled 2026-08-23" below |
| Targeted re-roll | **A tenth of the pick** | Added when the loop was built. Same section |

As shipped, the pick is Dust rather than coins: 10 for a common up to 300 for a
mythical, against ~7 Dust/day of duplicate income. The reasoning is below, and the
item and edge counts in this table were corrected from 25/27 when the manifest was
regenerated with real triggers.

The targeted pick is what makes the dex completable at all, so its price sets the
endgame. Random hatching alone needs a median **110,218 hatches** to see every
hatchable entry once (27x worse than uniform, because the rarest entries are largely
non-evolving legendaries that stay in the hatchable pool). Restricting draws to the
hatchable 570 improved that by a mere 1.6x over drawing from the full 1,083. Luck
handles the bulk; only the targeted path closes the tail.

---

### Scope carried over from upstream

Kept: the **floating desktop pet** (`FloatingPetPanel`, a borderless always-on-top
draggable sprite window, independent of the menu bar), **notifications** on hatch
and other companion events, and the **shop**.

Shop stock: **Rare Candy and Shiny Charm kept. Mint rejected, not deferred.** A
Mint rerolls a Pokemon's nature, and natures play no part here because there is no
stat min-maxing to aim at, so it would be a coin sink that buys nothing observable.
If stats ever arrive, revisit this entry first.

**A Pokedex view is in scope.** The Phase 3 close-out recorded it as deferred; that
was a misreading of the user, who read "browser UI" as a web app and was declining
that, not declining a way to look at the collection. There is no web anything in
this project. The view is a screen inside the menu bar popover for browsing what has
been collected.

### Settled 2026-08-23, when the loop was built

Both of the open economy questions were put to the user before the model was
written, because both change the shape of the code rather than the value of a
constant.

**Duplicates mint a second currency, Dust.** The user's call, from two options.
Coins already accrue at ~1,080/day whether or not the app is being played, so a
coin refund for a duplicate is a rounding error you would never notice, and the
guaranteed path would be funded by idling rather than by playing. A separate
currency fixes both: it is minted only by hatching, so it accrues at the rate you
actually play, and it makes the tail of the dex something you work toward.

**The split is coins buy volume, Dust buys choice, and neither substitutes for
the other.** Coins keep eggs, Rare Candy, stones, the Linking Cord and the Shiny
Charm. Dust buys exactly two things, and they are the same mechanism aimed at
different targets:

| | What it does |
|---|---|
| **Targeted pick** | Name an entry you do not own and be given it, in its plain sprite. The only reason the dex is completable |
| **Targeted re-roll** | Hatch a species you already own again, for a shot at a variant you do not. This is the shiny hunt |

Two alternatives were offered and declined: letting Dust also buy Rare Candy
(rejected because two ways to buy candy makes the dearer one dead), and moving the
Shiny Charm onto Dust (rejected; it stays a coin purchase).

**Only egg hatches mint Dust.** Not a taste decision, an exploit. Dust pays out on
the raw capture rate, so a duplicate legendary is worth 85 while a re-roll of one
costs 25: if re-rolls paid out they would print money on exactly the entries the
price exists to protect. Evolutions and targeted picks pay nothing either, for the
weaker reason that neither is a roll.

**Dust income is 1.97 per duplicate, about 7 a day.** Derived, not guessed. Payout
is `255 / captureRate` and the draw is weighted on `captureRate`, so the expected
yield collapses to `255 x 570 / sum(captureRate)`: the weighting that makes rare
things rare makes them rare in the duplicate stream too. At 3.6 eggs/day, which is
what 1,080 coins buys at 300 each, that is ~7 Dust/day once most hatches are
duplicates.

**The pick is priced on the rarity band, which is the reverse of the hatch
weighting, and deliberately.** The raw rate spans 85x, so pricing on it puts a
legendary at ~85 days of duplicates against a common's one. A price is a thing you
read, not a weight you sample, so it gets the quantized band the raw number is too
lumpy for.

| Band | Dust | Days at ~7/day |
|---|---|---|
| common | 10 | 1.4 |
| uncommon | 20 | 3 |
| rare (the median band, 493 entries) | 50 | 7 |
| epic | 100 | 14 |
| legendary | 250 | 36 |
| mythical | 300 | 43 |

The user chose **generous, to be tuned down**: it is easier to make this harsher
once the loop is playable than to find out a year in that completion was never
reachable. A re-roll is a tenth of the pick, so a 1/64 shiny hunt on a rare species
is ~320 Dust, a long project rather than an afternoon.

**Auto-evolution fires only for an entry with exactly one item-free edge.** A
stone is a thing you choose to use, so an item edge never fires on its own no
matter how high the level goes. Anything that branches waits for the player: Eevee
has three item-free edges at level 36, Wurmple two at 7, Tyrogue three at 20. The
resolution loops, because one credit can cross two thresholds and a Rare Candy at
level 5 takes a Caterpie past both 7 and 10.

**"One edge in total" rather than "one edge *ready*", and the difference is a
silent lock-out.** The narrower rule was written first and looks equivalent. It is
not, for the two entries whose item-free branches sit at *different* levels:

| Entry | Edges | What the narrower rule did |
|---|---|---|
| Nincada | Ninjask 20, Shedinja 36 | Evolved at 20, so level 36 was never reached as a Nincada |
| Dartrix | Decidueye 34, Hisuian Decidueye 36 | Same, at 34 |

In both cases the later target became unobtainable by raising, leaving only the
Dust purchase. **The graph still contained the edge**, so the generator's
reachability assertion was satisfied and said nothing: reachable-in-principle and
reachable-by-playing are different properties, and only the first one is checkable
from the manifest. A test covers the second.

Found by a test asserting starter chains were linear, which they are not: Cyndaquil,
Oshawott and Rowlet all fork at their second stage into a Hisuian form. That fork
exists only because the edge join was corrected earlier the same day; under the old
join those three regional evolutions had no incoming edge at all.

**Shininess carries through evolution**, which is the only way a shiny Charizard
slot can ever be filled: eggs draw from the hatchable pool and Charizard is not in
it.

**Nothing that acquires a Pokemon disturbs the raise in progress.** Hatching,
re-rolling and the targeted pick all land in the log and assign an active raise
only when there is none. It matters most for re-rolling, which would be unusable
otherwise: the point of a shiny hunt is to keep fishing while the current one
climbs, and a re-roll of the species being raised is the case a careless
implementation would overwrite. Switching used to be the one thing that cost
levels; since the roster landed it costs nothing, and every individual keeps what
it earned whether it is training or in the PC.

**Notifications are quiet by default.** What earns an alert is an event that
happens on its own while the window is closed, which is the set token accrual
drives: an evolution, a graduation, and a choice now waiting. A shiny is the one
exception, and only at the roll. Level ups are excluded on volume alone, at 99 per
climb. A notification for something the player just clicked arrives second to the
result already on screen, which is how an app gets its notifications turned off.

**Permission is requested when the player first has something to raise, not on the
first thing worth posting.** The lazy version was written first and was wrong:
asking on the first postable event means the first evolution races its own
permission prompt, and a notification posted while authorization is pending is
dropped. The single event the whole feature exists for is the one that would be
swallowed. Asking after the first hatch settles it hours before an evolution can
fire, at a moment the player is already looking at the app. Still not asked at
launch, so someone who never touches the game half is never prompted.

**Granting sends one confirmation, ever**, and it exists because of how this was
verified. Whether an ad-hoc signed bundle can post at all is not knowable from the
code: `requestAuthorization` returned `true` while the app was absent from
Notification Center's registered-apps list, which is the signature of a
LaunchServices registration failure that drops notifications silently. The only
evidence that settles it is someone seeing a banner. **The user confirmed one
appeared, 2026-08-23**, so the ad-hoc path works. The confirmation also says
plainly what will and will not interrupt them, which is worth one banner on its
own. Note what the weaker evidence looked like: a `UserDefaults` flag proving the
send code ran, which says nothing about whether anything rendered. Fourth instance
in this project of that distinction mattering.

**The desktop pet is an `NSPanel`, not a SwiftUI `Window`.** Three requirements
SwiftUI has no vocabulary for: float above ordinary windows without stealing focus
(`.nonactivatingPanel` at `.floating`), follow the user across Spaces
(`.canJoinAllSpaces`), and be dragged by a transparent background
(`isMovableByWindowBackground`). Off by default, because an always-on-top window
is a thing a user asks for rather than one that appears.

**Dex detail replaces the grid in place; it is not a sheet.** A `MenuBarExtra`
window closes on focus loss, which is exactly what presenting a sheet from it does.

**Unseen dex entries draw a glyph, not a greyed sprite.** Two reasons that happen
to agree: it keeps the dex a thing you fill in, and it stops browsing from pulling
2,368 sprite files for Pokemon nobody has caught.

### The first pick

Added 2026-08-23 after the user played the loop cold and named the barrier: the
first thing that happens to a new player should not be a weighted random draw.

**The first Pokemon is chosen, free, from the 27 canonical starters.** Opening with
a draw over 570 hatchable entries means the first Pokemon is overwhelmingly likely
to be one nobody asked for, which is a poor first thirty seconds for a game whose
entire hook is attachment to a single creature. Every one of these games opens with
this choice, and it costs the economy nothing: one entry out of 1,083, on a curve
where the binding constraint is raising time rather than acquisition.

It is offered once, and the guard is an **empty catch log** rather than a flag,
because "have I ever caught anything" is a question the log already answers and a
separate boolean could disagree with it. Hatching first forfeits it, so the free
pick cannot be taken after seeing what luck gave you. The variant is still rolled:
a shiny starter at 1/64 is a better story than a guaranteed plain one.

**The starter list is 27 hardcoded ids**, because nothing in PokeAPI marks a species
as a starter: no flag, no pokedex slice that isolates them, and no derivable rule
that does not also catch Caterpie. What keeps that from being 27 magic numbers is
the test, which asserts against the real dex that there are three per generation for
nine generations, that every one is hatchable and non-regional, and that every one
is the base of a three-stage line.

**The picker is the only place in the app that shows sprites for Pokemon nobody
owns.** Everywhere else an unseen entry draws a glyph. Here the choice is the
content, so 27 sprites are worth fetching.

### The Everstone

Added 2026-08-23, from the user's question: does a Charmander at 16 evolve on its
own, and if you postpone it, is there a point of no return?

The answer to the first was yes, automatically, with no way to say no. Single
item-free edges fire on the credit that crosses the threshold, so for the common
case there was no equivalent of pressing B in the games. That was a gap rather than
a decision: nothing had ruled it out, it simply had not been thought about.

**The toggle is called the Everstone**, the user's call, and correctly: it is the
item that does exactly this job in the mainline games, so the name carries its own
explanation.

**It is free, not shop stock.** The other items are all coin sinks, so this is the
odd one out and worth saying why. An Everstone gates *taste*, not power: it makes a
Pokemon stay the shape you like, which changes nothing about progression, the dex,
or the economy. The recorded principle is that useful sinks buy time or certainty;
charging for a preference buys neither, and it would put a price on the one feature
whose whole purpose is attachment.

**It is held by the individual, not set by the player.** A newly started Pokemon
begins without one, which is what "held item" means and also the behaviour that
needs no explaining. Since the roster landed, a stored individual keeps the stone
it was holding along with its levels: it is that Pokemon's item, not the trainer's.

**A hold queues, it does not cancel, so there is no point of no return.** Taking
the stone off resolves immediately and fires everything the level passed, in order:
a Caterpie held to 20 becomes a Butterfree at once, and Metapod is registered in the
dex on the way through. This is deliberately *more* forgiving than the games, where
declining an evolution simply re-offers it next level. Nothing is ever lost by
waiting, which is the property that makes the toggle safe to touch.

Consistent with that, every level check in the game is `>=` rather than `==`, so a
level-100 Nincada can still become Shedinja and a level-100 Pikachu still takes a
Thunder Stone. Late is always allowed.

**It blocks automatic evolution only.** Pressing an evolve button while holding one
is an unambiguous instruction and overrides it, which is also roughly how a stone
behaves in the games. The toggle is hidden entirely for a line that never evolves
on its own, because on a Pikachu it would promise to prevent something that does
not happen unasked.

### Saved games must survive a new field

Found while adding the Everstone, and worth more than the feature that found it.

`Raise` gained a field, and the synthesized `Codable` decoder **throws on a missing
key even where the property has a default**. `GameMonitor.load()` was
`try? JSONDecoder().decode(...)`, falling through to an empty `Trainer`, which
cannot distinguish "no save yet" from "save I could not read". The next `persist()`
would then write the empty collection straight over the real one.

So every schema change was one field away from silently deleting a collection. That
matters more here than it would elsewhere because of an asymmetry: **the usage
ledger can be rebuilt by rescanning `~/.claude`, and the collection cannot.** A
Pokemon caught last week exists in exactly one file.

Two fixes, both cheap:

- `Raise` decodes by hand, with `decodeIfPresent` and a default for the new field.
  Every field added from here on wants the same.
- An unreadable save is copied to `game-state.unreadable.json` before anything can
  overwrite it, and the decoding error is printed rather than swallowed.

A test decodes a real save written before the field existed, taken verbatim from
the live app, and asserts the collection, the charm, the coins spent and the
rebuilt slot index all survive.

**Level marks are written events, not derived ones. Decided 2026-08-24** after
the user asked for a level 100 mark in the Dex, then a level 50 one an hour
later.

There was nothing to derive either from. `Trainer.credit` already detected the
level 100 crossing and emitted a transient `.graduated` event for the notifier,
but nothing persisted it, and `Raise` carries the level of the *active* Pokemon
alone. Switch Pokemon and the fact that the last one got anywhere was gone. So
the Dex could not have shown a ring however it was drawn; the data did not exist.

**The record carries the level, it is not a graduation flag.** This is the one
thing worth copying elsewhere. The first cut shipped a `GraduationEvent`, a
boolean fact in event form, and the request for a second height arrived before
the day was out. Level 50 and level 100 are the same kind of fact at different
heights; a flag would have needed a second parallel list, and then a third.
`MilestoneEvent` carries `level`, `Trainer.milestoneLevels` is `[50, 100]`, and a
future threshold is one array entry.

The rename cost nothing here only because it happened immediately: the field had
been persisted for about an hour and every live save held `"graduations": []`.
`CatchLog` still reads the old key and treats records under it as level 100, and
`MilestoneEvent` decodes a missing `level` as 100 for the same reason. Read the
old shape, write the new one, never both.

Three further calls, each with an alternative that looks reasonable:

- **A second append-only list on `CatchLog`, not a field on `CatchEvent`.** A
  catch is a sprite arriving; a milestone is an individual getting somewhere.
  Folding them together would mean going back and rewriting a `CatchEvent` in
  place, which is the one thing this log does not do. Same reasoning as
  `UsageLedger`: append the fact, derive the view.
- **Credited to the form it was at the time, not to its origin.** A Charmander
  raised all the way is a Charizard when it graduates, and the ring belongs on
  Charizard's tile. `Raise.originEntryID` still answers "where did this one
  start" for anyone who wants the other view.
- **Per sprite, not per species**, matching invariant 18. A shiny at 100 is a
  separate mark from a plain one. The grid asks the species-level question once
  per tile and draws the highest; the detail pane's variant row asks the
  per-sprite one.

**Every level crossed is recorded, not just the highest.** One credit can clear
both marks at once, from a Rare Candy or a quiet hour on a busy machine, and the
log should say it passed 50 rather than silently skipping it. Same shape as the
evolution loop in invariant 20, and for the same reason.

**Amended 2026-08-24, from a question the user asked: "will Dragonite ever have a
silver halo?"** It would not have, and two separate faults were behind that.

*The credit is now replayed in level order.* A single credit can carry an
individual past a mark, past an evolution, and past a second mark. The first
implementation resolved the whole evolution chain and *then* asked what the
individual was, so a Dragonair going 49 to 60 in one credit had its level 50 mark
recorded against the **Dragonite**, for a level it passed as a Dragonair. The same
climb spread over two credits recorded it against the Dragonair. Attribution that
depends on how the XP happened to arrive is not attribution, and one credit
crossing the whole curve is not exotic: a cold first scan credits a month at once.
`resolveEvolutions` now takes an `upToLevel` cap and each mark is recorded after
resolving only as far as that mark. A test raises the same Dratini both ways and
asserts the two agree: 50 to Dragonair, 100 to Dragonite.

*And the tile now reads the roster as well as the log.* The paragraph above says
marks must be written events because "`Raise` carries the level of the active
Pokemon only, so the moment you switch, that one made it is gone". **That
reasoning expired when the roster landed** and began keeping every individual
forever with its level and its current form. The log answers "which forms crossed
this line while they were that form"; the roster answers "which forms are held at
this level right now". Neither is sufficient alone:

- Dragonair evolves at **55**, so no Dragonite can ever cross 50 on the normal
  path. Log-only leaves a level 60 Dragonite with no ring at all until it
  graduates. The same gap opens above 100 for any stone used on a graduate: a
  Vaporeon made from a level 100 Eevee never crossed anything.
- A Charmander that became a Charizard is one roster row saying "Charizard".
  Roster-only would strip Charmeleon of a mark it genuinely earned.

So the tile is the union, taken over `Raise.id` rather than by counting both, or
an individual that crossed the line *and* is still that form would count twice.
The events are still the durable record and are still never derived; what changed
is that they are no longer the *only* source the display reads.

Drawn as a ring rather than a corner badge. The top trailing corner is already
the shiny sparkle's, and at 44pt across a grid of 1,083 tiles a border reads at a
glance where a 7pt glyph does not. Gold replaces silver rather than stacking:
everything at 100 passed 50, and two rings would say one thing twice. The detail
pane counts graduations but not halfways, because tallying waypoints reads like a
scoreboard for something nobody is competing at.

**Neither mark pays out, notifies, or unlocks anything**, and that is deliberate.
Whether level 100 deserves a reward is still an open question below, and adding a
second payout before answering the first would make it harder to answer. Nothing
keys off `milestoneLevels` but the ring colour.

Not yet seen on screen. Nothing in the live collection has reached either mark:
the active individual is level 29 of 100, needing another 162,000 XP for silver.
How long that takes is entirely a function of use, and the spread is wide enough
to be worth writing down: a heavy day like 2026-08-23 moves roughly 216,000 XP,
while the idle overnight rate measured here is about 25,000. So silver is a day of
real work away, or a week of leaving the machine alone. The logic is covered by
tests; the pixels are not, and by the rule this project already learned the hard
way, that means it is unverified.

### Still open

- **Whether the pick prices are right.** They are deliberately generous and the
  user expects to tune them down. That is a judgement only play can make.
- **Whether level 100 needs a reward.** Right now graduation is its own trophy. If
  the last 2.7 days of a climb feel empty in practice, that is where to look.

---

## v2 direction, set 2026-08-24

Decisions only. The sequencing, the migration detail and the test list live in
[PLAN-v2.md](PLAN-v2.md), and are deliberately not duplicated here: one copy of
one fact, the same rule `CatchLog` follows.

**All of v2 is implemented, 2026-08-24: steps 0 to 7.**

### The save is copied aside before it is read

Step 0 of the plan, and first because step 1 is the largest change
`game-state.json` has ever taken. The existing protection, the
`game-state.unreadable.json` quarantine, fires **only when a decode throws**. It
covers a corrupt file and it does not cover the failure a migration actually
produces: a save that decodes perfectly and holds the wrong thing, because a
default was seeded wrong or an empty roster was persisted over a real one.
Nothing throws, nothing is quarantined, and the next write makes it permanent.
The asymmetry from "saved games must survive a new field" is the whole reason to
care: the usage ledger can be rebuilt by rescanning, the collection cannot.

`SaveBackup.capture()` runs in `GameMonitor.init` **before `load()`**, copying
the save to `backups/game-state-<local day>.json`, newest 10 kept.

Three calls inside that, each with a plausible alternative:

- **Day-stamped, not per-launch.** An app that launches, writes a bad save and
  dies would otherwise burn ten good copies in ten launches, which on a crash
  loop is ten seconds. Ten days of history is the useful axis, not ten launches.
- **The first capture of a day wins**; later launches that day copy nothing. This
  is the half that makes the backup work against a bad write rather than only
  against corruption. Today's copy is the save as it stood *before today ran*, so
  a launch that ruins the save cannot then overwrite the copy that would undo it.
  Overwriting per launch was the obvious reading of "copy the save" and is
  strictly worse for the failure this exists to catch.
- **Pruned by file name, not by modification date.** The stamp is `yyyy-MM-dd`,
  so lexical order *is* day order, while modification date says when a copy was
  taken rather than which day's state it holds. A test writes the days out of
  order and asserts the oldest *day* is the one evicted.

Local calendar for the stamp, matching invariant 9: a UTC stamp rolls over
mid-evening here and would file a copy under tomorrow.

### The roster, and why identity is `Raise.id`

Step 1 of the plan, implemented 2026-08-24. `Trainer.active: Raise?` is now
`roster: [Raise]` plus `team: [UUID]`, and **nothing ever deletes a `Raise`**: the
roster is append-only like the two logs. Switching away no longer costs anything,
which is the reversal the user asked for in as many words.

**Identity is `Raise.id`, not `VariantSlot`.** A slot cannot be the key, because a
`Raise` mutates its own `entryID` as it evolves, so a slot-keyed store would have
to be rekeyed on every evolution: the same "two copies of one fact" smell that
`CatchLog.filledSlots` exists to avoid. `MilestoneEvent.raiseID` already pointed
at `Raise.id` and its doc comment already wanted two Pikachu to be two
individuals, so this is the shape the log was written for.

**Two verbs, not one.** v1's `setActive(entryID:)` could not express the
difference between "bring Charizard back" and "start a second Charmander", and
once levels persist that difference is the whole feature. So `addToTeam(raiseID:)`
resumes an existing individual at its stored level, `startRaising(entryID:...)`
creates a new one at level 1, and `removeFromTeam(raiseID:)` stores without
deleting. Starting is still free and ungated.

**`active` survives as the name for team slot 1**, and only until the team gets a
UI. One stored fact, two readers: the popover and the status item still speak in
one Pokemon, and renaming them is step 4's job rather than something to smear
across two steps.

**A duplicate individual is allowed and is not a duplicate.** Two Charmander
raised separately are two rows in the roster with two levels, because that is what
"my progress on this one" means. Ownership is still per sprite, per invariant 18,
and is still the log's question, not the roster's.

**Migration reads the legacy key forever and never writes it**, the pattern
`CatchLog` already uses for `graduations`. A save with `active` and no `roster`
seeds a one-individual roster with its XP intact and puts it in slot 1. Old keys
that every save has ever carried stay *required*, which matters more than it
looks: if every field were `decodeIfPresent`, a nonsense object would decode as a
brand new empty trainer instead of throwing, and invariant 23's quarantine would
never fire. New keys are optional, old keys are not.

**The team is sanitised on decode, not trusted.** Unknown ids dropped, duplicates
collapsed, capped at 6. It is a list of references into the roster, so it is the
one part of the save that can be internally inconsistent, and the fix belongs
where the data is read rather than at every use site. Same instinct as invariant
22 rebuilding the slot index on decode.

### The team gains XP together

Step 2 of the plan, implemented 2026-08-24. **A team of up to 6 gains XP
simultaneously.** Slot 1 at 1.0, slots 2 to 6 at 0.8 each, per occupied slot, so
a team of two is 1.8x and the ramp is smooth.

The shares live in `XPCurve.leadShare` and `XPCurve.partyShare` and nowhere else,
because the party figure is the dial: 0.8 gives 5.0x, 0.5 gives 3.5x, 0.25 gives
2.25x.

**A capped member's share is not redistributed.** XP that would go to a graduated
individual is simply not granted. Redistribution was the tempting alternative and
is wrong: it would silently change what the lead slot means the moment it hits
100, and the ceiling clamp already existed. A graduated Pokemon left in the team
is wasting a share, and the right answer is to *tell the player*, which is a step
4 job, not to compensate behind their back.

**Rare Candy feeds one Pokemon, never the team.** It was routed through `credit`
in v1 because "credit" and "the active one" were the same thing. With six members
that would hand 10,000 XP to all of them for 250 coins, turning the one targeted
item in the game into a permanent 5x team boost and the only sensible purchase in
the shop. It now calls `grant` against one `raiseID`, defaulting to the lead until
step 4 gives the button a picker. One candy, one Pokemon, as in the games.

**Every event that concerns an individual now carries its `raiseID`.**
`levelledUp`, `evolved`, `evolutionChoice` and `graduated` all assumed a single
subject, which was true when there was one active Pokemon and is now false: one
credit can level six of them. Display copy still names the *species*, because that
is what the player recognises; the id is for pairing an event with a team slot.

**Alerts of the same kind from one credit are grouped, not posted one by one.**
Notification volume was already an explicit constraint (level ups are excluded on
volume alone, at 99 per climb) and a team multiplies every count by six. An
overnight batch that evolves four members would have posted four banners, which is
how a user ends up turning notifications off, and then the one that mattered does
not arrive either. `Notifier.announcements(for:dex:)` collapses each kind into one
banner that names them all: "3 Pokemon evolved", body "Metapod, Kakuna and
Ivysaur, all at once." Grouped per kind and never across kinds, because
"5 updates" tells the player nothing. Three banners is the ceiling for any single
credit. A batch of one still reads exactly as it did before the team existed, and
a shiny is never grouped because it can only come from a single click.

### The Exp Share

Step 3 of the plan, implemented 2026-08-24.

**A boost, not a split.** 10,000 coins, one-time, then a free toggle. If slot 1
gets 100 XP then slots 2 to 6 each get 100 XP; the credit is never divided across
the team. The divide-by-six reading was raised and rejected by the user: it would
make a paid item a *downgrade* from the free 5.0x default. A full team goes from
5.0x to 6.0x.

Priced at 10,000 rather than 5,000 because it is passive and permanent, which is
the class the Shiny Charm sits in at 30,000; at 5,000 it is 4.6 days of accrual
for a permanent +20% and is bought without thinking. At 10,000 it competes with
33 eggs.

Three smaller calls:

- **Buying turns it on.** Nobody spends 10,000 coins on something and then leaves
  it off, and a purchase that visibly does nothing until a second control is found
  reads as a bug. The toggle exists to turn it *off* again, which nothing sensible
  will ever do; that is known and accepted rather than a tradeoff being offered.
- **The toggle is inert until owned, not an error.** A control the player cannot
  see cannot be pressed, so a throw there could only ever fire on a bug. Turning
  it off does not sell it back, and off means 0.8 rather than nothing.
- **Owning it and using it are two persisted fields**, both `decodeIfPresent` and
  both defaulting to false. One combined field could not express "bought, switched
  off", and a save from before either existed has to mean neither.

It was deliberately kept out of the shop until the team UI existed, because until
then it would have sold a 10,000 coin item that did nothing observable. It is
listed now, and the toggle sits under it once owned.

**The 5x to 6x XP inflation is accepted, and the reason is that graduation pays
out nothing.** This looks like it contradicts "raising time is the bottleneck",
which is load-bearing above. The measurement that defuses it:

| | XP | Days at 216,000 XP/day |
|---|---|---|
| Level 36, the deepest common evolution edge | 129,600 | **0.6** |
| Level 50, silver ring | 250,000 | 1.16 |
| Level 100, graduation | 1,000,000 | 4.63 |

Evolution is already fast; what is slow is graduation, and `milestoneLevels` is
display-only by deliberate decision while the reward question stays open. So 6x
graduation throughput inflates ring colours and nothing else: no coins, no Dust,
no unlock. Two real costs accepted knowingly: Rare Candy gets relatively weaker,
and the silver and gold rings get common. Both are watch-and-see, and both are
cosmetic to fix. The party share is the dial if it needs turning, and it lives in
one constant for that reason.

### Per-project attribution, and the encoding that never got decoded

Step 6 of the plan, implemented 2026-08-24. **The plan's approach was wrong and
was replaced before any of it was written.**

The plan said to decode `~/.claude/projects/-Users-apersad-Documents-...`, the
encoded directory name. That encoding replaces every `/` with `-`, which makes it
**ambiguous**: `hue-scenes` and `hue/scenes` encode identically, and this machine
has directories of both shapes. Any decoder is guessing, and it guesses wrong on
exactly the names a person would recognise.

It also turned out to be unnecessary. **All three sources write the working
directory into the data already:**

| Source | Where | Coverage |
|---|---|---|
| Claude Code | `cwd`, on the usage line itself | 421 of 421 usage lines in the largest file |
| Codex | `cwd`, on `turn_context` | carried forward like the model already is |
| Copilot CLI | `sessions.cwd` | a `LEFT JOIN` on the query that was already running |

Measured over the live corpus after the change: **every entry from every source
is attributed**, and a test asserts that under `POKEBAR_CORPUS=1`, including that
no name still looks like an encoded path. Reading a fact is always better than
reversing a lossy encoding of it.

**The key is the full path and the name is its last component.** Two directories
can share a last component, so only the path is a safe identity.

**Attribution is by working directory, not by project root**, and that is visible
in the real data: `PawscriptionsKit`, `PeckishKit`, `Assets.xcassets` and
`firebase` all appear beside their parents, because a session started in a
subdirectory reports that subdirectory. Rolling up to a git root was considered
and left alone: it needs filesystem access, it cannot work for a directory that
has since been deleted, and "where was I actually working" is a defensible answer
in its own right. Watch it; if the list gets noisy the fix is a roll-up rule, not
a change to what is recorded.

**The per-project delta is diffed off the ledger, never summed from the entries.**
The ledger credits *growth* on a turn it has already seen, so summing the entries
handed to it would attribute a rewritten turn's whole total to its project on
every scan, roughly 2.4 times over. Same trick the total weighted delta already
used, and for the same reason.

**Rare Candy attributes to nothing.** It was bought, not earned anywhere, so a
Pokemon fed one has `xpByProject` summing to less than its `totalXP`. That is the
honest answer, and the display shows shares of what *is* attributed.

**Only new usage is attributed.** The ledger has no per-entry history to go back
over, so everything credited before this shipped is unattributed and stays that
way. Backfilling would mean re-reading 481 MiB and rebuilding a ledger that is
deliberately append-once. The alternative to a gap at the start is no feature.

**Per-project attribution records always, displays optionally.** The user wants
to hide it sometimes, not to stop collecting it. A toggle that gated *recording*
would leave holes that can never be backfilled, because the ledger credits each
turn exactly once and cursors do not rewind. The toggle is therefore a display
preference in `UserDefaults`, never in `game-state.json`: nothing re-derivable
belongs in the one file that cannot be re-derived.

### The team on screen

Step 4 of the plan, implemented 2026-08-24. Every rule was already in `Trainer`;
what this decided is how 6 slots, a PC and three aimed items fit in 312pt.

**The card is the selected member, and the rows are the rest.** One detail view
plus a list, not six cards: six of anything with a progress bar does not fit. The
selected member's row is *skipped*, because the card above is that row expanded,
and the useful side effect is that a team of one renders exactly what it rendered
before any of this existed. The pane a returning v1 player sees is unchanged.

**Selection answers three questions at once**, which is the only reason it exists:
which Pokemon gets the Rare Candy, which one the Everstone is for, and which one
is being promoted. Aiming each separately would be three controls per row, on a
row 300pt wide. Selection is resolved on read and falls back to the lead, so
storing or promoting cannot leave a stale target behind.

**Promote, not drag-to-reorder.** Slots 2 to 6 all take the same share, so their
order is *cosmetic*; slot 1 is the only slot that means anything. One "Make lead"
button therefore covers every reorder that changes anything, and it is testable,
which a drag list in a 340pt popover is not.

**The Dex button says which of two things it will do before it is pressed.**
"Resume at level 47" and "Raise a new one" are very different outcomes behind one
click, and the roster is keyed by individual while the Dex is keyed by entry, so
the button has to choose. `Trainer.raiseAction` resolves it without mutating
anything and the label reads it: a stray double-click can no longer quietly leave
a second level 1 Charizard in the roster. Not owned beats a full team beats
resume, because a button offering to resume a Pokemon it cannot add is the worse
lie.

**The PC list is sorted best first and capped at six rows.** "Bring back my
strongest" is the question that list exists to answer. It is capped because
nothing is ever deleted, so the PC grows without limit, and the pane says how
many it is hiding rather than pretending that is all of them.

**The Exp Share toggle lives in the Shop, next to the item.** What it *does* shows
up in the Raise pane, in the team's multiplier, which is where a player would look
to see whether it is working. Two controls for one fact would be worse than one in
the less obvious place.

**A graduated member is told about, not compensated for.** `GameFormat`
`wastedSlotNote` puts it in the team header in orange. That is the other half of
invariant 32: the share is deliberately not redistributed, so the player has to be
able to see the waste.

**The scroll area is measured and then clamped**, unlike the Dex and Shop panes
which are pinned. Those two are always full so a fixed frame is honest for them.
This one is one card on a fresh install and six slots plus a PC of twenty
later: a fixed frame means dead space at one end or a 900pt popover at the other.
`PopoverMetrics.RaisePane` holds the two bounds and a test pins the clamp.

### The feedback round, 2026-08-24

Everything below came out of the user playing the team build cold, which is the
only way any of it would have been found.

**A hatch is celebrated, not logged.** A 300 coin egg announced itself as one grey
line in a four-row feed, directly under the button that bought it, and the first
thing the user did with the team was miss it entirely. `CelebrationCard` is now an
overlay over the whole popover: the sprite at 84pt, what it was, whether it was new
to the dex, what the duplicate paid, and which slot it went into.

The rule it settles is worth more than the card: **the popover celebrates what you
clicked, and the notifier announces what happened while you were not looking.**
Evolutions therefore never celebrate, because they fire on their own from token
accrual and the notifier already covers them. Dismissed by a click and by nothing
else: no timer, because a card that vanishes mid-read is worse than one you have
to wave away, and the sprite may still be arriving from the network.

**Nothing conjures a Pokemon out of nothing.** "Raise a new one" in the Dex read as
an offer to invent one, and worse, it appeared on Charmander and Charmeleon, whose
individuals had *become* the player's Charizard. Two rules replace it:

- **"Add to team" only ever offers individuals that already exist**, by name, with
  their variant and level, so two stored Pikachu are two rows. No button at all
  when there is nobody to bring back, rather than a disabled one: a dead control
  with no explanation is worse than no control.
- **A brand new individual has to be hatched, at a price, and only at the bottom
  of its line.** A Charmeleon is a Charmander that grew, so the Charmeleon tile
  says exactly that instead of selling one. "Bottom of the line" is
  `Pokedex.isEvolutionGated` inverted, which is the same 570 entries an egg draws
  from, babies included, and therefore not a second rule that could disagree with
  the first.

**Hatch another is priced in both currencies, and they curve differently.** The
user asked for both and asked for the numbers to be reasoned rather than guessed.

| | Coins | Dust |
|---|---|---|
| Price | 3,000, flat | half a targeted pick: 5 / 10 / 25 / 50 / 125 / 150 |
| Accrual here | ~1,080/day | ~7/day |
| So, in time | 2.8 days, any species | 0.7 days common, 3.6 rare, 18 legendary |

Flat coins against banded Dust is the whole design: **Dust is the cheap path for a
Caterpie and coins are the cheap path for a legendary**, so the two currencies are
not interchangeable and the choice is real. 3,000 is ten eggs, and an egg already
fills a slot for 300, so what is being charged for is *choosing the species*, which
has to sit well clear of the random draw or the draw stops being the game.

It cannot be farmed, which is what makes a merely-steep price safe without a
cooldown: **the team caps at six**, so there is no reason to buy more than a
handful, ever. The sink is self-limiting by construction rather than by rule.

**An acquisition always produces an individual, and fills an empty slot if there
is one.** The old rule was "start a raise only when nothing is training", which was
correct when there was one active Pokemon and became wrong the moment there were
six: hatching into a team with five empty slots did nothing visible. With no room
the individual lands in the PC, because an egg that was paid for must never
produce nothing. The shiny-hunt protection is unchanged: it still never disturbs an
*occupied* slot.

The consequence, accepted: the PC now accumulates duplicates, since every hatch
leaves an individual. That is the right model (the PC is the box) and both lists
that show it are capped at six with a count of what is hidden.

**Six uniform cards in a 2 x 3 grid, and drag to swap.** The first version had the
lead as a large card and the rest as thin rows, and the rows read as neither equal
members nor as clickable. Every slot now looks like every other slot, empty ones
included, which is also what makes the order legible enough to be worth
rearranging. Two columns rather than three: at 312pt a third column leaves ~100pt
a card, which truncates "Charizard" beside a level. Dropping one card on another
**swaps** them rather than inserting and shifting, so dropping onto the lead
promotes exactly one Pokemon and demotes exactly one. "Make lead" survives beside
it as the reliable way.

**The drag took three attempts, and the third abandons the system drag and drop
entirely.** Worth recording all three, because the failures were silent and
identical from the outside.

1. `.draggable` on a `Button`. A button's press gesture wins, so the drag never
   started at all. Selection worked; dragging did nothing.
2. `.draggable` on a plain view with `.onTapGesture`. Fixed the gesture conflict
   and still did nothing, which ruled the conflict out as the whole story.
3. **A plain `DragGesture`.** `.draggable` and `.onDrag` both hang a real drag
   session off the window, and this window is a `MenuBarExtra` panel that never
   becomes key. A `DragGesture` needs none of that machinery: mouse down, a
   translation, mouse up, all inside SwiftUI, so the window cannot refuse it.
   **This one works, confirmed on screen by the user 2026-08-24.**

The cost is that the drop target has to be worked out by hand instead of by
AppKit. Each card reports its rectangle in a named coordinate space
(`onGeometryChange`), and the drop is whichever rectangle the cursor was inside on
mouse-up. The dragged card offsets and lifts while it moves, and the target
highlights, because a drag with no feedback until it lands is indistinguishable
from a drag that is not working, which is exactly how the first two failed.

**A level up says who levelled up.** `.levelledUp` never carried a subject,
because for all of v1 there was exactly one Pokemon it could have been, so the
feed read "Reached level 21" and meant nobody. It carries `entryID` alongside the
`raiseID` now: the id says which individual, the entry says which *name to print*,
and a `raiseID` alone cannot give the feed a name. It is the form it was at the
time rather than what it later became, the same rule `MilestoneEvent` follows, so a
Pineco that reaches 21 and evolves in the same credit reached 21 as a Pineco.

**"Bench" was the wrong word and is gone.** The games call it the PC, so the
button is "Send to PC", the list is "YOUR PC", and the code follows: `Trainer.boxed`,
`GameMonitor.sendToPC(raiseID:)`. The rename went further than the copy on purpose,
because "bench" had quietly come to mean two different things: the Pokemon that are
stored, and team slots 2 to 6. `XPCurve.benchShare` is now `partyShare`, which is
what those slots actually are.

**And there is a right-click menu doing the same jobs**, added at the same time
rather than after the next round of feedback. A menu bar window is an awkward place
to drag inside, and a feature that only works by dragging has no route at all for
anyone who cannot. It carries "Make lead", "Swap with" and "Send to PC", which is
everything the drag and the detail panel can do.

**The milestone mark is a halo, not a border.** Caught on screen: a crisp 1.5pt
ring around one tile in a grid is what *selection* looks like, and macOS draws its
focus ring the same way. The hard edge is now 0.6pt at 40% and the mark is carried
by a blurred stroke that bleeds outward. A glow is not a state, and nothing else in
that grid glows.

### Open at login: the framework, not a plist

Step 7, implemented 2026-08-24. `SMAppService.mainApp`, not a hand-written
LaunchAgent plist in `~/Library/LaunchAgents`.

A plist has to name an absolute path to the bundle, and this bundle lives at
`dist/PokeBar.app` inside a working copy. A rebuild is fine, but a clean or a move
leaves a login item pointing at nothing, **silently**, until the user notices the
app stopped starting. `SMAppService` registers this bundle by identity, is removed
when the app is deleted, and appears in System Settings where a user would go
looking for it. It is also the only route Apple supports from macOS 13 on.

**Off by default**, like the desktop pet: an app that adds itself to login items
unasked is a bad neighbour. And nothing is lost while PokeBar is off, because
cursors persist and a launch after three days credits those three days. What the
switch buys is the passive notifications firing *when the events happen* rather
than arriving in a batch at the next launch.

The toggle re-reads the system state after every change rather than trusting the
write, because macOS can answer "registered, but the user has to allow it". That
state has its own copy pointing at System Settings, since it is the one case the
user cannot fix from inside the app.

**Confirmed on screen 2026-08-24: the ad-hoc signed bundle registers cleanly**,
reporting `.enabled` rather than `.requiresApproval`. That was the open risk in
this step and it is closed, which also means the `needsApproval` branch is written
but has never actually been seen here. Whether it survives a reboot is untested by
design: the user will find out at their next restart.

**Deferred by the user, not rejected:** widgets, and battles. Battles were liked
but named as a risk of "losing the plot of a token use project", and would also
require reopening "stats are out", which is what Mint's rejection hangs off.
Types in the manifest were only ever proposed as a battle prerequisite and go
with it.

### What "Hatch another" is actually selling, 2026-08-24

The button's note read *"A second one of this exact species, at level 1, to raise
alongside the rest."* Every word true, and the user read it as an expensive
photocopy of the Pokemon they already had, which is a fair reading of that
sentence and not what the offer is.

What it actually sells is a **fresh roll**. `Trainer.obtain` calls `HatchRoll` for
shiny and for gender on *every* acquisition, this path included, so the egg can
come out as a variant the collection does not hold. The note says that now, and it
names the species, because "another" with no subject invites "another of what".

**The offer is not gated on a complete entry, and the note branches instead.**
Asked whether the button should switch off once every sprite of a species is
owned, the answer is no, because the egg sells two things and only one of them
runs out:

- The variant roll, which is spent once the entry is complete.
- **A level 1 to raise**, which never is. A graduated individual earns nothing
  from a credit (invariant 32) and its team slot is dead weight, so hatching a
  fresh one is how that slot goes back to being worth something. Disabling on
  completion would delete the only restock path a completionist has.

So `Trainer.DexOptions` gained `missingVariants`, counted against
`entry.ownableVariants` rather than an assumed four (invariant 18), and it decides
only what the note may promise. Once it hits zero the line stops advertising a
variant and names the reason that survives. A test asserts `hatchAnother` is still
offered at zero, so the next reader cannot "fix" this by gating the button.

Counted against the *reachable* set as well as the ownable one: zero of the 1,083
entries have a distinct female sprite together with a single-gender rate, checked
against the manifest, so every slot counted here can actually come out of an egg.

---

## v3, set 2026-08-26

Four changes, three of them corrections the user made after living with v2 on
screen and one carried in from PokeFit.

**All of it is approved on screen, 2026-08-26.** Signed off item by item: the five
tabs, the PC pane, "Show in Dex" from the Raise pane, and a Great Egg hatched end
to end through the choose-then-hatch control. That is the only way rendered pixels
get verified here, since `screencapture` is blocked for the terminal, and it took
three rounds on the egg control alone.

### Your PC is a tab, not a box at the bottom of the Raise pane

**The user's words: it "doesn't feel right" in the Raise tab.** They were looking
at it sitting under the Everstone caption and above the Hatch button, which is
where v2 put it.

Two things were wrong and they compound. It read as an appendix to the team rather
than as a place, and it was the only list in the app that **grows without limit**,
because the roster is append-only and every switch adds to it. Sharing a clamped
250pt scroll area with the team grid, the selected card and the Everstone forced a
six-row cap and an overflow note. A cap on the one list whose entire purpose is
that nothing in it was ever lost is the wrong trade, so `GameFormat.pcRowLimit`
and `pcOverflowNote` are **gone** rather than moved: with a tab of its own there
is nothing to hide.

What the Raise pane keeps is a one-line link, `GameFormat.pcLink(total:)`, nil
while the PC is empty because a link to an empty list is a dead end and that is
the state a fresh install is in.

`PopoverMetrics.PCPane` measures and clamps at 90 to 300, the same shape as
`RaisePane` for the opposite reason: the Raise pane starts small and grows, the PC
pane starts **empty**, and 300pt of nothing on a fresh install is worse than a
short pane. The ceiling is higher because there is nothing under this list but the
footer.

**Five tabs measure 300pt against the pane's 312pt.** Measured, not assumed:
`NSSegmentedControl` at `.fillEqually` will happily return a control wider than
the pane and truncate every label rather than refuse to lay out, so there is a
test that builds the real control from `PokeBarPopover.Pane.allCases` and asserts
it fits. There is 12pt spare, which means **a sixth tab does not fit** and
renaming "PC" to anything longer needs the test re-run.

### Pane selection and the Dex's focused entry moved up to the popover

**The user: figuring out when a Pokemon evolves "takes more clicks than
necessary".** It took leaving the Raise pane, switching tab, and finding the tile
by hand in a grid of 1,083.

"Show me this one's Dex entry" is a jump *between* panes, so neither pane can own
it. `DexView`'s `selected` was local `@State` and is now a `@Binding` on an entry
id held by `PokeBarPopover`, which sets the id and the tab together. The Raise
pane's selected card, its right-click menu and every PC row hand up an entry id.

An id rather than a `DexEntry`, so a caller needs nothing but the number it
already has, and `DexView` resolves it through the dex it was going to consult
anyway.

### The team header dropped its multiplier

**The user: "5x XP" doesn't make sense to display.** They are right, and the
reason is worth recording because the figure was added deliberately in v2: 5x
against *what* is not a question a header can answer. The only baseline is a team
of one, and nobody runs one on purpose once they have six.

What the number was reaching for is already stated where it can be acted on, by
`GameFormat.shareLine` under the selected card ("Full XP", "80% XP"), which is per
slot and therefore tells the player something about the slot they are looking at.

**The Exp Share stays in the header**, as words rather than a multiplier, because
it is genuinely a state, it is off by default, and this is the only place that
says which way it is set. The separate teal "Exp Share" badge that sat beside the
line went with the multiplier: it said the same thing a second time. The line
itself turns teal instead. A test asserts the header can never carry `"x XP"`
again.

`GameFormat.multiplier(_:)` survives, because `expShareDetail` still sells the
item on 5x to 6x, which is a comparison between two states and therefore means
something.

---

## The egg ladder, carried over from PokeFit

**Four tiers: Egg, Great Egg, Ultra Egg, Master Egg.** Pools nest upward. The
mapping, the pool sizes and the reasoning were settled in PokeFit
(`docs/EGG-POOLS.md` and `DECISIONS.md` §10.4 there, 2026-08-25) against **this
same manifest**, so nothing needed re-deriving: this is the price pass PokeFit
explicitly deferred.

### What did not come across: the incubators

In PokeFit an egg is bought with coins and then hatched by **walking**, a second
gate that makes the coin price low-stakes. PokeBar has nothing to fill that gate
with, so an egg here is still opened the instant it is paid for and **price is the
whole gate**. That is not a simplification, it is the reason the pricing had to be
done properly here and could be deferred there.

### The mapping is a function of `rarity`, never a flag

```
Egg     <- everything hatchable
Great   <- rare and above
Ultra   <- legendary and above
Master  <- mythical only
```

Because the pools nest, one `floor: Rarity` on `EggTier` expresses all four, and
Master reads as mythical-only for free because mythical is the top band. `Rarity`
gained `Comparable`, derived from `allCases` rather than a hand-written rank,
because the declaration order *is* the fact: `rarity_of()` in the generator bands
on ascending capture difficulty and puts the two flagged bands on top.

**No per-entry tier flag, ever.** Same rule as invariant 21 and the same silent
failure: a stored tier would be a second copy of a fact `rarity` already holds,
and the two would drift. Generation 10 arrives with a capture rate, the generator
bands it, and the pools update with no edit.

Measured against `pokedex.json`, and asserted by tests:

| Tier | Bands | Pool | Share of hatchable |
|---|---|---|---|
| Egg | everything | **570** | 100% |
| Great | rare and above | **266** | 47% |
| Ultra | legendary and above | **91** | 16% |
| Master | mythical only | **22** | 3.9% |

Band composition of the hatchable pool: common 234, uncommon 70, rare 140, epic
35, legendary 69, mythical 22.

**Six legendaries and mythicals are deliberately unhatchable** by any tier, and
this needs no special case: Silvally, Cosmoem, Solgaleo, Lunala, Melmetal and
Urshifu are all evolution targets, so invariant 21 excludes them. Type: Null,
Cosmog, Meltan and Kubfu are all in the Ultra pool, so the path exists. That is a
feature. The only route to Solgaleo is hatching a Cosmog and raising it, which is
how the mainline games do it and gives the evolution system something to do at the
top of the collection.

### The tier changes the pool and the price, and nothing else

Shiny odds, the gender roll, the `.hatch` source and therefore the Dust payout are
identical across the four. **One dial**, so an Ultra Egg is understood the moment
the pool is.

Keeping the source as `.hatch` for every tier is what keeps invariant 17 stated
once instead of four times, and it is why a duplicate mythical out of a Master Egg
is still a ~26 Dust windfall rather than 25,000 coins wasted. PokeFit's §10.4.5
called that a happy accident of two independent designs meeting; it holds here
unchanged.

The weighting inside a pool is unchanged too: `captureRate`, never the band. The
band decides *membership*, the raw rate decides the draw, which is why an Ultra Egg
still favours Type: Null over Mewtwo. The one ceiling on that is
`HatchRoll.legendaryWeightCap`, added 2026-08-27 and recorded in "Three legendaries
hold the maximum capture rate" below.

**Recording the tier on the catch event was considered and set aside.** "What did
my Master Eggs give me" is a fair question and the log's whole design is to answer
questions nobody thought of yet, but `CatchEvent` has a synthesized decoder, and
invariant 23 means a new field there needs a hand-written one. That is real
migration risk on the one file that cannot be re-derived, for a question nobody
has asked. Deferred, not rejected.

### Pricing: each tier is the cheapest route to its own promise

The plain Egg drops from 300 to **200**, at the user's suggestion, so the bottom of
the ladder stays the thing you open without thinking about it.

Prices are not chosen for feel. Because the pools **nest**, a plain Egg can already
produce a mythical, so every tier competes with spamming the tier below it. With
`p` the weighted chance of the thing you are actually buying, measured on the real
manifest:

**Re-measured 2026-08-27** under `HatchRoll.legendaryWeightCap`. The pre-cap
figures are in the same row for comparison, because the cap moved every one of
them and the ladder was originally priced against the old column:

| Route | Coins per legendary | Coins per mythical |
|---|---|---|
| Egg, 200 | 200 / 0.0108 = **18,558** (was 10,165) | 200 / 0.0032 = **63,384** (was 63,960) |
| Great, 600 | 600 / 0.0877 = **6,843** (was 3,989) | 600 / 0.0257 = **23,373** (was 25,099) |
| Ultra, 3,500 | **3,500**, certain | 3,500 / 0.2928 = **11,954** (was 22,023) |
| Master, 20,000 | | **20,000**, certain |

Read down the legendary column: every tier still undercuts every cheaper route to
the same outcome, and the Ultra Egg does it with certainty and with more headroom
than before (3,500 against 6,843, where it used to be 3,500 against 3,989).
**Break one of those inequalities and the tier becomes a trap**: it still sells, it
just quietly costs more than the cheaper egg it is meant to improve on.

**The mythical column is now broken at the top, knowingly**, and that is its own
decision recorded below. A test restates the whole chain against the live manifest
rather than against these numbers, so moving a price or a pool fails at the desk.

Against this machine's ~1,080 coins/day: 0.19 days for an Egg, 0.56 for a Great,
**3.2 for an Ultra** and **18.5 for a Master**.

**The Master Egg sits well under the Shiny Charm at 30,000 on purpose.** A
consumable should not outprice the game's flagship permanent.

### The hazard: coins laundering into Dust, and the exception the user took

**The clean rule is that the plain Egg stays the most coin-efficient source of
Dust.** Dust pays out on the raw capture rate, and the higher pools are full of
capture-rate-3 species, so their duplicates are worth far more per hatch. Expected
Dust per duplicate, re-measured 2026-08-27 under the legendary weight cap: Egg
**1.97**, Great **7.99**, Ultra **30.30**, Master **25.75** (was 1.97 / 7.51 /
16.90 / 25.75). Keeping coins-per-Dust ascending therefore needs **floor prices of
811, 3,077 and 2,614**. Note the Ultra Egg overtaking the Master Egg on expected
Dust: the cap shifts weight off three capture-rate-255 legendaries and onto
capture-rate-3 ones, which pay 85 Dust each.

That matters because coins accrue passively and buy volume while Dust comes only
from duplicates and buys choice. The whole two-currency design (see "Currency"
above) is that a quiet week cannot be bought out of and a lucky one cannot be idled
through, and a coins-to-Dust exchange rate collapses it. Same family as invariant
17, which exists to stop exactly this through re-rolls.

**The user priced the Great Egg at 600 knowing it breaks this, tuning for
enjoyment: "Meh, yolo. Let's run this to maximize my enjoyment."** Recorded as a
decision rather than a mistake, with what it actually costs measured rather than
asserted:

| | Coins per Dust | Dust per day if you spend everything here |
|---|---|---|
| Egg, 200 | 101.3 | ~10.7 |
| **Great, 600** | **75.1** | **~14.4** |
| Ultra, 3,500 | 115.5 | ~9.3 |
| Master, 20,000 | 776.6 | ~1.4 |

(Re-measured 2026-08-27 under the cap. Was 101.7 / 79.9 / 207.1 / 776.6. The Ultra
Egg halving its coins-per-Dust is the cap's largest side effect and is the reason a
cap of 30 was rejected: at 30 it reached 95.2 and undercut the plain Egg outright,
breaking this section as well as the one above.)

**The magnitude is small where the principle is loud.** Coins already converted to
Dust through plain eggs, so this makes an existing rate 27% better rather than
opening a new door: a whole day's income goes from ~10.6 Dust to ~13.5. The real
cost is not inflation, it is that **the plain Egg loses its job**. It shrinks to
being the only source of the 304 commons and uncommons a Great Egg cannot produce,
which is a genuine purpose but a much smaller one than "the egg you buy".

**So what is defended now is the bound, not the ordering**, and the test was
rewritten to say so rather than deleted. Three things it still pins:

- The Great Egg is the **only** inversion.
- Its advantage stays under **1.5x**. At 400 the ratio is 1.9x, and that is a
  genuine mint rather than a discount.
- Ultra and Master stay strictly worse than **both** cheaper eggs. Those are the
  two that would really print, at ~17 and ~26 Dust a hatch.

A test that asserts a violated invariant is worse than no test, and a test quietly
deleted to make a build green is worse still. This is the third option: assert the
exception explicitly, so the next reader finds a recorded decision instead of a
puzzle, and the guard that still matters keeps working.

### Three legendaries hold the maximum capture rate, and the roll now caps them

**Found 2026-08-27, from a screenshot.** The user hatched a duplicate Terapagos at
27 owned sprites and 14 lifetime hatches and said the odds felt wrong. They were
right, and it was not luck.

**Necrozma, Eternatus and Terapagos all have `capture_rate` 255**, the maximum in
the game, while being legendary. Each is a scripted, effectively guaranteed story
catch in its most recent appearance, which is why the anomaly clusters on
legendaries and nowhere else in the dex.

The data was checked before anything was changed, because the user had read 3 on
Bulbapedia:

| Source | Necrozma | Eternatus | Terapagos |
|---|---|---|---|
| PokeAPI `pokemon-species` | 255 | 255 | 255 |
| PokeAPI source CSV, `pokemon_species.csv` id 800 | 255 | 255 | 255 |
| PokemonDB | 255 | 255 | 255 |
| Bulbapedia infobox | **3** | 255 | 255 |
| Bulbapedia trivia, same page | 255 in USUM and SwSh | | |

Bulbapedia's infobox carries the **debut generation's** value; Necrozma was
rebalanced from 3 in Sun/Moon to 255 in Ultra Sun/Moon and again in Sword/Shield,
and that page says so itself two sections down. Controls run at the same time
(Mewtwo 3/3, Koraidon 3/3, Zacian 10/10, Caterpie 255/255) all agreed, so this was
generation scoping rather than an error in either source. **The manifest is
correct and `generate-dex.py` needs no change.**

What was wrong was the *consequence*. Weighting on the raw rate made those three
the heaviest entries in every pool, which is invisible in the 570 entry pool and
dominant once a tier narrows it:

| | Pool | Terapagos per hatch | The three combined |
|---|---|---|---|
| Egg, 200 | 570 | 0.36% | 1.1% |
| Great, 600 | 266 | **2.78%** | **8.4%** |
| Ultra, 3,500 | 91 | **18.5%** | **55.5%** |

So 3,500 coins for a guaranteed legendary was 55.5% likely to be one of three
species, and the next-heaviest entry in the Great pool was Bruxish at 0.87%,
making Terapagos a 3.2x favourite over the most likely non-legendary. Two
Terapagos in 14 hatches is ~5.7% if every egg was a Great and ~16% by the fourth
Ultra. Ordinary, in other words.

It also inverted the payout. Dust is `255 / captureRate`, so these three pay the
**floor of 1 Dust**: the most likely legendary duplicate was worth the same as a
Caterpie, which is the reading that put it on screen in the first place.

**The fix is `HatchRoll.legendaryWeightCap = 45`**, a ceiling on the weight of a
legendary or mythical entry. 45 is where the other legendaries cluster (7 of the 91
hatchable ones sit there exactly), so it reads as "no legendary outweighs the
ordinary legendaries" rather than as a tuned constant, and it **changes exactly
three entries**. Terapagos goes from 18.5% of an Ultra Egg to 6.02%, the same
weight as Mew.

**The cap is on the weight only. Dust still pays on the raw rate**, per invariant
17. The weight decides how often a thing appears; the raw rate is what the thing is
worth. A Terapagos duplicate is still 1 Dust, and a test pins that, because capping
the payout too would lift the Great Egg's expected Dust straight through the bound
the section above defends.

`HatchRoll.weight(for:)` is exposed rather than inlined so the ladder's two pricing
tests measure the distribution the roll actually uses. They previously read
`captureRate` directly, which was the same thing until this landed.

**A cap of 30 was asked for first and withdrawn once costed.** It pulls the seven
entries at 45 down as well, and the resulting shift broke *both* pricing
invariants: the Ultra Egg reached 95.2 coins per Dust against the plain Egg's
101.6, a second Dust inversion on top of the Great Egg's.

#### The Master Egg's promise is knowingly broken, and this is why

Any cap at all breaks invariant 41's mythical chain, which was missed on the first
pass here: capping takes 630 of the Ultra pool's 1,378 weight off three legendaries
and **none off the mythicals**, so the mythical share of an Ultra Egg roughly
doubles, 15.89% to 29.28%. That makes the Ultra Egg the cheaper route to a
mythical, **11,954 coins against the Master Egg's 20,000, a 1.67x overpay**.

Both exits were priced and put to the user:

| | Change | Result | Cost |
|---|---|---|---|
| A | Master Egg 20,000 -> **10,700** | Cheapest mythical again, 10% headroom | The top egg drops from 18.5 days to ~9.9 |
| B | Ultra Egg 3,500 -> **6,600** | Ultra per mythical back to 22,542 | Valid window is only 6,600 to 6,843, a 4% target, and Ultra goes 3.2 days to ~6.1 |

**The user took neither and accepted the break**, keeping both prices as tuned.
Recorded as a decision rather than a mistake, and the recommendation at the time
was against it: at 1.67x this is a larger magnitude than the Great Egg's accepted
27% on Dust, and the Master Egg is now a trap in exactly the sense invariant 41
defines. What makes it survivable is that the Master Egg's promise is *certainty*
rather than expectation. 11,954 coins of Ultra Eggs gets a mythical on average and
can still hand over eleven legendaries in a row; 20,000 cannot miss. That is a real
thing to sell, it is just no longer the cheap thing.

So the test pins the **bound**, the same shape as the Great Egg's Dust inversion:
the overpay is asserted to exist, so quietly un-breaking it fails and sends the
reader here, and it is asserted to stay under **1.8x**, so the next price or pool
change cannot widen it without failing at the desk.

### Two ladders were declined, and one was impossible

Recorded because the arithmetic is the useful part, not the outcome.

**200 / 800 / 5,000 / 25,000 shipped first and was declined.** It satisfied every
constraint with ~20% headroom on both ceilings. Rejected as too slow: an Ultra Egg
at 4.6 days and a Master at 23.

**200 / 600 / 4,500 / 20,000 was proposed by the user and does not work**, for two
reasons rather than one. The Dust inversion above, and separately the Ultra Egg
becomes *dominated*: Great-spam gets a legendary for 3,989 expected while the Ultra
Egg costs 4,500, so the tier that guarantees one is strictly worse than the tier
that gambles for one. Dropping Ultra to 3,500 is what fixed that, and it is why the
final ladder is not simply the proposal with one number changed.

**Keeping the Great Egg at 600 *and* the Dust ordering is impossible above an Egg
price of 157.** The floor is `600 / 7.51 > Egg / 1.97`, which depends on nothing but
the Egg price, so no other price can rescue it. A 150 / 600 / 3,500 / 20,000 ladder
is fully valid and was set aside: halving the entry price to protect a rule the user
had already decided to spend was the wrong trade.

### Where the ladder lives in the UI

**A split button on the Raise pane, and the full ladder in the Shop.**

**Choosing a tier does not buy it.** The menu sets a selection, the button spends
the coins, and nothing hatches until the button is pressed: click the arrow,
choose, read the price under the button, click Hatch.

The first version hatched on the menu row itself, one click. **The user caught it
and asked for the failsafe**, and they were right: a Master Egg is 20,000 coins,
18.5 days of accrual, and coins are frozen at credit time, so a menu row that
bought on selection was one slip away from being unrecoverable. Nothing else in
this app spends that much without the price on the control being pressed.

So the button now names the tier ("Hatch Master Egg") and a line under it names
the price and the pool ("20,000 coins. 22 of 570 entries, always a mythical."),
turning orange when the selection is unaffordable. The button is the only thing
that spends, so it has to say what it is spending on.

**Two controls rather than one split button**, which is where this costs
something. `Menu(primaryAction:)` looks better and was the first shape, but it
cannot disable its primary action independently of its menu. That leaves two bad
options for an unaffordable tier: keep the button live so a click produces an
error, or disable the whole control including the arrow, which traps the player on
a selection they cannot change. A separate `Button` disables cleanly while the
arrow stays live at zero coins, which is exactly when it is needed.

**The three controls in the row all draw at 20pt, and getting there took
measuring rendered pixels rather than layout boxes.** The user caught the arrow
sitting at a different height from the Hatch button, twice, and the first fix was
wrong in a way that is worth recording because it is a trap.

What does not work: **`frame` and `padding` do not change a bordered control's
bezel height.** `ImageRenderer` reports the *layout* size, so framing the Menu to
21pt duly reported 21pt and drew a 14pt bezel centred inside it. Reading the
layout size looked like confirmation and was not, which is how a change shipped
that visibly did nothing. The check that actually answers the question is
rendering the control and scanning the bitmap for the vertical extent of drawn
pixels.

Measured that way, at `.small`:

| Control | Drawn height |
|---|---|
| `Button` + `Label("Hatch Egg", systemImage: "oval.portrait.fill")` | **21pt** |
| `Button` + `Label("Rare Candy (2)", systemImage: "capsule.fill")` | 20pt |
| `Menu` + bare `Image` | 14pt |
| `Menu` + any label carrying text metrics | 20pt |

**So the arrow was right and the egg was wrong.** `oval.portrait.fill` is a tall
symbol, and at its default scale it alone pushed the Hatch button a point above
every other control in the row, including the Rare Candy button that had been
sitting beside it since v1. `.imageScale(.small)` on that label brings it to 20pt.
**Confirmed on screen at the third attempt**, which is the count worth remembering:
this is a class of bug that cannot be seen in code and cannot be trusted from a
layout measurement either.

The arrow uses `Text(Image(systemName: "chevron.down"))` rather than a bare
`Image`, because a `Menu`'s bezel height is **quantized by the kind of label it
has** and ignores padding and frames: an image label is 14pt and anything with
text metrics is 20pt, with nothing in between. Wrapping the chevron in a `Text` is
what buys the 20pt.

One residual to know before adding a control here: a SwiftUI `Menu` at `.small`
cannot be made 21pt at all, so if the Hatch button ever needs its full-size glyph
back, the arrow cannot follow it and the row would need an AppKit bridge, the way
`SegmentedTabs` already does for a different unreachable knob.

Widths measured the same way, because the longest title is 43% wider than the old
one: 132pt for "Hatch Master Egg", 35pt for the arrow and 123pt for the Rare Candy
button, so **300pt of the pane's 312pt** in the worst case. 12pt spare. The price
moved out of the row to make that fit, and reads better for it: it is a
confirmation, not a column.

**A cheap tier stays selected after a hatch and an expensive one does not.**
`EggTier.isRoutine`, which is true for the Egg and the Great Egg and false above
them, so six Great Eggs are six clicks while a Master Egg falls the selection back
to plain. That keeps the spam case fast and stops a second click on a button the
player has stopped reading. The rule lives on `EggTier` rather than in the view so
it can be tested, and the test pins the boundary at a day's income (~1,080 coins):
a routine tier is one a day's earnings covers.

**The Shop rows are unchanged and still hatch on one click**, deliberately. There
the price is *on* the button next to the name, which is the same shape as every
other shop item including the 30,000 coin Shiny Charm. The dropdown was the
problem because picking from a list does not feel like committing; pressing a
button labelled "20,000" beside "Master Egg" does.

**Exercised on screen and signed off 2026-08-26**, on a Great Egg hatched through
the full arrow, choose, read, hatch sequence.

The Shop gets an EGGS section even though an egg is not an item and there is never
one to hold. What it adds is the ladder **side by side**: four prices against four
pool sizes is the only view that makes the choice between them legible, and a
price list is what a shop is. Pool sizes come from the dex, never typed into the
copy, so a new generation moves the shop's numbers on its own.

---

## Today by project, in the Usage tab

Asked for 2026-08-27: a second breakdown beside the per-model one, showing
today's tokens per project with a percentage, behind a switch that shows and
hides it. **Approved on screen the same day**, rendering PokeBar 45% / 7.11M,
pokefit-ios 37% / 5.79M and Before this update 18% / 2.80M, with no scrolling
needed at five tabs plus three project rows. Five rows was not tested against a
real overflow, because this machine only had two projects live that day; the
"N more" collapse is pinned by tests, not by pixels.

**It needed a new table, because the data did not exist.** The ledger had
`daily[day][model]` (raw tokens, per local day) and `weightedByProject[project]`
(tier-weighted, all time), and neither answers "how much of today went where".
Weighted totals are the wrong denominator for this pane anyway: the section sits
under "Today" and its percentages have to be fractions of the *same* figure the
per-model rows divide up, or two tables of one day disagree about the day.
`UsageLedger.dailyByProject` is therefore raw tokens, keyed day then working
directory, credited from the same `delta` in the same loop as `daily`.

Deriving it from `daily` was never possible. A turn carries a model and a project
independently, and once the pair is summed into a per-model bucket nothing
recovers it.

**Forward-only, and the gap is shown rather than hidden.** Cursors do not rewind,
so a ledger written before the new key existed cannot be backfilled, and
rescanning from zero to try would re-credit every turn older than the 2 day
`growthWindow` and mint coins for it. That is the same reasoning that made
per-project attribution forward-only in the first place (above), one layer down.
What is new is the handling: `ProjectBreakdown.rows` takes the day's real total as
a parameter and emits a **"Before this update"** row for the difference. On the day
this ships, the section adds to 100% of the day with the shortfall named; from the
next day on, that row never appears again. The alternative was a section whose
percentages each read too high while quietly claiming to cover the day. A corpus
test asserts the two day tables agree for every day in the live tree.

**That row was first labelled "Not attributed", and the label was wrong.** The
user read it as a token leak and asked where the tokens were going, which is the
correct reaction to those words: they say the tokens have no home. They have one.
Measured on the live ledger the moment the question was asked, on 2026-08-27:
today's total was 8,787,923 by model against 5,988,341 by project, a gap of
2,799,582; sampled again a minute later both totals had risen by an identical
164,382 and **the gap had not moved by a single token**. It is a frozen historical
constant, not a rate. The cause was visible in the timestamps: the day began at
midnight and the new binary started at 00:09:41, so 9m41s of turns were credited
by a build with nowhere to put the project.

The row therefore has exactly one possible cause, and the label should name it. A
turn that genuinely does not say where it ran is a *different* thing: it goes to
`Project.unknown` and reads "Unknown". So the copy is about *when*, not about
attribution. Worth remembering as a copy rule generally: a bookkeeping row on a
usage screen is read as an accusation unless it says why it exists.

**Names are disambiguated on collision, and only on collision.** Attribution is
by working directory, so this machine really does have
`.../PokeBar/Assets.xcassets` beside `.../PokeFit/Assets.xcassets`. Two rows both
reading "Assets.xcassets" is silent: the numbers look like they should have been
added together. Colliding names are qualified with their parent
(`PokeBar/Assets.xcassets`); everything else stays a bare last component, which is
what it was already. This is a display fix, not a change to what is recorded, and
the roll-up-to-a-git-root question stays deferred.

**The tail collapses to "N more", not to "Other".** Twenty-plus directories are in
play and only five rows fit, so the count is the informative part: "Other" tells
you a tail exists, "15 more" tells you how much of the list you are not seeing.
The per-model side keeps "Other" because five models is the whole list plus
rounding.

**The row is laid out against `PopoverMetrics.ModelRow`, deliberately.** The two
tables sit one above the other in one pane, and columns that nearly line up read
worse than columns that do. The one thing that could not carry over is the
measurement: a model name is a parsed identifier with a known worst case
(`"GPT 5.6 Terra (Copilot)"`, 130.8pt), and a project name is whatever a directory
is called. So the project row scales to 0.85 and then truncates in the *middle*,
because the distinguishing part of a qualified name is at both ends.

**The switch is a display preference and defaults to shown.** Same key family and
same reasoning as the Raise pane's eye toggle: what is on screen is a list of
directory names, one of which may be a client's, and a menu bar app gets opened in
front of people. `@AppStorage("PokeBarShowProjectUsage")`, never the ledger, and
**recording never stops** because a hole here could never be filled in. The
section header stays visible when the rows are hidden, since it carries the only
control that brings them back.

---

## Evolution items are 100 coins, set 2026-08-28

`Prices.evolutionStone` and `Prices.linkingCord` went 400 -> 100, at the user's
direction: items read as too expensive in play. Nothing else moved. Rare Candy
stays at 250, the Shiny Charm at 30,000, the Exp Share at 10,000 and the egg
ladder at 200 / 600 / 3,500 / 20,000, all of which were considered in the same
breath and declined.

**The figure that makes the old price wrong is 95, not 400.** A stone is
*consumed* by the evolution it unlocks (`Trainer.evolve` decrements the
inventory), so 400 was never the price of an item, it was the price of one edge,
paid again for the next Vaporeon. The item edges are 69 stone plus 26 trade, so
the completionist bill was 38,000 coins, ~35 days of accrual at this machine's
~1,080 coins/day, against the Shiny Charm's 30,000. An item that gates *taste*
outpricing the game's flagship permanent is the wrong ordering, and it is the
same reasoning the Everstone section already records: item edges are the branch
the player is meant to choose, and a per-use tax on choosing is a tax on the only
part of evolution they steer. At 100 the bill is 9,500, ~8.8 days, which sits
below one Exp Share and reads as a running cost rather than a wall.

**Why this price is safe to move alone, unlike an egg price.** The three egg
prices constrain each other (invariants 41 and 42: the pools nest, so every tier
competes with spamming the one below, and the Great Egg sets both ceilings above
it). An item is not on that ladder. It buys no draw, mints no Dust, and appears in
no expected-value comparison, so nothing rebalances and no test moves. The two
constants are named separately and stay equal only by coincidence of value: a
stone and a cord gate different edge kinds, and `Trainer.ShopItem.priceInCoins`
already branches on the slug.

**What it costs, stated so nobody has to rediscover it.** Coins are already not
the bottleneck (raising time is), and this removes one of the few places they bit.
The four dead cheap purchases were never the interesting decision; the interesting
one is *which* branch a Nincada or an Eevee takes, and that is unpriced either
way. If items later feel free to the point of pointless, the fix is upward from
100 and it is a one-line change with no ladder attached.

---

## Menu bar UI

**The status item shows coins, not tokens or cost.** Coins are the game currency
and the reason the app exists. The restored ledger publishes them before the cold
scan starts, so a relaunch shows a real figure immediately instead of a zero that
climbs for 17 seconds. Compact three-significant-digit formatting keeps the item's
rendered width roughly constant as the figure grows, so the menu bar does not
shuffle on every update.

**Formatting is hand-rolled, not `NumberFormatter` or
`RelativeDateTimeFormatter`.** These strings are asserted in tests, and the system
formatters are locale- and SDK-dependent, so the assertions would be testing the
OS rather than this code. One machine, one locale: delegating buys nothing here.

**Model display names are parsed from the identifier, not shipped in a table.**
`claude-haiku-4-5-20251001` renders as `Haiku 4.5`, and an unrecognised
`claude-quasar-7` still renders as `Quasar 7`, in grey. This is the display-side
counterpart to pricing resolving to `nil` rather than `0`: a model newer than our
tables must look unknown, never blank and never free. A hardcoded name table would
go stale on the same launch day the pricing table does, which is the upstream
failure this project already fixed once.

**Popover geometry is a testable constant table, not literals in view bodies.
Decided 2026-08-24**, when adding a third usage source made the model rows
outgrow their columns. The popover is a chosen 340pt with 14pt padding, so a pane
lays out in 312pt, and `PopoverMetrics` now owns that arithmetic. Three things
were wrong on screen and all three had the same cause, a leading-aligned `VStack`
handing each child its ideal width and letting the rest of the row go to waste:

- The segmented tab picker sat bunched against the left edge. `maxWidth:
  .infinity` widened the container and left the control **centred** inside it,
  which is a second wrong answer rather than a fix. SwiftUI wraps
  `NSSegmentedControl` at `segmentDistribution = .fit`, sizing each segment to
  its own label, and exposes no way to change it, so the control is now bridged
  directly as `SegmentedTabs` with `.fillEqually`. Reimplementing the tab bar in
  SwiftUI was the alternative and it costs more than it buys: the native look is
  already right and a hand-built copy would drift from it on the next OS.
- The token-class grid hugged the left with a gap beside it. Its cells now split
  the width evenly, which incidentally lines "Cache read" up under "Output".
- The model rows spent 282 of 312pt and gave the name column 74 of them, so
  `"Sonnet 5 (Copilot)"` rendered as `"Sonnet 5 (Co..."`. The name column is now
  fixed at 132pt at 12pt type and the **bar** is what flexes.

The name-fixed-bar-flexes direction is the load-bearing part. It is the only
arrangement that both fills the row and keeps every bar starting and ending on
the same x, which is what makes the bars comparable down the column at all. The
widths were measured with `NSFont.systemFont` rather than estimated: at 12pt the
widest name this can produce is `"GPT 5.6 Terra (Copilot)"` at 130.8pt, and the
two numeric columns hold `"100%"` at 28.6pt and `"76.7M"` at 31.2pt. A test
asserts the budget still leaves the bar at least 60pt, because overrunning it is
silent: the row lays out fine and the bar just collapses to its 3pt minimum and
stops meaning anything. `minimumScaleFactor(0.85)` is the last resort behind
that, on the grounds that a name reading slightly small beats a name losing its
tail.

Not fixed by widening the popover, which was the other option. 340pt was chosen
against the menu bar, not against this content, and the space to fill was already
there.

All three **approved on screen by the user 2026-08-24**, which is the only way
rendered pixels get verified here. It took two rounds: the first fixed the rows
and the grid and left the tabs centred, and the user caught that from a
screenshot. Worth remembering as the same lesson the menu bar sprite taught, that
a layout change is not verified until somebody looks at it.

**The per-model breakdown collapses everything past five rows into "Other".**
A layout guard, not cosmetics: the popover is a fixed-width menu bar window, and a
day that touched a dozen models would push it off screen. Ties break on model id,
because dictionary iteration order is not stable and rows must not shuffle between
two publishes of identical data.

**The popover re-derives its totals when it opens.** `todayTokens` is bucketed by
local day *at publish time*, so a quiet run across midnight would keep labelling
yesterday's usage "Today". The refresh reads no files and credits nothing; a test
pins that calling it repeatedly cannot mint coins.

**The dollar figure always carries its caption.** "On a subscription it is value
realised, not money spent" sits under the number every time rather than hiding in
a tooltip. When a model in use has no published price, the caption switches to say
the figure is a floor, which is the visible half of never reporting $0.00 for an
unpriced model.

**Activation policy is set at runtime, not in an `Info.plist`.** `swift run` has no
bundle to read `LSUIElement` from, and bundling and signing stay deferred until
this runs daily. One `setActivationPolicy(.accessory)` call in the app delegate
gets the same menu-bar-only behaviour today.

**No sprite yet.** The status item uses `smallcircle.filled.circle` as a stand-in
Poke Ball, and the tier colours (fable purple, opus orange, sonnet blue, haiku
green) carry the visual load. Species art arrives with the Pokedex data layer.

**An app bundle is mandatory to see the UI at all, so bundling is no longer
deferred.** `scripts/bundle.sh` assembles `dist/PokeBar.app`. Measured: SwiftUI
registers a `MenuBarExtra` status item only for a process that has a bundle
identifier, and `swift run PokeBar` produces a bare executable reporting
`CFBundleIdentifier = NULL`. The failure is silent and misleading in the worst
way: the app launches, the engine scans, the ledger credits coins, `pgrep` finds
a healthy process, and nothing is ever drawn in the menu bar. Diagnosed only
after asking the user to look at a menu bar that could not have shown anything.

`Info.plist` carries `LSUIElement`, which makes the runtime
`setActivationPolicy(.accessory)` call redundant for the bundled path. Both are
kept: the runtime call still covers running the binary directly, which is what
the tests and any headless check do.

**Code signing with a stable identity and a LaunchAgent stay deferred.** The
bundle takes an ad-hoc signature, which is all a local launch needs. The stable
identity mattered only for caching credentials under our own Keychain ACL, and
the app now deliberately holds no credentials at all.

---

## Tooling

**XCTest, not swift-testing.** `Testing` is not present in this toolchain.

**Usage-test fixtures date from `Date()`, not from a literal. Learned the hard way
2026-08-24.** `UsageMonitorTests` pinned `2026-08-22T12:00:00.000Z` and passed
every run for two days, then failed with two assertions that both pointed at
invariant 2 being broken. It was not. `UsageLedger.pruneInFlight` drops in-flight
entries by the **log** timestamp against a 2 day `growthWindow`, so once the
fixture aged past the window the first copy of a turn was inserted and pruned in
the same `credit` call, the streaming rewrite arrived looking like an id nobody
had seen, and the full 700 output tokens were credited on top of the partial 5.

The finding, not just the fix: a hardcoded timestamp in a test that runs through
the ledger is a **timer**, and it fails in the most misleading direction
available, accusing the one rule in the file that is working. The fix is a
relative timestamp plus a test that asserts the fixtures sit inside the window, so
the next person gets "your fixture is too old" instead of "growth crediting is
broken.

**`DEVELOPER_DIR` must point at Xcode.app to run tests.** `xcode-select -p` here
returns `/Library/Developer/CommandLineTools`, which has no XCTest. Scoped per
invocation via `scripts/check.sh` rather than changing a global machine setting
with `sudo xcode-select -s`.

**No GitHub Actions.** macOS runners burn free minutes fast. Pre-push checks run
locally through `scripts/check.sh`.

**Session close-out is a skill, not a habit.** `.claude/skills/wrap-up/SKILL.md`,
invoked as `/wrap-up`. Three fixed steps: what is pending on the user, reconcile
the three docs against the code, verify the repo survives a `/clear`. It requires
pasted command output rather than assurances and an explicit safe / not-safe
verdict, because this session twice reported something as verified on weaker
evidence than the wording implied: a menu bar item that could not have rendered,
and a Keychain blob whose shape had never been checked.

---

## Deferred, not rejected

- **History, trends, burn rate, limit projection.** Explicitly deprioritised.
  The scanner already emits dated entries, so the seam exists if it is wanted.
- **Alternate-form axis beyond regionals.** 260 further form sprites exist.
- **Parallel cold scan.** The 17s cold start is single-threaded and could fan out
  across files. Only matters once per install, so not yet worth the complexity.
- **Thinning level-ups out of the activity feed.** Deferred by the user on
  2026-08-24, with the problem already confirmed on screen: with a team of three,
  all four feed slots read "X reached level N", so a hatch, an evolution or a Dust
  payout is pushed off within one tick. The user looked at it and chose to keep it
  as it is for now, explicitly leaving the door open.

  Recorded so the next session does not have to rediscover the shape. Two options
  were costed, and the *first* is the one to reach for:

  1. **Drop level-ups from the feed.** A level-up is the one event in that list
     the card above already shows, twice over, as a number and as a bar. The feed
     would become the things you would otherwise miss. Notifications already
     exclude level-ups on exactly this reasoning, at 99 per climb and now up to
     six climbs at once.
  2. **Group them**, the way `Notifier.announcements` groups its own: "3 Pokemon
     levelled up" as one line. Keeps the sense of motion but still spends a slot
     on it every tick.

  **Do not raise this unasked.** It is a display preference the user has looked
  at and settled for now, in the same category as the Dust prices.

- **A completionist readout: a gold counter, and a "not yet golden" Dex filter.**
  Declined by the user on 2026-08-24, having asked whether the game can account
  for someone who wants every variant collected and every one of them golden.

  It can, in the *data*. Ownership is per sprite across 2,368 slots
  (`CatchLog.filledSlots`), milestones are stored both per sprite and per entry
  (`milestoneBySlot`, `milestoneByEntry`), the roster is append-only so 2,368
  graduated individuals can coexist, and the Everstone is what makes gold
  reachable on a mid-line form at all: without it a Charmander can never cross
  100 as a Charmander.

  The two gaps are in the *readout*, and both are small because the data already
  exists. The Dex header counts seen and sprites but not graduated, so tracking a
  gold run means opening 1,083 tiles; and the filter is All / Caught / Missing,
  with no way to ask "which ones are left", which is the only question a
  completionist is asking by then.

  The arithmetic, so nobody has to redo it. Slots break down as 1,083 normal +
  1,081 shiny + 102 female + 102 shiny female = 2,368 exactly. At this machine's
  throughput with a full team and the Exp Share (1.30M XP/day):

  | Goal | Time |
  |---|---|
  | One gold per entry, 1,083 climbs | ~2.3 years |
  | Gold on every sprite, 2,368 climbs | ~5.0 years |
  | Either, solo at 1.0x | 13.7 / 29.9 years |

  Collecting is the harder half, not raising: 568 base forms need a shiny roll at
  1/48 with the charm against ~7 Dust/day, while the 513 evolution-gated forms'
  shinies come free by raising a shiny through its line. That is the Dust wall the
  user has already parked, and it, not the XP curve, is what gates this.
