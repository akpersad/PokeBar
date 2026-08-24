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

**Switching Pokemon is free and unrestricted, with no level gate.** A gate at level
20 was considered and rejected. With 570 hatchable entries drawn at random, hatching
something you do not care about is the common case, not the exception, and a gate
punishes the player for the game's own randomness. The real cost is already built
in and needs no rule: swapping abandons that individual's levels, and the next
hatch starts at 1. Whatever was reached stays in the log, so switching is never
destructive to the collection, only to the individual. Shiny re-rolling is governed
by the re-roll price, which is a separate knob from swapping.

**The abandon-levels half of that is reversed for v2, 2026-08-24.** The gate
rejection stands; what does not is treating lost levels as the cost. The user's
words: "I shouldn't lose my progress on Charizard if I want to switch out to
another pokemon for a week." Levels will persist per individual. See the v2
section below.

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
| Evolution stones | **400 coins** | 23 items, gating 69 edges |
| Linking Cord | **400 coins** | Gates 26 edges |
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
implementation would overwrite. Switching is still the one thing that costs levels,
and it is the one thing the player asks for explicitly.

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

**It is held by the individual, not set by the player.** Switching starts the next
Pokemon without one, which is what "held item" means and also the behaviour that
needs no explaining.

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

Nothing below is implemented.

**Levels persist per individual, permanently.** Reverses the paragraph above.
`Trainer.active: Raise?` becomes a roster plus an ordered team, and identity is
`Raise.id` rather than `VariantSlot`, because a `Raise` mutates its own `entryID`
as it evolves and a slot-keyed store would need rekeying on every evolution.
`MilestoneEvent.raiseID` already exists and its doc comment already wants two
Pikachu to be two individuals, so this is the shape the log was written for.

**A team of up to 6 gains XP simultaneously.** Slot 1 at 1.0, slots 2 to 6 at
0.8 each, per occupied slot, so a team of two is 1.8x and the ramp is smooth.

**Exp Share is a boost, not a split.** 10,000 coins, one-time, then a free
toggle. If slot 1 gets 100 XP then slots 2 to 6 each get 100 XP; the credit is
never divided across the team. The divide-by-six reading was raised and rejected
by the user: it would make a paid item a *downgrade* from the free 5.0x default.
Priced at 10,000 rather than 5,000 because it is passive and permanent, which is
the class the Shiny Charm sits in at 30,000; at 5,000 it is 4.6 days of accrual
for a permanent +20% and is bought without thinking.

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
cosmetic to fix. The bench share is the dial if it needs turning, and it lives in
one constant for that reason.

**Per-project attribution records always, displays optionally.** The user wants
to hide it sometimes, not to stop collecting it. A toggle that gated *recording*
would leave holes that can never be backfilled, because the ledger credits each
turn exactly once and cursors do not rewind. The toggle is therefore a display
preference in `UserDefaults`, never in `game-state.json`: nothing re-derivable
belongs in the one file that cannot be re-derived.

**Deferred by the user, not rejected:** widgets, and battles. Battles were liked
but named as a risk of "losing the plot of a token use project", and would also
require reopening "stats are out", which is what Mint's rejection hangs off.
Types in the manifest were only ever proposed as a battle prerequisite and go
with it.

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

- The segmented tab picker sat bunched against the left edge. Fixed with
  `maxWidth: .infinity`, which also gives the four labels more room.
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
