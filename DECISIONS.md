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

**Claude Code is the only usage source.** Dropped Codex, Copilot CLI, Cursor and
the other seven upstream providers.

- Copilot: upstream expects `~/.copilot/session-store.db` with an
  `assistant_usage_events` table. That file does not exist on this machine; only
  `config.json`, IDE locks and process logs. Nothing to read.
- Codex: this machine runs a newer SQLite build (`state_5.sqlite`,
  `logs_2.sqlite`) with no `~/.codex/sessions/*.jsonl` at all, so the upstream
  parser would report zero forever. Worse, `threads.tokens_used` is a single
  cumulative integer with no input/output/cache split, so cost cannot be derived
  honestly. Deliberately out of scope.

**No `UsageProvider` protocol.** With one source, a provider abstraction is
speculative generality. Extracting a protocol later from one working
implementation is easy and better informed than guessing its shape now.

**No SQLite dependency.** Claude Code usage is append-only JSONL. Upstream
linked `libsqlite3` only for Codex, Cursor, Copilot and Kiro.

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
325 KiB, checked in. Four reasons, in descending weight:

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

*Aspect-preserving fit is mandatory.* Gen-V animated GIFs have a per-species canvas
that is not square, while every static sprite is a uniform 96x96. So stretching to
fill a square box is invisible on the static path and distorts only the animated
one, which is the path the menu bar uses:

| Entry | gen-V GIF | static PNG |
|---|---|---|
| Bulbasaur #1 | 37x38 | 96x96 |
| Pikachu #25 | 50x46 | 96x96 |
| Gengar #143 | 74x75 | 96x96 |
| Spoink #325 | **36x66** | 96x96 |
| Lucario #448 | 47x63 | 96x96 |
| Glaceon #471 | 76x54 | 96x96 |

Spoink stretched to square renders 1.83x too wide.

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
