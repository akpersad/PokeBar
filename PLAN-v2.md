# PokeBar v2 work plan

Written 2026-08-24. **Steps 0 to 5 are built; steps 6 and 7 are not started.**
Priority order is the user's, set in the brainstorm that produced this file:
**the team comes first.**

Read DECISIONS.md before starting any step. Every step below that changes a
directional call names the DECISIONS.md section it has to amend *first*.

---

## The headline change, and why it is smaller than it looks

Two things the user asked for, in one phase:

1. **Levels always persist.** Switching away from a Charizard for a week and
   coming back must not cost its levels. Today `Trainer.setActive` builds a
   brand new `Raise` at level 1 and drops the old one on the floor
   (`Trainer.swift:408`). That is recorded as deliberate in DECISIONS.md
   ("the cost is losing that individual's levels") and is being **reversed**.
2. **A team of up to 6**, gaining XP simultaneously. Slot 1 takes the full
   share, slots 2 to 6 take a smaller but consistent share. An **Exp Share**
   purchase levels that up so every slot takes the full share.

### The throughput arithmetic, stated before it is built

Today one individual absorbs 1.0x of the XP a credit is worth. With five party
slots at 0.8, a full team absorbs **5.0x**; with Exp Share, **6.0x**. That
directly contradicts "raising time is the bottleneck, not coins", which
DECISIONS.md treats as load-bearing.

It matters much less than that framing suggests, and the numbers are the reason:

| | XP | Days at 216,000 XP/day |
|---|---|---|
| Level 36 (the deepest common evolution edge) | 129,600 | **0.6** |
| Level 50 (silver ring) | 250,000 | 1.16 |
| Level 100 (gold ring, graduation) | 1,000,000 | 4.63 |

Evolution is *already* fast. What is slow is graduation, and graduation
deliberately pays out nothing: `Trainer.milestoneLevels` is display-only and
DECISIONS.md keeps it that way on purpose, because whether level 100 should
reward anything is still open. So 6x graduation throughput inflates ring
colours and nothing else. No coins, no Dust, no unlock.

What the team actually buys is what the user asked for: six evolution lines
progressing at once instead of one, and no abandoned progress. Both are the
point.

Two real consequences to accept knowingly:

- **Rare Candy weakens.** It stays the only way to push one specific individual
  faster, but with six climbing at once its relative value drops. Watch it; do
  not pre-emptively reprice it.
- **The silver and gold rings get common.** If they are meant to feel scarce,
  the team is what ends that. Cosmetic, and reversible by changing what the Dex
  draws rather than by changing the economy.

The party ratio is the dial. It lives in exactly one place so it can be turned:

