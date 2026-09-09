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
#516) — none of that needs to repeat, but *any* sweep's own bin/run
output, fuzz-seed noise, and back-and-forth still would, every single
time, if run inline. Under `/loop hecks_qa` that's every wakeup,
indefinitely. A subagent's internal transcript never reaches this
session — only its final report does — so this session's own context
stays flat regardless of how many sweeps ever run.

**The one thing that must NOT be fresh per sweep: the worktree.**
`qa/data/*.heki` (the ledger's own persisted state — Target claims, Bug
history, Sweep records) is real filesystem state, untracked by git, that
lives inside whatever checkout `bin/run` was invoked from. A generic
`isolation: "worktree"` subagent call gets a **brand-new** worktree each
time — which means a brand-new, EMPTY `qa/data/`, and the ledger would
silently forget every claim and every bug between sweeps. Don't do that.

Instead:

1. **One time, not per sweep**: make sure a dedicated, persistent
   worktree exists — e.g. `.claude/worktrees/hecks-qa-runner`. Create it
   once (`EnterWorktree` with a fixed `name`, or `git worktree add`
   directly) and never tear it down between sweeps. This is where
   `qa/data/` actually lives, permanently.
2. **Every sweep**: dispatch a subagent (the `Agent` tool, default
   isolation — i.e. *no* `isolation: "worktree"`) whose prompt is:
   - the exact working directory to `cd` into (the persistent worktree
     from step 1, as an absolute path),
   - an instruction to `git fetch && git rebase origin/main` first, so
     it starts from current main (matters if a prior sweep opened a PR
     that's since merged),
   - the full "Running one sweep" section below, verbatim, with `<your
     name>` filled in (e.g. `hecks_qa` or the engineer name you're
     operating under),
   - an instruction to leave the worktree clean (on `main`, no
     uncommitted changes, no lingering branch checked out) before
     finishing — so the *next* sweep, in the same worktree, starts from
     a known-good state.
3. Wait for the subagent's report. Relay only its short summary here —
   don't pull its internal transcript into this conversation.
4. If invoked via `/loop hecks_qa`: schedule the next wakeup per the
   loop skill's own self-pacing guidance. If invoked directly (one-off),
   you're done — report the sweep's outcome and stop.

## Running one sweep

*(This is the subagent's own prompt — steps 1-6 below, plus the two
sections after them. The ledger is `qa/bluebook/quality_control.bluebook`
— read its own header comment first if you haven't: the whole practice
in three rules — a CHECK compares an expectation against an answer, a
BUG is logged with the failing test that proves it or it isn't logged,
everything else is a GATE, refused, waivable only by a human, never by
this loop.)*

### 0. One-time-per-worktree: make sure the ledger boots for real

```
bundle exec ruby bin/run qa/bluebook --help
```

If this fails, stop and fix the ledger itself first — don't sweep
against a chapter tracker that isn't live.

### 1. Pick a chapter — `Rotation`, least recently swept first

```
bundle exec ruby bin/run qa/bluebook ask rotation
```

If it's empty, no chapter has been `Identify`d yet — seed the two the
existing fuzz-bridge already knows (`bin/fuzz`,
`spec/rust_conformance_fuzz_spec.rb` both cover exactly these two):

```
bundle exec ruby bin/run qa/bluebook identify reference=pizzas  path=examples/pizzas
bundle exec ruby bin/run qa/bluebook identify reference=banking path=examples/banking
```

Widen later (Phase 4 below) — don't invent new Targets before the two
already-instrumented ones have had a real pass.

### 2. Claim it

```
bundle exec ruby bin/run qa/bluebook target.claim id=<reference> held_by.value=<your name> now.value=$(date +%s)
```

The claim is the whole collision guard — a live claim younger than its
`window` (900s default) refuses a second claimant outright. Fresh branch
per finding (below) is the second layer, not the first.

### 3. Open a sweep, run the existing harnesses

```
bundle exec ruby bin/run qa/bluebook open target=<target-id> reference.value=SW-<n> engineer.value=<your name>
```

Then run what already exists — this loop OPERATES the fuzz
infrastructure, it doesn't reinvent it:

- **Single-runtime property/exception fuzzing**: `bin/fuzz <domain> --seed N`
  (shrinks and saves the first finding under `tmp/fuzz-failures/` on its
  own).
- **Ruby↔Rust differential fuzzing** (the actual parity check): the
  `spec/rust_conformance_fuzz_spec.rb` pattern — generate seeded
  sequences via `Hecks::Fuzzing::SequenceGenerator`, replay through both
  `Hecks::Fuzzing::Replay.call` and the compiled Rust conformance
  binary, diff. Widen the seed count locally with `SEEDS=40` (that
  spec's own convention). Check `ALLOWED_FINDINGS` before assuming a
  divergence is new — several are already catalogued and accepted.

For each dispatch you actually put to the system, log a `Check` with the
expectation written FIRST:

```
bundle exec ruby bin/run qa/bluebook check id=<sweep-id> subject.value="<what was put to the system>" expectation.value="<what should happen>"
# then, after looking — `to.aggregate` is the sweep, `to.entity` is the Check's own sequence number:
bundle exec ruby bin/run qa/bluebook held      to.aggregate=<sweep-id> to.entity=<n> sequence.value=<n> observation.value="<what actually happened>"   # matched
bundle exec ruby bin/run qa/bluebook surprised to.aggregate=<sweep-id> to.entity=<n> sequence.value=<n> observation.value="<what actually happened>"   # didn't
```

### 4. On a surprising Check — a genuine divergence or crash

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
  - **Cap: 3 such PRs per day.** Check today's already-opened
    `loop-parity/*` PRs (`gh pr list --search "head:loop-parity"
    --search "created:>=$(date +%Y-%m-%d)"`) before opening a fourth —
    stop and leave the rest as open Bugs instead.
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

### 5. Conclude and release

```
bundle exec ruby bin/run qa/bluebook conclude id=<sweep-id> notes.value="<what this sweep learned, min 40 chars>"
bundle exec ruby bin/run qa/bluebook release id=<target-id> now.value=$(date +%s)
```

(`made` is derived from the sweep's own checks — not a `conclude`
argument.)

### 6. Report, and leave the worktree clean

Confirm `git status` is clean and `main` is checked out before
finishing (the orchestrator's own cleanup requirement — the next sweep
reuses this exact worktree). Then report back only if something was
found — a new `Bug`, an opened/merged draft PR, a real parity mismatch.
A clean sweep of an already-solid chapter is a silent, successful
no-op, not a report.

---

## Authoring a new stress domain (occasional, not every sweep)

Once `pizzas`/`banking` have had real passes, "being clever" means
authoring a **new domain shape**, not just varying sequences against the
same two. The existing fuzz-bridge only does the latter.

- Live under `qa/stress_domains/`, never `examples/` — clearly
  synthetic, never mistaken for a usage sample. Use the
  `<name>/bluebook/<name>.bluebook` nested shape (see
  `qa/stress_domains/ledger_ordering/`) — a flat `<name>.bluebook`
  breaks `bin/project_rust`'s own naming convention.
- Bias hard toward RE-TRIGGERING, in a new context, a class of bug
  hecks has already found — cite the specific memory/ADR/PR you're
  aiming at. Highest hit-rate; broader/untargeted generation only once
  that vein's exhausted.
- **Discard it** unless it exercises a DSL construct-combination the
  current `Target` set doesn't already cover — check what
  pizzas/banking (and the stress domains already in
  `qa/stress_domains/`) already use before keeping a new one. An
  ever-growing corpus with no new signal is pure CI-time cost.
- A domain that survives becomes a real `Target` (`identify`) and
  enters the same rotation as any other chapter — no special-casing.

## What this will never do

- File a GitHub issue on your behalf (`Ticket` stays dormant).
- Merge its own draft PR.
- Waive its own finding.
- Touch a branch with recent activity, or skip claiming before working
  a chapter — the collision guardrails in step 2 aren't optional.
- Open more than 3 draft PRs in one calendar day.
- Run a sweep's own work inline in the orchestrating session, or hand a
  sweep subagent a fresh `isolation: "worktree"` — both defeat the
  reasons this file is split the way it is.
