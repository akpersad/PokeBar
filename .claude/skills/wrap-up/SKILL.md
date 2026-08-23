---
name: wrap-up
description: End-of-session close-out for PokeBar. Reports what is pending on the user's plate, brings CLAUDE.md / DECISIONS.md / README.md back in line with what the code actually does, and verifies the repo is safe to /clear and resume cold. Use when the user says they are wrapping up, stopping for now, about to clear context, or asks "are we good to stop".
---

# Wrap up a PokeBar session

Three steps, in this order. Do all three. Report each one separately, and do not
merge them into a single summary.

This is a close-out, not a work session. Do not start new features, refactors, or
"while I'm here" cleanups. The one exception is step 2: documentation drift is
in scope by definition.

---

## Step 1: What is pending on the user

Report only things that genuinely require the user. Sort into two lists,
**blocking** and **optional**, and say plainly if a list is empty. Never pad this.
"Nothing is pending from you" is a good answer when it is true, and inventing work
to look thorough is the failure mode here.

Something belongs on their plate only if it is one of:

- A **decision of taste or balance** that code cannot settle. Phase 4 economy
  questions live here: what coins buy, what an egg costs, whether upstream's
  desktop pet / notifications / shop survive.
- A **judgment on risk** that is theirs to make, not yours.
- An **action only they can take**: approving a system prompt, an interactive
  login, looking at rendered UI and reacting to it, rotating a credential.
- A **question you asked earlier in this session that they never answered.**
  Re-read the conversation for these rather than trusting memory. Do not re-ask
  something they already declined or moved past; a question they walked away from
  is an answer.

Sources to check, every time:

- `CLAUDE.md`, section "Open questions for the user"
- `DECISIONS.md`, section "Deferred, not rejected"
- Anything the current session surfaced and left hanging

For each item give one line of what it blocks. If a pending item blocks the next
phase, say so; if it blocks nothing, say that too, because the user's next
question will be "does this stop me".

---

## Step 2: Update the documentation

This repo's rule is that `DECISIONS.md` leads and code follows. At close-out that
inverts: find where the code has drifted ahead of the docs and fix the docs.

Check each of these against reality, not against what you remember writing:

**`DECISIONS.md`**
- Every directional call made this session has an entry with the evidence or
  measurement behind it. A decision made in code but never written down is the
  main thing this step exists to catch.
- A call that was **rejected** says rejected, not deferred, and says why. Those
  are different promises to a future reader.
- Something learned the hard way keeps the finding, not just the conclusion.

**`CLAUDE.md`**
- The architecture map matches `find Sources -name '*.swift'`.
- The "State" section names the true current phase and the real next action.
- The test count matches what `./scripts/check.sh` just printed.
- Invariants: if this session added a load-bearing rule that is silent when
  broken, it belongs in the invariants list with the measurement.
- Reference figures are still labelled as measured on a date, not as current
  truth. They grow with use; the properties matter, the digits do not.

**`README.md`**
- Status checkboxes and the phase line match `CLAUDE.md`.
- The Privacy section describes what the app *actually* touches. This one has
  been wrong before, claiming a network call and a credential the app does not
  use. Verify it against the code, not against intent.

**UI copy**, since the project bans em dashes in anything a user reads:

```bash
grep -rn '—' Sources/PokeBar/UI Sources/PokeBar/App | grep -v '^\s*//'
```

Comments are exempt. A hit inside a string literal is a bug.

State explicitly which files you changed and which you checked and found already
correct. "Checked, no drift" is a real result worth reporting.

---

## Step 3: Safe to clear context

Run the real checks. Paste actual output, never a claim.

```bash
./scripts/check.sh                       # build + tests must pass
git status --short --branch              # clean tree, in sync with origin/main
git log --oneline -5
ls dist/PokeBar.app >/dev/null 2>&1 && pgrep -f PokeBar.app >/dev/null && echo "app running from bundle"
```

Then confirm each of these, and name any that fail:

1. **Tests pass and the build is clean.** If anything fails, say so with the
   output. A failing check is a blocker, not a footnote.
2. **Working tree is clean and pushed.** Standing permission is push directly to
   `main` for this project. Uncommitted work at close-out is the one thing that
   does not survive a `/clear`, so commit it or say why you did not.
3. **No scratch left behind.** Temporary test files, throwaway scripts, stray
   `/tmp` artifacts, debug processes. A scratch file that reaches `main` is worse
   than one that never existed.
4. **A cold session can resume.** The test: could someone who reads only
   `CLAUDE.md` and `DECISIONS.md`, with none of this conversation, take the next
   step without guessing? If not, fix `CLAUDE.md` until they can. That file is
   the handoff, and this is the last chance to write it while the context is
   still in your head.
5. **The next action is stated in one sentence**, in `CLAUDE.md` and in your
   reply.

Finish with an explicit verdict: **safe to clear**, or **not safe**, followed by
exactly what is blocking. Do not soften a "not safe" into a list of caveats.