| Party share | Full team | With Exp Share |
|---|---|---|
| 0.8 (the user's example: 10 and 8) | 5.0x | 6.0x |
| 0.5 | 3.5x | 6.0x |
| 0.25 | 2.25x | 6.0x |

Shipping 0.8 as specified.

### Exp Share: settled 2026-08-24

**Boost, not share.** If slot 1 gets 100 XP then slots 2 to 6 each get 100 XP.
The credit is not divided across the team. The party share rises from 0.8 to 1.0 and the
full-team multiplier goes from 5.0x to 6.0x.

The divide-by-six reading was raised and rejected by the user. It would have made
a 10,000 coin purchase a *downgrade* from the free 5.0x default, which is
incoherent. Recorded because it is the sort of thing that gets re-litigated
later: the item multiplies, it never splits.

Known and accepted: the toggle is therefore strictly beneficial, so it will sit
on permanently once bought. The off position exists for completeness, not as a
tradeoff.

---

## Step 0: back up the save before touching its shape — DONE 2026-08-24

Small, and first for a specific reason: step 1 is the largest change to
`game-state.json` in the project's history, and today the only protection is the
`.unreadable.json` quarantine written on decode failure
(`GameMonitor.swift:213`). That covers corruption. It does not cover a bad
write, a migration bug, or a persist that writes an empty roster over a real
one, which is precisely the failure step 1 could introduce.

- On launch, before `load()` returns, copy `game-state.json` to
  `backups/game-state-<ISO day>.json`. Keep the most recent 10, delete the rest.
- Day-stamped rather than per-launch, so a crash loop cannot evict every good
  copy.
- Tests: a backup appears on launch when a save exists; none is written when
  there is no save; the eleventh launch-day prunes the oldest; a corrupt save is
  still quarantined by the existing path.

Invariant to add: **the save is backed up before it is read, and backups are
pruned by age, not by count of launches.** Shipped as invariant 29.

**As built**, in `Sources/PokeBar/Game/SaveBackup.swift`, called from
`GameMonitor.init` ahead of `load()`. One refinement on the spec above: **the
first capture of a day wins**, so later launches that day copy nothing rather
than overwriting. Overwriting per launch would let a bad write on day X destroy
day X's own good copy, which is the failure this step exists for. Nine tests,
including the eleventh-day prune, the out-of-order-day prune, and a corrupt save
that is both backed up and quarantined.

---

## Step 1: a roster, so levels persist — DONE 2026-08-24

Pure `Trainer` and `GameModels` work. No UI, no team yet. This step alone
delivers "I should not lose my progress on Charizard".

**Model change.** `Trainer.active: Raise?` becomes:

```
var roster: [Raise] = []          // every individual ever raised, levels intact
var team: [UUID] = []             // ordered, max 6, references roster ids
```

`Raise.id` is already a UUID and `MilestoneEvent.raiseID` already points at it,
with a doc comment that explicitly wants two Pikachu to be two individuals. This
step is the shape that comment was written for.

**Identity is `Raise.id`, not `VariantSlot`.** A slot cannot be the key: a
`Raise` mutates its own `entryID` as it evolves (`Trainer.swift:204`), so a
slot-keyed store would have to be rekeyed on every evolution, which is the
"two copies of one fact" smell that `CatchLog.filledSlots` exists to avoid.

**`setActive` splits into two verbs**, because "resume Charizard" and "start a
second Charmander" are different intents and the current single function cannot
express either safely:

- `addToTeam(raiseID:)` resumes an existing individual at its stored level.
- `startRaising(entryID:shiny:gender:)` creates a new `Raise` at level 1 and
  adds it. Still free and ungated.
- `removeFromTeam(raiseID:)` sends one to the PC without deleting it. Nothing deletes a
  `Raise`; the roster is append-only like the two logs.

**Migration, per invariant 23.** This is the risky part.

- Decode `roster` and `team` with `decodeIfPresent` and a default.
- Keep reading the legacy `active` key **forever, never writing it**, the same
  pattern `CatchLog` uses for `graduations`. If `roster` is absent and `active`
  is present, seed the roster with that one `Raise`, XP intact, and make it team
  slot 1.
- Tests: a real pre-roster save decodes with its level preserved and lands in
  slot 1; a save with both keys prefers `roster`; a save with neither yields an
  empty roster rather than throwing.

**Tests for the behaviour itself:** raise to level 40, store it, raise something
else, bring the first one back, assert it is still level 40. That is the whole
feature in one assertion and it should be written first.

**DECISIONS.md:** amend "Switching Pokémon is free, with no level gate" and the
`Raise` doc comment. The reversal and its reason go in the record before the code
changes, per the project rule.

**As built.** Invariants 30 and 31. Three things went differently from the spec
above, all deliberate:

- **A third verb, `switchTo(entryID:)`, and it resumes.** The popover offers one
  "raise this one" button per *entry*, so until step 4 there is no UI that can name
  an individual, and `addToTeam(raiseID:)` alone would have left the headline
  feature unreachable from the app. `switchTo` picks the **highest-level**
  individual of that exact sprite and makes it the whole team, starting a new one
  only when the roster has none. Transitional in one respect only: it clears the
  other slots. Step 4 deletes it in favour of the two verbs.
- **`active` survives as a computed alias for team slot 1**, so `MenuBarLabel`,
  `CompanionView` and `DexView` are untouched. Renaming them belongs with the team
  UI rather than smeared across two steps.
- **`credit` split into `credit` + `grant(xp:to:)`.** Step 2 is now a loop over
  `teamRaises` calling `grant` once per slot: the level-up detection, the evolution
  chain and the milestone recording are already scoped to one `raiseID` and do not
  change. `setEverstone` gained a per-individual overload for the same reason.

Also built: the ownership check happens **before** anything mutates, because a
refused switch that had already emptied the team would silently stop XP accruing;
and the live save is decoded by a `POKEBAR_CORPUS=1` test rather than only by a
fixture. It migrates: Charizard, level 47, 224,081 XP, into slot 1.

---

## Step 2: the team gains XP together — DONE 2026-08-24

**Constants**, in one place so the dial is turnable:

```
XPCurve.leadShare:  Double = 1.0
XPCurve.partyShare: Double = 0.8
```

**`Trainer.credit` distributes** instead of crediting one individual. Slot 1
gets `weightedTokens * leadShare`, slots 2 to 6 get `weightedTokens *
partyShare` each. Per occupied slot, so a team of two is 1.8x and the ramp is
smooth. Every member then runs the existing per-individual pipeline:
level-up detection, `resolveEvolutions` (which already loops), milestone
recording against its own `raiseID`.

**Decisions this forces, all currently implicit in "there is one active":**

- **A capped member's share is not redistributed.** XP that would go to a
  graduated individual is simply not granted. Redistribution would make the lead
  slot silently mean something different once it graduates, and the ceiling
  clamp in `credit` already exists. Surface it in the UI instead: a graduated
  Pokemon in the team is wasting a share and the player should be told, not
  quietly compensated.
- **`GameEvent` needs to say *which* individual.** `evolved(from:to:)`,
  `levelledUp(to:)`, `evolutionChoice(from:options:)` and `graduated(entryID:)`
  all currently assume a single subject. Add the `raiseID`. This ripples into
  `Notifier` and `CompanionView`.
- **Six simultaneous evolution choices are now possible.** One credit can leave
  several members waiting on the player at once. The UI needs a list, not a
  single prompt, and `Notifier` needs to not post six banners for one credit.
  Notification volume was already an explicit design constraint (level-ups are
  excluded at 99 per climb); six members multiply everything by six. Re-check
  the whole notification set against that.
- **Everstone stays per individual.** It already is, and it now works the way
  the doc comment describes without qualification.

**Tests:** total XP granted equals `lead + 5 * party` for a full team; a team of
one behaves exactly as today (regression guard on the whole v1 economy); a
graduated member absorbs nothing and does not push others over the ceiling; two
members can hold distinct pending evolution choices simultaneously; milestones
land against the right `raiseID`.

**DECISIONS.md:** a new section under the game layer, carrying the throughput
table above and the reason the inflation is acceptable (graduation pays out
nothing). Amend "Raising time is the bottleneck" rather than deleting it: it is
still true, just 5x weaker.

**As built.** Invariants 32, 33 and 34. Everything above landed as specified, plus
two things the spec did not name:

- **Rare Candy had to stop going through `credit`.** It called it because in v1
  "credit" and "the active one" were the same thing; with six members that hands
  10,000 XP to all of them for 250 coins, which makes the game's one targeted item
  a permanent 5x team boost. It now calls `grant` against one `raiseID`, and
  `useRareCandy(on:)` is what step 4's picker will call. Invariant 33.
- **Notification grouping is a real behaviour, not just a cap.**
  `Notifier.announcements(for:dex:)` collapses same-kind alerts from one credit
  into one banner that names them all ("3 Pokemon evolved" / "Metapod, Kakuna and
  Ivysaur, all at once."), per kind and never across kinds. A batch of one reads
  exactly as before. Invariant 34.

Also added rather than deferred: `pendingEvolutions(of:)`,
`teamPendingEvolutions(dex:)` and `evolve(_:into:)`, so two members can hold two
unrelated pending choices and either can be settled without touching the other.
There is a test for exactly that. Step 4 renders it.

**Not visible in the app yet**, and that is expected: nothing the popover offers
can build a team of more than one, because `switchTo` clears the other slots and
hatching only starts a raise when the team is empty. Step 4 is what makes step 2
observable outside the tests.

---

## Step 3: the Exp Share — DONE 2026-08-24

Settled: boost, per the section above.

- `Prices.expShare = 10_000`, and a `Trainer.hasExpShare` flag alongside
  `hasShinyCharm`, plus `expShareEnabled` for the toggle.
- **10,000 rather than 5,000.** It is passive and permanent, which is the class
  the Shiny Charm is priced in at 30,000. At 5,000 it is ~4.6 days of accrual
  for a permanent +20% team XP, which is bought on sight and never thought about
  again. At 10,000 it is ~9 days, and it competes with 33 eggs. A third of the
  charm reads correctly against it.
- Purchase is one-time like the charm; the toggle is free and reversible.
- Tests: the multiplier changes from 5.0x to 6.0x when enabled; the toggle is
  inert until purchased; buying twice throws `alreadyOwned`; an old save decodes
  with both flags false.

**As built**, all four of those tests plus three more: every member earns an
identical figure with it on, both flags round trip through a save, and off means
0.8 rather than nothing. Two calls the spec did not name:

- **Buying turns it on.** A 10,000 coin purchase that visibly does nothing until a
  second control is found reads as a bug. The toggle is for turning it off, which
  nothing sensible will do.
- **It is not listed in `ShopView` yet**, on purpose. It only affects party slots
  and nothing in the popover can build a team, so the row would sell an item that
  does nothing observable. That row is part of this step's UI, which is step 4.

---

## Step 4: the UI for steps 1 to 3 — DONE 2026-08-24

Views hold no logic, so everything here routes through `GameFormat`. Tests go
there, not in view bodies.

- **`CompanionView` becomes a team view.** Six slots, ordered, with the lead
  slot distinguished. Drag or explicit controls to reorder, since slot 1 is now
  a meaningful choice.
- **PC list.** Every individual ever raised, with its stored level,
  so "bring Charizard back" is one click. This is the screen step 1 exists for.
- **`MenuBarLabel` follows slot 1.** One-line change to what it reads. Do not
  touch the sizing: 20pt height and the 33pt cap are settled and approved.
- **Rare Candy needs a target.** It currently applies to "the active one";
  with six it needs an explicit choice.
- **Everstone toggle moves per team member.**
- **`FloatingPetPanel` follows slot 1**, matching the menu bar.
- Copy rule: no em dashes in anything rendered.

**As built.** All seven of those, plus the Exp Share shop row that step 3 held
back. Six calls the spec left open, all recorded in DECISIONS.md under "the team
on screen":

- **The card is the selected member and the rows are the rest**, with the selected
  member's row skipped. Six cards do not fit in 312pt, and the useful side effect
  is that a team of one renders exactly what it rendered before v2.
- **Selection is the target for all three aimed things**: Rare Candy, Everstone,
  promote. Three controls per row was the alternative.
- **Promote, not drag.** Slots 2 to 6 take the same share, so their order is
  cosmetic and "Make lead" covers every reorder that changes anything. A drag list
  in a 340pt popover is also untestable.
- **The Dex button labels itself** through `Trainer.raiseAction`: "Resume at level
  47" or "Raise a new one". Two very different outcomes behind one unlabelled click
  is how a stray press leaves a junk level 1 duplicate in the roster.
- **The PC list is best first and capped at six rows**, with a count of what is
  hidden. It grows without limit because nothing is ever deleted.
- **The scroll area is measured and clamped** (140 to 250) rather than pinned like
  the Dex and Shop panes, because this one is a single card on a fresh install and
  six slots plus a PC of twenty later.

Deleted, as promised: `Trainer.switchTo`, `evolveActive`, `Trainer.active`, and the
lead-only `useRareCandy` and `setEverstone` overloads. Every verb names its
individual now.

### The feedback round, same day

The user played it cold and found six things. All fixed, all recorded in
DECISIONS.md under "the feedback round":

1. **A hatch needs fanfare.** It announced itself as one grey feed line under the
   button that bought it. Now `CelebrationCard`, over the whole popover.
2. **"Raise a new one" read as conjuring one.** Replaced by "Add to team", which
   only ever offers individuals that exist, named with their variant and level.
3. **It appeared on Charmander and Charmeleon**, whose individuals had become the
   player's Charizard. New individuals must now be *hatched*, at a price, and only
   at the bottom of a line.
4. **Hatch another, priced in both currencies**: 3,000 coins flat, or half a
   targeted pick in Dust. Flat against banded, so Dust is the cheap path for a
   common and coins for a legendary. Self-limiting, because the team caps at 6.
5. **The team display was lame.** Six uniform cards, 2 x 3, drag to swap.
6. **The silver ring read as selection.** It is a halo now.

Plus the thing all of that exposed: **an acquisition now fills an empty slot**,
which is what the user expected when they hatched an egg into a team of one.

**Awaiting the user's eyes** on the rebuilt pane. Rendered pixels can only be
confirmed by asking.

---

## Step 5: docs — DONE 2026-08-24, alongside each step

CLAUDE.md invariants, the architecture block, the game-layer figures table, and
the state section. New invariants earned by steps 0 to 3: the backup-before-read
rule, roster identity being `Raise.id`, the legacy `active` key being read and
never written, and a capped member's share not being redistributed.

---

## Step 6: per-project attribution, display-toggleable

Deferred behind the team, at the user's direction, but the design holds from the
brainstorm.

- `~/.claude/projects/` has 17 encoded directories here, carrying real names
  (`-Users-apersad-Documents-Development-Deloitte-Projects-...`). The scanner
  walks those paths and discards the project before building a `UsageEntry`.
  Add the field; decode the path.
- **Codex has no project in its path.** `~/.codex/sessions` is partitioned by
  date (`2026/...`), so its project has to come from the `cwd` on the session
  meta line. Until that is parsed, bucket Codex usage as unknown rather than
  guessing.
- `credit` takes a per-project breakdown of weighted tokens, and a `Raise`
  accumulates `xpByProject: [String: Double]`. New persisted field, so
  `decodeIfPresent` and a default.
- **Recording is always on; only display is toggled.** The user wants to hide
  this sometimes, not to stop collecting it. A toggle that gates *recording*
  leaves permanent holes that can never be backfilled, because the ledger
  credits each turn exactly once and cursors do not rewind.
- The toggle is a display preference, so it lives in `UserDefaults`, **not** in
  `game-state.json`. Nothing that can be re-derived belongs in the file that
  cannot.
- Tests: a known encoded path decodes to the right project; an unparseable path
  buckets as unknown rather than crashing; XP attribution across two projects
  sums to the total credited.

---

## Step 7: LaunchAgent and login item

Independent of everything above, low risk, last because nothing depends on it.
Currently deferred-not-rejected in DECISIONS.md. Nothing is lost when the app is
off (cursors back-credit on next launch), so this is quality of life: it makes
the passive notification set actually fire when the events happen instead of in
a batch at launch. Ad-hoc signing is still enough.

---

## Explicitly not in v2

Deferred by the user in this session, with reasons:

- **Widgets.** Deferred.
- **Battles.** Deferred, and named: it risks losing the plot of a token-usage
  project. Would also require reopening "stats are out", which is what Mint's
  rejection hangs off.
- **Types in the manifest.** Was only proposed as a battle prerequisite.
- Still rejected, not deferred, and not to be reopened: live plan limits and any
  Keychain access, Mint, cost-weighted currency, the Dust prices (deferred on
  purpose until the wall is hit), and the menu bar sprite sizing.

## Carried over, unchanged

- Look at the Dex when the active Pokemon crosses level 50 and confirm the
  silver ring reads against the dark grid. Still the one unverified thing in the
  build, and rendered pixels here can only be confirmed by asking the user.
  Step 2 makes this easier to reach, not harder.
- Re-check `gpt-5.6-sol`'s rate around 2026-11-21.
