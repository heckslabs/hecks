---
name: hecks_qa
description: Run one adversarial QA sweep against hecks — claim a chapter through the QualityControl ledger, run the existing Ruby/Rust fuzz harnesses against it, log any divergence as a Bug with a failing test, fix it if self-contained (draft PR), release the chapter. Invoke directly for one sweep, or via `/loop hecks_qa` for continuous operation. Use when asked to hunt for hecks Ruby/Rust parity bugs, "run a QA sweep", or "run the hecks QA loop".
---

# `hecks_qa` — one sweep, dispatched to keep this session's context flat

**This skill does not itself loop.** "hecks_qa" (not "qa-loop") on purpose —
it runs exactly one claim→sweep→release cycle. For continuous operation,
the *caller* wraps it: `/loop hecks_qa` re-invokes this skill on its own
schedule. Either way, follow the orchestrator step below first — don't
run the sweep steps directly in this conversation.

## Orchestrator step — read this before doing anything else

**Do not run "Running one sweep" (below) inline in this session.**
Dispatch it to a subagent instead, and only relay its final report here.
The reason: getting `qa/bluebook/quality_control.bluebook` working at
all took one session past 550k tokens of investigative debugging (PR
#516) — none of that needs to repeat, but *any* sweep's own output and
back-and-forth still would, every single time, if run inline. Under
`/loop hecks_qa` that's every wakeup, indefinitely. A subagent's internal
transcript never reaches this session — only its final report does — so
this session's own context stays flat regardless of how many sweeps ever
run.

**The one thing that must NOT be fresh per sweep: the worktree.**
`qa/data/*.heki` (the ledger's own persisted state — Target claims, Bug
history, Sweep records) is real filesystem state, untracked by git, that
lives inside whatever checkout the sweep runs from. A generic
`isolation: "worktree"` subagent call gets a **brand-new** worktree each
time — which means a brand-new, EMPTY `qa/data/`, and the ledger would
silently forget every claim and every bug between sweeps. Don't do that.

*(Once `qa/bluebook/quality_control.hecksagon` is actually bound to
`PostgresEra` AND `bin/qa_postgres_migrate` has actually been run against
the real `qa/data/*.heki` files — see that script's own header — this
specific reason goes away: a real Postgres database is shared state, not
worktree-local, so a brand-new worktree sees the exact same ledger a
persistent one would. This note is written from the OLD, still-Heki-bound
side of that migration; don't delete the persistent-worktree convention
above on the strength of this note alone until the real migration has
actually run — check `qa/bluebook/quality_control.hecksagon` itself for
which adapter it currently names.)*

Instead:

1. **One time, not per sweep**: make sure a dedicated, persistent
   worktree exists — e.g. `.claude/worktrees/hecks-qa-runner`. Create it
   once (`EnterWorktree` with a fixed `name`, or `git worktree add`
   directly) and never tear it down between sweeps. This is where
   `qa/data/` actually lives, permanently.
2. **Every tick — MANDATORY, NO EXCEPTIONS, before any fresh sweep
   starts**: `bin/qa_pr_check` runs, inside the SAME subagent dispatch
   described below, in the SAME persistent worktree. This is not left to
   an agent's own judgment to remember any more than bug-logging is (see
   that rule's own wording below) — a loop that keeps finding new bugs
   but never notices one of its own already-opened PRs went red on CI is
   exactly the gap this whole mechanism exists to close, and "the agent
   forgot to check" is not an acceptable reason for it to reopen. Put the
   instruction to run it FIRST in the subagent's own prompt, ahead of
   `bin/qa_sweep --all` — see "Checking on open PRs" below for its own
   exit-code contract and what happens on exit 2.
3. **Sweep the WHOLE rotation, mechanically, in one shot** (after the PR
   check above, same subagent, same dispatch): `bin/qa_sweep --all` (see
   that script's own top-of-file comment for the full design — one real
   `Process.spawn` OS process per currently-waiting `Target`, genuinely
   concurrent, each running the exact single-target path `bin/qa_sweep
   <target>` always has) replaces what used to be N subagents fanned out
   by THIS session, one per waiting chapter, each babysitting its own
   sweep. That fan-out cost real wall-clock and real token spend to
   orchestrate a step that has NO judgment in it on the clean path — a
   loop dispatching a subagent to run a script that itself only ever
   dispatches five inner CLI calls. `--all` collapses that: the
   concurrency now happens as real OS processes, not LLM-level fan-out,
   and the ONLY case still worth a subagent is a genuine finding — see
   step 4. The subagent's prompt is:
   - the exact working directory to `cd` into (the persistent worktree
     from step 1, as an absolute path),
   - an instruction to `git fetch && git rebase origin/main` first, so
     it starts from current main (matters both because `bin/qa_sweep`
     itself may have changed, and because a prior sweep may have opened
     a PR that's since merged),
   - "Checking on open PRs" below, verbatim, run BEFORE `bin/qa_sweep
     --all` — if it exits 2, its own judgment section is followed to a
     fix (or a left-open Bug) BEFORE sweeping,
   - `bundle exec ruby bin/qa_sweep --all` (widen `--seeds` the same way
     a single sweep already would), then an instruction to relay its
     ENTIRE printed consolidated report back VERBATIM — nothing
     summarized away, nothing acted on. This subagent's own job stops
     there: it makes NO judgment call of its own, the exact same
     discipline `bin/qa_sweep` itself already holds to on a single
     target's own surprise. Its own exit code is read here only to know
     what kind of report came back — see that script's own header for
     the contract: `0` (every currently-waiting target came back clean,
     or nothing was waiting — either way a complete, unremarkable tick),
     `1` (at least one target hit an operational error and NONE found
     anything — the ledger wouldn't boot, a claim was already held and
     not stale, a named path doesn't exist, the same causes a single
     sweep's own exit 1 always meant, just now possibly several at
     once), `2` (at least one target found something — a genuine
     finding always outranks an operational error sitting alongside it
     in the same report, see the script's own comment on that
     precedence),
   - an instruction to leave the worktree clean (on `main`, no
     uncommitted changes, no lingering branch checked out) before
     finishing — so the *next* tick, in the same worktree, starts from
     a known-good state.
4. Wait for the subagent's report, then read its ONE consolidated
   `bin/qa_sweep --all` report yourself — this judgment stays here, in
   the orchestrating session, deliberately kept OUT of the mechanical
   subagent dispatched in step 3 above:
   - **Exit 0 — nothing to act on.** Relay the short summary and move
     on; there is no per-target follow-up to dispatch.
   - **Exit 1, nothing found.** Read the real error message(s) yourself
     — fix the actual problem or report it, same as a single sweep's
     own exit 1 always meant. Still nothing to dispatch per target.
   - **Exit 2 — one or more targets found something.** The consolidated
     report's own "FOUND SOMETHING" section already lists every one of
     them, each with its OWN full structured report — chapter, seed,
     reproduction steps, subject/expectation/observation, the
     divergence detail. For EACH one, dispatch ONE FRESH subagent,
     carrying that target's own slice of the report VERBATIM (copied
     out of what you already have — never re-derived, never re-run) and
     "On a surprising check" below, verbatim. This is the only place a
     subagent still gets dispatched per target, and only when a real
     finding earns it — a target that came back clean in the same
     `--all` run needs nothing further this tick. Multiple findings in
     one tick mean multiple such subagents, dispatched independently;
     one target's own fix or open Bug never waits on another's.

   **If a per-target subagent's report says a draft PR was opened,
   record it in the ledger before moving on — this is YOUR job, not the
   subagent's.** `QualityControl::Patch` (`qa/bluebook/quality_control
   .bluebook`, "── which pull requests are ours ──") is what
   `bin/qa_pr_check` now reads *instead of* `gh pr list --search` — a PR
   this aggregate does not know about is invisible to it, the same way
   #534 was once invisible to the old branch/title search. The
   subagent's own report already carries everything `Patch.Open` needs
   — its number, url, branch, head commit and title are `gh pr create`'s
   own return value, read straight back by the subagent right after
   opening (`gh pr view --json number,url,headRefName,headRefOid,title`)
   and put in its report verbatim, not re-derived by you. Dispatch,
   against the persistent worktree's own ledger:
   ```
   bundle exec ruby bin/run qa/bluebook patch.open bug=<bug-reference> \
     number.value=<n> url.value="<url>" branch.value="<branch>" \
     commit.value=<head-commit-sha> title.value="<title>"
   ```
   Recording it is *this* action, deliberately kept out of "On a
   surprising check" below — that section is the per-target subagent's
   own prompt, and a fact this durable only becomes true once `gh pr
   create` has actually returned, which is exactly the moment a report
   reaches you, not a moment a subagent's own dispatch can be trusted to
   land twice for free if a report is ever retried.

   **If the report says a draft PR was opened for something that is NOT
   a bug fix — infra/domain-modeling work with no `Bug` behind it —
   record it in the ledger the same way, before moving on, via
   `QualityControl::Improvement` instead.** `Improvement`
   (`qa/bluebook/quality_control.bluebook`, "── deliberate work, landed
   ──") is `Patch`'s own sibling for exactly this: a real PR — a backlog
   aggregate, a compaction tool, a driving adapter — that proves nothing
   was wrong, so it names no `Bug`. `bin/qa_pr_check` reads its own
   `Improvement.Open` worklist the identical way it reads `Patch.Open`.
   The subagent's report carries the same five `gh pr create` facts
   (number, url, branch, head commit, title), plus — only when this PR
   grew out of a row in `Angle.Backlog` — that angle's own reference.
   Dispatch, against the persistent worktree's own ledger:
   ```
   bundle exec ruby bin/run qa/bluebook improvement.open \
     number.value=<n> url.value="<url>" branch.value="<branch>" title.value="<title>"
   ```
   or, citing the angle it fulfills:
   ```
   bundle exec ruby bin/run qa/bluebook improvement.open angle=<angle-reference> \
     number.value=<n> url.value="<url>" branch.value="<branch>" title.value="<title>"
   ```
   Once landed, record the commit (this is what starts `ImprovementCiWatch`'s
   own watch — see "Checking on open PRs" below):
   ```
   bundle exec ruby bin/run qa/bluebook improvement.land id=<n> \
     number.value=<n> commit.value=<head-commit-sha>
   ```
5. If invoked via `/loop hecks_qa`: **dispatch the next tick's mechanical
   subagent (step 3) immediately** once every subagent THIS tick started
   — the mechanical one, and any per-target follow-ups step 4 dispatched
   — has reported back; the loop's job is to keep the practice alive,
   not to pace it. `QualityControlDials::CADENCE_SECONDS` (top of
   `qa/bluebook/quality_control.bluebook`) is read as a floor, not a
   target: `0` (the default) means start the next tick the moment this
   one concludes, with no artificial wait in between. Use
   `ScheduleWakeup` only as a **liveness fallback** — in case a subagent
   hangs and its task-notification never arrives — not as the
   tick-pacing mechanism; a long fallback (the loop skill's own
   1200–1800s guidance) is appropriate precisely because it should
   almost never be the thing that fires. If invoked directly (one-off),
   you're done — report the outcome (PR check AND the consolidated
   sweep, plus any per-target follow-up) and stop.

## Checking on open PRs

*(This is part of the subagent's own prompt too, run BEFORE `bin/qa_sweep
--all` — see the orchestrator step above.)*

A draft PR this loop opened is a fix judged self-contained and verified
LOCALLY — which is not the same fact as "CI's own fresh build still
agrees", and nothing used to check whether those two ever drifted apart.
`bin/qa_pr_check` is that check, and it asks by reading the ledger, not
by searching GitHub for us: `QualityControl::Patch.Open`
(`quality_control.bluebook`, "── which pull requests are ours ──") is
every PR this practice has recorded opening and not yet seen merged or
closed — recorded once, at the moment it was opened (see the
orchestrator step's own new instruction above), never rediscovered by a
branch-prefix or title guess. `gh pr list --search "head:loop-parity"`
used to be how this script found its own PRs, and it was never reliable:
checked against this practice's own real history, #533/#532/#529/#526
are real PRs on `loop-parity/*` branches titled `"heki: ..."`/
`"BUG#N: ..."`/`"rust: ..."` rather than `"qa: ..."`, invisible to a
title search; #534 was titled `"qa: ..."` on a branch that never got the
`loop-parity/` prefix, invisible to a branch search — and a draft PR sits
outside a plain `gh pr list` on top of either gap. It sat open and
genuinely red for a day before anything noticed. There is no `--search`
left in this script at all: for each row in `Patch.Open` **and**
`Improvement.Open` — `QualityControl::Improvement`'s own worklist for a
deliberate, non-bugfix PR, checked exactly the same way (see the
orchestrator step's own new bullet above on when a draft PR goes here
instead of `Patch`) — it asks `gh` about that PR's own number directly —
`gh pr view <n>` first (is it still open at all, and what commit is its
head at right now), then, once its checks have settled (not pending),
the ledger's own `Clearance.CI.Run` — the `CI` port
`quality_control.hecksagon` declares, bound for real to `GithubChecks`
(`qa/adapters/github_checks.rb`), which is what actually shells to `gh`
from there, by commit. `ClearOnPass`/`RefuseOnFail`
(`quality_control.bluebook`'s own foot) turn its answer or refusal into a
real `QualityControl::Clearance` — which is what lets `BugCiWatch`/
`ImprovementCiWatch` (the two process managers in the same bluebook, read
their own comments there) notice a red run on its own and put the
record back (`Bug.Regress`/`Improvement.Regress`) without anyone
watching for it by hand. The script itself never decides pass or fail any
more, and it never decides which PRs are ours either — it only decides,
among the PRs the ledger already says are ours, which commit is worth
asking about.

```
bundle exec ruby bin/qa_pr_check
```

- **Exit 0 — nothing to act on.** Both `Patch.Open` and `Improvement.Open`
  are empty, or every row across either is already merged/closed (retired
  this run), already has a recorded `Clearance`, or is still running.
  Relay the script's own printed summary and move on to the sweep below.
- **Exit 1 — an operational error.** `gh` was not reachable, a tracked
  PR's own head commit does not look like a sha, or the ledger would not
  boot. Read the message; fix the actual problem (or report it) rather
  than retrying blind — same as a sweep's own exit 1.
- **Exit 2 — FOUND A NEWLY-RED PR.** The ledger itself already recorded
  `Clearance.Failed` for the commit (via the `CI` port, not a direct
  dispatch — see this section's own opening paragraph). For a `Patch`
  row, that means `BugCiWatch` already fired `Bug.Regress` — the bug is
  back in `investigating`, on the record, before this loop does anything
  else. **Follow "On a surprising check", below, now**, against the
  re-opened Bug instead of a freshly-logged one, before moving on to a
  fresh sweep target. The one difference: `Log` was already satisfied
  when this bug was first found — don't re-log it; `investigate`/`fix`/
  `verify` through the SAME Bug record, and (if self-contained) open a
  fresh `loop-parity/*` PR the ordinary way, subject to the same daily
  cap as any other.

  For an `Improvement` row, `ImprovementCiWatch` already fired
  `Improvement.Regress` — the record is in `needs_fix`, on the record.
  There is no Bug-shaped judgment to follow here: fix whatever broke and
  dispatch a fresh `improvement.land id=<n> number.value=<n>
  commit.value=<new-sha>` (see the orchestrator step's own bullet above)
  — the same event `ImprovementCiWatch` started on, so the watch picks
  the new commit back up on its own.

## Running one sweep

*(This is the subagent's own prompt. The ledger is
`qa/bluebook/quality_control.bluebook` — read its own header comment
first if you haven't: the whole practice in three rules — a CHECK
compares an expectation against an answer, a BUG is logged with the
failing test that proves it or it isn't logged, everything else is a
GATE, refused, waivable only by a human, never by this loop.)*

Everything mechanical — booting the ledger, picking a chapter off
`Rotation` (seeding `pizzas`/`banking` the first time ever, if nothing
has been `Identify`d yet), claiming it, opening a sweep, running the
existing fuzz infrastructure in-process (`Hecks::Fuzzing::
SequenceGenerator` + `Replay`, differentially against a compiled Rust
conformance binary when one exists for this chapter, Ruby-only property/
exception fuzzing otherwise — see `qa/stress_domains/ledger_ordering/
NOTES.md` for why not every domain has one), logging a `Check` per seed
with the expectation written first, and concluding/releasing on a clean
run — is `bin/qa_sweep`'s own job now, not yours. Run it:

```
bundle exec ruby bin/qa_sweep [target-reference] [--seeds N]
```

- **No target-reference**: the least-recently-swept waiting chapter.
  `--seeds` defaults to 10 seeded sequences of 25 steps each; widen it
  for a deeper pass (`--seeds 40`, matching `SEEDS=40` — the same
  convention `spec/rust_conformance_fuzz_spec.rb` already uses locally).
- **Sweeps are adversarial by default.** A fraction of every generated
  sequence's command steps (`QualityControlDials::ADVERSARIAL_FRACTION`,
  top of `qa/bluebook/quality_control.bluebook`) is deliberately mutated
  into the argument shapes BUG#7–#16 were found through — an undeclared
  `to:`/`with:`/`id:`, a blank creating identity, a single-field value
  object as bare `null`/`{}`, a duplicate entity identity, a mapped
  argument left out, unknown+mismatched+absent in one step, entity
  commands two hops deep (`lib/hecks/fuzzing/sequence_generator/
  adversary.rb`). `--adversarial 0` turns it off; `--adversarial 0.5`
  turns it up for one run. Same seed, same fraction, same sequence — the
  report's `reproduce:` line carries the fraction, and each mutated step
  is listed with what was done to it and which bug class that exercises.
- **Exit 0 — clean.** Every generated sequence held; the sweep is
  concluded and the target released. You're done — relay the script's
  own printed summary, nothing else needed.
- **Exit 1 — an operational error.** The ledger wouldn't boot, the named
  target doesn't exist, it's already held by somebody else and the claim
  hasn't gone stale, `--seeds` wasn't a positive integer, and so on.
  Nothing here is QA work — read the message; fix the actual problem (or
  report it) rather than retrying blind.
- **Exit 2 — FOUND SOMETHING.** The script stopped at the first
  surprising check and printed a structured report to stdout: the
  chapter, the exact seed and step count to reproduce
  (`Hecks::Fuzzing::SequenceGenerator.generate(domain, seed:, steps:)`),
  the check's own subject/expectation/observation, and either the
  field-by-field Ruby-vs-Rust divergence or the property violation/crash
  message. It deliberately left the sweep OPEN and the target HELD —
  `bin/qa_sweep` never logs a `Bug`, never concludes, never releases on
  a surprise. That judgment is yours from here, and it is the ONLY
  judgment left in this skill.

### On a surprising check — a genuine divergence or crash

**Mandatory, no exceptions**: log the Bug with the failing test that
reproduces it, or don't log it at all.

```
bundle exec ruby bin/run qa/bluebook log sweep=<sweep-id> reference=BUG#<n> sequence.value=<n> \
  title.value="<one line>" demonstration.value="<exact command/spec that fails>" \
  symptom.value="<what actually happened>" expectation.value="<what should have>" \
  submitter.value="<your name>"
```

Then decide, honestly:

- **Self-contained** (a missing guard, an off-by-one, a validation gap —
  no semantic/architectural judgment call): fix it, verify the new
  regression test goes green, open a **draft PR** — **from this
  persistent worktree, on a fresh branch, then return to `main` before
  finishing** (see the orchestrator step's own cleanup instruction).
  - Branch: `loop-parity/<slug>`.
  - Commit identity: this repo's own `Miette <miette@embryonaut.ai>` —
    already the local git config, don't override it.
  - **Never auto-merge.** Draft, always, regardless of CI status — green
    CI is necessary, not sufficient, for something that ran unattended.
  - **Report the PR's own number, url, branch and head commit back —
    don't record it in the ledger yourself.** Right after `gh pr create`,
    run `gh pr view --json number,url,headRefName,headRefOid,title` and
    put those five values (plus the Bug's own reference) verbatim in your
    final report. `QualityControl::Patch.Open` (`quality_control
    .bluebook`, "── which pull requests are ours ──") is what
    `bin/qa_pr_check` now reads instead of searching GitHub for PRs that
    might be ours, and recording a PR into it is the orchestrator's own
    job, done once your report comes back — see the orchestrator step's
    own instruction above. Don't dispatch `patch.open` from in here.
  - **The cap is `QualityControlDials::PR_CAP_PER_DAY`** — read it at the
    top of `qa/bluebook/quality_control.bluebook`, not a number in this
    sentence (see that file's own comment on why it lives there and not
    here). `0` means uncapped. Only if it's a positive number: check
    today's already-opened `loop-parity/*` PRs (`gh pr list --search
    "head:loop-parity" --search "created:>=$(date +%Y-%m-%d)"`) before
    opening one more than the cap allows — stop and leave the rest as
    open Bugs instead.
  - Mark the Bug's own lifecycle through as work happens: `investigate`,
    `fix commit.value=<sha>`, `verify verification.value="<what was
    run>"`.
- **Bigger** (touches semantics, needs real judgment): leave the `Bug`
  open and unclaimed. **No GitHub issue** — the ledger's own `Bug`
  record IS the tracker. `Ticket`/`IssueTracker` stays dormant; don't
  wire it.
- **Never waive it yourself.** You may note "this looks waivable, here's
  why" in the Bug's own notes/reason field — only a human actually calls
  `bug.waive`/`sweep.waive`.

The sweep stays open and the target stays held either way — on purpose,
the same way `bin/qa_sweep` left them: a chapter with an unresolved
surprising check drops out of `Rotation` until a person (or a later,
deliberate `bin/run qa/bluebook conclude`/`release`) decides it's ready
to be swept again, rather than being re-fuzzed in a known-broken state
on the next wakeup.

---

## Authoring a new stress domain (occasional, not every sweep)

Once `pizzas`/`banking` have had real passes, "being clever" means
authoring a **new domain shape**, not just varying sequences against the
same two. The existing fuzz-bridge only does the latter.

**Check `Angle.Backlog` first — before inventing an angle from scratch.**
`QualityControl::Angle` (`qa/bluebook/quality_control.bluebook`, "── where
to look next ──") is the practice's own durable memory of investigation
directions a past session already identified and cited, so this step
doesn't repeat from zero every time an agent gets here:

```
bundle exec ruby bin/run qa/bluebook ask backlog
```

(`bin/qa_seed_angles` bootstraps it once, the same way `bin/qa_sweep`'s
own `seed_default_targets!` bootstraps `pizzas`/`banking` — idempotent,
safe to run again.) Each row already names what it cites — a Bug
reference, an ADR, a construct-combination gap — so read `Angle.Resolved`
too before starting: an entry already `built` or `discarded` says what
came of chasing it, which is exactly the history that keeps a second
session from re-proposing the same thing a first already settled one way
or the other.

- Live under `qa/stress_domains/`, never `examples/` — clearly
  synthetic, never mistaken for a usage sample. Use the
  `<name>/bluebook/<name>.bluebook` nested shape (see
  `qa/stress_domains/ledger_ordering/`) — a flat `<name>.bluebook`
  breaks `bin/project_rust`'s own naming convention.
- Bias hard toward RE-TRIGGERING, in a new context, a class of bug
  hecks has already found — cite the specific memory/ADR/PR you're
  aiming at. Highest hit-rate; broader/untargeted generation only once
  that vein's exhausted. An open row in `Angle.Backlog` is very often
  exactly this citation, already written down.
- **Discard it** unless it exercises a DSL construct-combination the
  current `Target` set doesn't already cover — check what
  pizzas/banking (and the stress domains already in
  `qa/stress_domains/`) already use before keeping a new one. An
  ever-growing corpus with no new signal is pure CI-time cost.
- A domain that survives becomes a real `Target` (`identify`) and
  enters the same rotation as any other chapter — no special-casing.
  `bin/qa_sweep` picks up whichever mode fits it automatically: Ruby-only
  until (and unless) `bin/project_rust` ever gives it a compiled Rust
  binary too, differentially against that binary from then on — nothing
  about the sweep itself needs to know which.
- **Close the loop on the angle that led here.** If the domain grew out
  of a row in `Angle.Backlog`, mark it: `angle.investigate` when you pick
  it up, then `build resolution.value="<what actually got built>"` (the
  `Target` reference, the PR, the domain's own path) once it lands, or
  `discard reason.value="<why not>"` if it turns out not to hold up.
  **If the domain came from a genuinely new angle nobody had written down
  yet — not from `Angle.Backlog` — propose it before or alongside the
  domain itself**: `propose premise.value="…" citation.value="…"
  proposer.value="…"`, citing the specific memory/ADR/PR/construct-gap the
  same way the bullet above already asks the domain itself to. This is
  the actual mechanism that lets the practice mine its own history
  instead of an agent reinventing judgment every session — it only works
  if a genuinely new angle gets written down here, not just chased
  straight into a domain and forgotten the moment the PR merges.

## What this will never do

- File a GitHub issue on your behalf (`Ticket` stays dormant).
- Merge its own draft PR.
- Waive its own finding.
- Touch a branch with recent activity, or skip claiming before working
  a chapter — the collision guardrails `bin/qa_sweep` enforces aren't
  optional.
- Open more draft PRs in one calendar day than
  `QualityControlDials::PR_CAP_PER_DAY` allows (`0` means uncapped —
  check the current value in `qa/bluebook/quality_control.bluebook`
  before assuming a limit applies).
- Run a sweep's own work inline in the orchestrating session, or hand a
  sweep subagent a fresh `isolation: "worktree"` — both defeat the
  reasons this file is split the way it is.
- Log a `Bug`, conclude a sweep, or release a target on a surprising
  check — `bin/qa_sweep` stops and hands off instead; only an agent
  following the judgment above does any of those three.
- Skip `bin/qa_pr_check` before a fresh sweep. Every tick, not just the
  ones where somebody remembers a PR might have gone red — see the
  orchestrator step's own "MANDATORY, NO EXCEPTIONS" line.
- Dispatch `patch.open` or `improvement.open` from inside a sweep
  subagent's own prompt. Recording an opened PR into
  `QualityControl::Patch` or `QualityControl::Improvement` is the
  orchestrator's own job, done once a report naming the PR comes back —
  see the orchestrator step's own instructions and "On a surprising
  check"'s own reporting bullet, above.
