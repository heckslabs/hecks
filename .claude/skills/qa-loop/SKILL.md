---
name: qa-loop
description: Run one adversarial QA-loop iteration against hecks — claim a chapter through the QualityControl ledger, run the existing Ruby/Rust fuzz harnesses against it, log any divergence as a Bug with a failing test, fix it if self-contained (draft PR), release the chapter. Use when asked to run the hecks QA loop, hunt for Ruby/Rust parity bugs, or "run the loop"/"do a sweep".
---

# Running one QA-loop sweep

The ledger is `qa/bluebook/quality_control.bluebook` (PR #516). This
skill is the explicit, invokable driver for it — the thing a person or a
`/loop` invocation actually runs, one iteration at a time. Read
`qa/bluebook/quality_control.bluebook`'s own header comment first if
you haven't: the whole practice in three rules — a CHECK compares an
expectation against an answer, a BUG is logged with the failing test that
proves it or it isn't logged, everything else is a GATE (refuses, can be
waived by a human, never by this loop).

## 0. One-time: make sure the ledger boots for real

```
bundle exec ruby bin/run qa/bluebook --help
```

If this fails, stop and fix the ledger itself first — don't sweep against
a chapter tracker that isn't live. (`data/` populates under `qa/` on
first real dispatch; that's expected, not a bug.)

## 1. Pick a chapter — `Rotation`, least recently swept first

```
bundle exec ruby bin/run qa/bluebook ask rotation
```

If it's empty, no chapter has been `Identify`d yet — seed the two the
existing fuzz-bridge already knows (`bin/fuzz`, `spec/rust_conformance_fuzz_spec.rb`
both cover exactly these two):

```
bundle exec ruby bin/run qa/bluebook identify reference=pizzas  path=examples/pizzas
bundle exec ruby bin/run qa/bluebook identify reference=banking path=examples/banking
```

Widen later (Phase 4 below) — don't invent new Targets before the two
already-instrumented ones have had a real pass.

## 2. Claim it

```
bundle exec ruby bin/run qa/bluebook target.claim id=<reference> held_by.value=<your name> now.value=$(date +%s)
```

The claim is the whole collision guard (Q6 of the design) — a live claim
younger than its `window` (900s default) refuses a second claimant
outright. Fresh branch per finding (below) is the second layer, not the
first.

## 3. Open a sweep, run the existing harnesses

```
bundle exec ruby bin/run qa/bluebook open target=<target-id> reference.value=SW-<n> engineer.value=<your name>
```

Then run what already exists — this loop OPERATES the fuzz infrastructure,
it doesn't reinvent it:

- **Single-runtime property/exception fuzzing**: `bin/fuzz <domain> --seed N`
  (shrinks and saves the first finding under `tmp/fuzz-failures/` on its
  own).
- **Ruby↔Rust differential fuzzing** (the actual parity check): the
  `spec/rust_conformance_fuzz_spec.rb` pattern — generate seeded
  sequences via `Hecks::Fuzzing::SequenceGenerator`, replay through both
  `Hecks::Fuzzing::Replay.call` and the compiled Rust conformance binary,
  diff. Widen the seed count locally with `SEEDS=40` (that spec's own
  convention). Note ADR 0037 findings 3-5 may still be open — check
  `spec/quality_control_spec.rb`'s own current status / `ALLOWED_FINDINGS`
  before assuming a divergence there is new.

For each dispatch you actually put to the system, log a `Check` with the
expectation written FIRST:

```
bundle exec ruby bin/run qa/bluebook check id=<sweep-id> subject.value="<what was put to the system>" expectation.value="<what should happen>"
# then, after looking — `to.aggregate` is the sweep, `to.entity` is the Check's own sequence number:
bundle exec ruby bin/run qa/bluebook held      to.aggregate=<sweep-id> to.entity=<n> sequence.value=<n> observation.value="<what actually happened>"   # matched
bundle exec ruby bin/run qa/bluebook surprised to.aggregate=<sweep-id> to.entity=<n> sequence.value=<n> observation.value="<what actually happened>"   # didn't
```

## 4. On a surprising Check — a genuine divergence or crash

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
  regression test goes green, open a **draft PR**.
  - Branch: `loop-parity/<slug>`.
  - Commit identity: this repo's own `Miette <miette@embryonaut.ai>` —
    already the local git config, don't override it.
  - **Never auto-merge.** Draft, always, regardless of CI status —
    green CI is necessary, not sufficient, for something that ran
    unattended.
  - **Cap: 3 such PRs per day.** Check today's already-opened
    `loop-parity/*` PRs (`gh pr list --search "head:loop-parity"
    --search "created:>=$(date +%Y-%m-%d)"`) before opening a fourth —
    stop and leave the rest as open Bugs instead.
  - Mark the Bug's own lifecycle through as work happens:
    `investigate`, `fix commit.value=<sha>`, `verify verification.value="<what was run>"`.
- **Bigger** (touches semantics, needs real judgment): leave the `Bug`
  open and unclaimed. **No GitHub issue** — the ledger's own `Bug` record
  IS the tracker. `Ticket`/`IssueTracker` stays dormant; don't wire it.
- **Never waive it yourself.** You may note "this looks waivable, here's
  why" in the Bug's own notes/reason field — only a human actually calls
  `bug.waive`/`sweep.waive`.

## 5. Conclude and release

```
bundle exec ruby bin/run qa/bluebook conclude id=<sweep-id> notes.value="<what this sweep learned, min 40 chars>"
bundle exec ruby bin/run qa/bluebook release id=<target-id> now.value=$(date +%s)
```

(`made` is derived from the sweep's own checks — not a `conclude` argument.)

## 6. Report

Only surface something if you found something — a new `Bug`, an
opened/merged draft PR, a real parity mismatch. A clean sweep of an
already-solid chapter is a silent, successful no-op, not a report.

---

## Phase 4 — authoring a new stress domain (occasional, not every sweep)

Once `pizzas`/`banking` have had real passes, "being clever" means
authoring a **new domain shape**, not just varying sequences against the
same two. The existing fuzz-bridge only does the latter.

- Live under `qa/stress_domains/`, never `examples/` — clearly synthetic,
  never mistaken for a usage sample.
- Bias hard toward RE-TRIGGERING, in a new context, a class of bug hecks
  has already found — cite the specific memory/ADR/PR you're aiming at
  (ADR 0037's findings, the Heki list-key symbol/string-keyed
  divergence, ports method-contract gaps, ...). Highest hit-rate;
  broader/untargeted generation only once that vein's exhausted.
- **Discard it** unless it exercises a DSL construct-combination the
  current `Target` set doesn't already cover — check what pizzas/banking
  (and now the stress domain candidates already in `qa/stress_domains/`)
  already use before keeping a new one. An ever-growing corpus with no
  new signal is pure CI-time cost.
- A domain that survives becomes a real `Target` (`identify`) and enters
  the same rotation as any other chapter — no special-casing.

## What this loop will never do

- File a GitHub issue on your behalf (`Ticket` stays dormant).
- Merge its own draft PR.
- Waive its own finding.
- Touch a branch with recent activity, or skip claiming before working a
  chapter — the collision guardrails in step 2 aren't optional.
- Open more than 3 draft PRs in one calendar day.
