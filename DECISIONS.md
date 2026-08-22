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
idle minute costs nothing instead of re-reading half a gigabyte.

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
as unknown, never as free.

**Limits use our own Keychain item.** This machine has no
`~/.claude/.credentials.json`, so the OAuth token is Keychain-only, and upstream's
automatic polling deliberately never reads the Keychain (they measured a 13s block
and a password prompt), leaving the limits percentage stale until manually
refreshed. Upstream had to delete their own Keychain cache because each public
release changed the code signature and broke the item ACL. We sign once with a
stable local certificate that never changes, so we can cache the credential under
our own ACL and refresh silently. Available to us precisely because this is not
distributed.

---

## Tooling

**XCTest, not swift-testing.** `Testing` is not present in this toolchain.

**`DEVELOPER_DIR` must point at Xcode.app to run tests.** `xcode-select -p` here
returns `/Library/Developer/CommandLineTools`, which has no XCTest. Scoped per
invocation via `scripts/check.sh` rather than changing a global machine setting
with `sudo xcode-select -s`.

**No GitHub Actions.** macOS runners burn free minutes fast. Pre-push checks run
locally through `scripts/check.sh`.

---

## Deferred, not rejected

- **History, trends, burn rate, limit projection.** Explicitly deprioritised.
  The scanner already emits dated entries, so the seam exists if it is wanted.
- **Alternate-form axis beyond regionals.** 260 further form sprites exist.
- **Parallel cold scan.** The 17s cold start is single-threaded and could fan out
  across files. Only matters once per install, so not yet worth the complexity.
