---
name: hecks_qa
description: Run one tick of hecks's adversarial QA practice — bin/qa_tick (CI watch over open PRs, then a bounded sweep of the whole QualityControl rotation), then dispatch judgment only where a tick found something. Invoke directly for one tick, or via `/loop hecks_qa` for continuous operation. Use when asked to hunt for hecks Ruby/Rust parity bugs, "run a QA sweep", "run a QA tick", or "run the hecks QA loop".
---

# `hecks_qa` — one tick, dispatched; judgment only where something was found

**This skill does not itself loop.** It runs exactly one tick. For
continuous operation the *caller* wraps it: `/loop hecks_qa`. Everything
mechanical lives in scripts and in `qa/bluebook/quality_control.bluebook`
(read its header once — three rules: a CHECK compares an expectation
against an answer; a BUG is logged with the failing test that proves it or
not at all; everything else is a GATE, refusable, waivable only by a
person). What is left here is judgment.

## The tick — dispatch it, don't run it inline

Run `bin/qa_tick` in **one subagent**, in the **persistent worktree**
`.claude/worktrees/hecks-qa-runner` (create it once with `EnterWorktree`
and a fixed `name`, never tear it down: the Rust conformance-binary build
cache under `rust/target/` is real and expensive, and a fresh
`isolation: "worktree"` per tick would rebuild it every time; the ledger
itself is Postgres — `hecks_quality_control`, see `qa/bluebook/
quality_control.world` — so it is shared state, not worktree state).
Never run the tick inline: its output is large and would land in this
session's context every wakeup.

The subagent's prompt is: `cd <absolute path of the runner worktree>`,
then `bundle exec ruby bin/qa_tick`, then relay the ENTIRE printed report
back verbatim, and make no judgment of its own. `bin/qa_tick` refuses a
dirty tree, rebases onto `origin/main`, runs `bin/qa_pr_check` FIRST
(always — the order is the script, not a rule to remember), then
`bin/qa_sweep --all` (bounded by `QualityControlDials::SWEEP_MAX_PARALLEL`,
each target's depth widened from its own `clean_streak`, stale holds
reclaimed and named), and exits with the precedence across both:

- **0 — clean.** Relay the summary. Nothing to dispatch.
- **1 — operational error, nothing found.** Read the actual message(s);
  fix the real problem or report it. Nothing to dispatch per target.
- **2 — FOUND SOMETHING.** For EACH finding in the report — a `FOUND
  SOMETHING` slice from `--all`, or a `NEWLY-RED PR` from `qa_pr_check` —
  dispatch ONE fresh subagent carrying that slice VERBATIM plus the
  section below. Findings never wait on each other.

If the report's `stale holds reclaimed:` count is non-zero on consecutive
ticks for the same target, say so: a hold that has to be reclaimed every
tick is a release that keeps failing to land, and that is worth a Bug.

Under `/loop hecks_qa`: dispatch the next tick the moment every subagent
this tick started has reported. `QualityControlDials::CADENCE_SECONDS` is
the floor between ticks (`0` = immediately); use `ScheduleWakeup` only as
a liveness fallback, at `QualityControlDials::LIVENESS_FALLBACK_SECONDS`.

## On a finding — the per-finding subagent's own prompt

The target is already **suspended** (the ledger's own `SuspendOnSurprise`
policy did that the moment the check was recorded) and its sweep is left
open; nothing re-fuzzes it until a person releases it. Your judgments,
in order:

1. **Genuine, or a harness artifact?** Reproduce with the report's own
   `reproduce:` line. A divergence that is really a known gap, a flake,
   or a fixture problem is not a bug — say why in your report and stop.
2. **Write the failing test** that proves it — a real spec or command
   that exits non-zero today.
3. **Log it, triaged:** `bin/qa_log_bug --sweep <sweep-id> --title … \
   --demonstration "<that command>" --symptom … --expectation … \
   --submitter <you> --triage self_contained|bigger`. It RUNS the
   demonstration and refuses a passing one; it mints `BUG#n` itself.
   `self_contained` means a missing guard, an off-by-one, a validation
   gap — no semantic or architectural call. Anything else is `bigger`.
4. **If `self_contained`:** fix it on a fresh `qa/<slug>` branch in the
   runner worktree; move the bug through `bin/run qa/bluebook
   bug.investigate id=BUG#n …`, `fix id=BUG#n reference.value=BUG#n
   commit.value=<sha>`, `verify id=BUG#n evidence.value="<what ran>"`;
   then `bin/qa_open_pr --bug BUG#n --title "…"`. It refuses a branch
   off `BRANCH_PREFIX`, a bug that is not `fixed`, a fix commit not on
   HEAD, and a day already at `PR_CAP_PER_DAY`; it records the PR in the
   ledger itself and queues auto-merge per `AUTO_MERGE`. Return the
   worktree to `main`, clean, before finishing.
5. **If `bigger`:** leave the Bug open and unclaimed. The ledger IS the
   tracker — no GitHub issue (`Ticket` stays dormant).

For a **newly-red PR** the record is already back in `investigating`
(`BugCiWatch`) or `needs_fix` (`ImprovementCiWatch`): don't re-log; fix
through the SAME record and, for an Improvement, `land id=<n>
number.value=<n> commit.value=<new-sha>`.

**A suspended target is released only by a person**: `bin/qa_sweep
<target> --release --notes "<what you concluded, 40+ chars>"`. It concludes
the open sweep, counts the bugs it logged, moves the streak, and records
what the chapter can be compared against. Never release from a subagent.

## Authoring a new stress domain (occasional)

Read the backlog first — `bin/run qa/bluebook ask backlog` and `ask
resolved` — before inventing an angle; `ask citing citation.value="…"`
before proposing one. A new domain lives under `qa/stress_domains/<name>/
bluebook/<name>.bluebook`, biases hard toward re-triggering a bug class
already found (cite it), and is discarded unless it covers a construct
combination no current `Target` does (`bin/qa_domain_novelty`, once it
exists). Close the loop: `angle.investigate` when you pick a lead up,
`build resolution.value=…` or `discard reason.value=…` when it lands;
`propose premise.value=… citation.value=… proposer.value=…` for a
genuinely new angle. A surviving domain becomes a `Target` (`identify`)
and enters the rotation like any other; `bin/qa_sweep` picks its mode
itself. Deliberate work with no Bug behind it is opened with
`bin/qa_open_pr --improvement [--angle ANGLE-n] --title …`.

The sweep compares on three axes — Ruby vs the compiled Rust binary, an
engine against ITSELF (self-consistency: cold rehydration, replay
idempotency, value-object round trip), and Memory vs a real PostgresEra
boot (`--persistence-parity`, single-target) — so "the engines agree" is
never the whole answer.

## What this will never do

- File a GitHub issue, or merge by hand (`bin/qa_open_pr` queues
  auto-merge per the dial; CI decides).
- Waive a gate. `sweep.waive`/`bug.waive` now REFUSE `waived_by`
  `qa_sweep` and `nobody` — only a signed person gets through.
- Release a suspended target, log a bug without a failing demonstration,
  or mint a `BUG#` by hand — the scripts refuse each.
- Run the tick inline, hand it a fresh worktree, or skip `bin/qa_pr_check`
  — `bin/qa_tick` is the order.
