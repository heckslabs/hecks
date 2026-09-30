---
name: hecks_qa
description: Run one tick of hecks's adversarial QA practice — `exe/hecks quality_control ask tick` (CI watch over open PRs, then a bounded sweep of the whole QualityControl rotation), then dispatch judgment only where a tick found something. Invoke directly for one tick, or via `/loop hecks_qa` for continuous operation. Use when asked to hunt for hecks Ruby/Rust parity bugs, "run a QA sweep", "run a QA tick", or "run the hecks QA loop".
---

# `hecks_qa` — one tick, dispatched; judgment only where something was found

**This skill does not itself loop.** It runs exactly one tick. For
continuous operation the *caller* wraps it: `/loop hecks_qa`. Everything
mechanical lives in scripts and in `lib/hecks/quality_control/quality_control.bluebook`
(the chapter, with its ports and adapters beside it; `qa/` keeps this repository's
ledger wiring, world, settings and stress domains) (read its header once — three rules: a CHECK compares an expectation
against an answer; a BUG is logged with the failing test that proves it or
not at all; everything else is a GATE, refusable, waivable only by a
person). What is left here is judgment.

## The tick — dispatch it, don't run it inline

The former `qa_*` scripts are verbs on the launcher now: `exe/hecks quality_control <verb>`.
A `--flag` a script took goes inside `arguments="--flag …"` on the `ask` verbs, and the
ledger-writing verbs (`log`, `patch.open`, `improvement.open`) take `name=value` words instead
of flags (`exe/hecks quality_control <verb> --help` prints each one's words; the mapping is in
`lib/hecks/three_zero/forms.yml`). Where a step below still shows the old flag spelling
(`--title`, `--angle`, `--from-dials`, `--promote`), pass it that way.

Run `exe/hecks quality_control ask tick` in **one subagent**, in the **persistent worktree**
`.claude/worktrees/hecks-qa-runner` (create it once with `EnterWorktree`
and a fixed `name`, never tear it down: the Rust conformance-binary build
cache under `rust/target/` is real and expensive, and a fresh
`isolation: "worktree"` per tick would rebuild it every time; the ledger
itself is Postgres — `hecks_quality_control`, see `qa/bluebook/
quality_control.world` — so it is shared state, not worktree state).
Also once, per machine: the ledger connects as `hecks_qa`, an ordinary
non-superuser role, because PostgresEra refuses to boot over a superuser
connection — its era write-fence is row-level security, which a
superuser walks through (BUG#24). Run `exe/hecks quality_control ask create_ledger_role database.value=
hecks_quality_control` once (idempotent; the `.world` header explains)
before the first boot. Never run the tick inline: its output is large
and would land in this session's context every wakeup.

The subagent's prompt is: `cd <absolute path of the runner worktree>`,
then `bundle exec exe/hecks quality_control ask tick`, then relay the ENTIRE printed report
back verbatim, and make no judgment of its own. `exe/hecks quality_control ask tick` refuses a
dirty tree, rebases onto `origin/main`, runs `exe/hecks quality_control ask check_pull_requests` FIRST
(always — the order is the script, not a rule to remember), then
`exe/hecks quality_control ask run arguments="--all"` (bounded by `QualityControlDials::SWEEP_MAX_PARALLEL`,
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
   `replay:` line (the SHRUNK sequence, under `shrunk:`) — or, when no
   `shrunk:` block was printed (a non-shrinkable mode, or
   `SHRINK_BUDGET = 0`), the `reproduce:` line. A divergence that is
   really a known gap, a flake, or a fixture problem is not a bug — say
   why in your report and stop.
2. **Write the failing test** that proves it — a real spec or command
   that exits non-zero today. Build it from the shrunk steps, not the
   full generated seed: they are already the minimal sequence that
   still reproduces the same finding. **If you are confident the finding
   is genuine but cannot get a reliable, deterministic reproduction**
   (flaky, environment-sensitive, timing-dependent) — do NOT silently
   drop it. Author your best-effort reproduction attempt anyway: real,
   runnable code (a spec file, a script, a direct
   `Hecks::Fuzzing::Replay.call` snippet — whatever fits), saved under
   `tmp/qa-repro-attempts/` (the same convention `tmp/qa-shrunk/` already
   uses for shrunk sequences) or committed alongside any fix work, then
   log it with `--reproduced no` (step 3) rather than leaving it
   unlogged.
3. **Log it, triaged:** `exe/hecks quality_control log sweep=<sweep-id> title.value=… \
   --demonstration "<that command>" --symptom … --expectation … \
   --submitter <you> --triage self_contained|bigger [--reproduced no]`.
   It RUNS the demonstration and refuses a passing one — UNLESS
   `--reproduced no` is passed (default `yes`), which skips that check
   for exactly the no-reliable-signal case above. `--demonstration` is
   still required either way, and must still be real runnable code (a
   file path or an actual command), never prose describing what
   happened. It mints `BUG#n` itself. `self_contained` means a missing
   guard, an off-by-one, a validation gap — no semantic or architectural
   call. Anything else is `bigger`.
4. **If `self_contained`:** fix it on a fresh `qa/<slug>` branch in the
   runner worktree; move the bug through `hecks run qa/bluebook
   bug.investigate id=BUG#n …`, `fix id=BUG#n reference.value=BUG#n
   commit.value=<sha>`, `verify id=BUG#n evidence.value="<what ran>"`;
   then `exe/hecks quality_control patch.open bug=BUG#n title.value="…"`. It asks the ledger
   first, as a dry run of `Patch.Open`, whose `given`s refuse a branch
   off `BRANCH_PREFIX` and a bug that is not `fixed`; the `GitPr` adapter
   refuses a fix commit not on HEAD and a day already at
   `PR_CAP_PER_DAY`. It records the PR in the ledger itself and queues
   auto-merge per `AUTO_MERGE`. Return the worktree to `main`, clean,
   before finishing.
5. **If `bigger`:** leave the Bug open and unclaimed. The ledger IS the
   tracker — no GitHub issue (`Ticket` stays dormant).

For a **newly-red PR** the record is already back in `investigating`
(`BugCiWatch`) or `needs_fix` (`ImprovementCiWatch`): don't re-log; fix
through the SAME record and, for an Improvement, `land id=<n>
number.value=<n> commit.value=<new-sha>`.

**A suspended target is released only by a person**: `exe/hecks quality_control ask run
<target> --release --notes "<what you concluded, 40+ chars>"`. It concludes
the open sweep, counts the bugs it logged, moves the streak, and records
what the chapter can be compared against. Never release from a subagent.

## On a generated-domain finding

`exe/hecks quality_control ask tick`'s third step, `exe/hecks quality_control ask check_generated_domains --from-dials`,
checks domains `Hecks::Fuzzing::DomainGenerator` wrote (two
`FormCensus::FORMS` forced onto one aggregate, plus extras), against Rust
too when `GENERATED_DOMAINS_RUST` is on. A `GENERATED DOMAIN FOUND
SOMETHING` block has already been shrunk twice: the domain (`domain:`,
with its before/after size) and the steps (`shrunk:`, `replay:`). Nothing
is in the ledger yet and no target is suspended. The per-finding
subagent's judgments:

1. **Genuine, or a generator artifact?** Replay it. A mode of
   `rust_projection`/`rust_build` means a bluebook Ruby boots that the
   Rust projection cannot compile — real, unless the domain uses a name
   the projection documents as reserved. A divergence the rotation's own
   known-gap tables already excuse is not new.
2. **If genuine:** promote it, `exe/hecks quality_control ask check_generated_domains --promote
   <finding-dir> --name <stress_domain_name>` (the report's `promote:`
   line). That copies the minimal domain into `qa/stress_domains/`, renamed,
   with a NOTES.md. Then follow the printed next steps, `exe/hecks quality_control ask target.seed`
   last — it derives the rotation from the corpus
   (`Hecks::Corpus.rotation_targets`), so a promoted domain is a target by
   virtue of being on disk, and nobody has to remember an `identify` line.
   Forgetting it is how ten stress domains went unswept. The next sweep of
   that target surprises the ordinary way, and the
   "On a finding" section above applies from there: the failing test, then
   `exe/hecks quality_control log`.
3. **If an artifact of the generator itself:** say so in your report. A
   generator fix is deliberate work (`exe/hecks quality_control improvement.open`),
   never a Bug.

## Mining combinations with an agent (opt-in, never part of a tick)

Only when a person asks for it ("mine new combinations", "have an agent
look for new bug shapes"): `exe/hecks quality_control ask mine_combinations [--candidates N]
[--rust]`. It censuses `qa/stress_domains/*` and `examples/*`, asks an
agent (the `Agent` adapter: `claude -p` by default) to write N candidate bluebooks aimed at
unmet form pairs and recent bug mechanisms, each with a HYPOTHESIS.md,
gives non-booting ones back for one repair round, and checks the rest
through `exe/hecks quality_control ask check_generated_domains --source`. `--brief` prints the prompt
without calling an agent; `--from <run>/candidates` re-checks an earlier
run. Run it in a subagent (its output is large). A `GENERATED DOMAIN FOUND
SOMETHING` block from it is handled exactly as in the section above; the
promoted NOTES.md carries the agent's hypothesis. `exe/hecks quality_control ask tick` never runs
it and no dial turns it on.

## Authoring a new stress domain (occasional)

Read the backlog first — `hecks run qa/bluebook ask backlog` and `ask
resolved` — before inventing an angle; `ask citing citation.value="…"`
before proposing one. A new domain lives under `qa/stress_domains/<name>/
bluebook/<name>.bluebook`, biases hard toward re-triggering a bug class
already found (cite it), and is discarded unless it covers a construct
combination no current `Target` does (`exe/hecks quality_control ask judge_novelty`, once it
exists). Close the loop: `angle.investigate` when you pick a lead up,
`build resolution.value=…` or `discard reason.value=…` when it lands;
`propose premise.value=… citation.value=… proposer.value=…` for a
genuinely new angle. A surviving domain becomes a `Target` (`identify`)
and enters the rotation like any other; `exe/hecks quality_control ask run` picks its mode
itself. Deliberate work with no Bug behind it is opened with
`exe/hecks quality_control improvement.open [--angle ANGLE-n] --title …`.

The sweep compares on three axes — Ruby vs the compiled Rust binary, an
engine against ITSELF (self-consistency: cold rehydration, replay
idempotency, value-object round trip), and Memory vs a real PostgresEra
boot (`--persistence-parity`, single-target) — so "the engines agree" is
never the whole answer.

## Discovering external domains (opt-in, occasional)

Only when a person asks for it ("look for new domains", "what's out
there in ~/Projects"): `exe/hecks quality_control ask discover_external_domains 
[--projects-dir <path>] [--max-depth N]`. It walks sibling repos under
`~/Projects` (never this repo — already fully covered) for a directory
shaped `<name>/bluebook/<name>.bluebook` — matched uniformly at every
depth, so a sibling repo that IS one domain at its own root
(`<repo>/bluebook/<repo>.bluebook`, e.g. `~/Projects/some_site`) is
found the same way a nested one is — confirmed against the project's
own `Gemfile`/`Gemfile.lock` for a real `hecks` gem dependency (a repo
depending only on `hecksagain`, e.g. `~/Projects/some_console_app`
today, is correctly excluded even though its bluebook reads
`Hecks.bluebook` — that gem aliases `Hecks = Hecksagain`, it is not the
real `hecks` gem), cross-referenced against `Target.All` so an already-
identified domain is never re-reported. **Report only** — it never
calls `identify` itself; it prints the exact `hecks run qa/bluebook
identify reference=… path=…` command for a person to review and run.
`exe/hecks quality_control ask tick` never runs it and no `qa/settings.yml` dial turns it on,
same as `exe/hecks quality_control ask mine_combinations arguments.value=` above. Before enrolling a real find,
read its own header for a live limitation: `exe/hecks quality_control ask run` resolves
every `Target.path` relative to THIS repo's root, so sweeping a target
whose real location is outside it needs that gap closed first.

## What this will never do

- File a GitHub issue, or merge by hand (`exe/hecks quality_control patch.open` queues
  auto-merge per the dial; CI decides).
- Waive a gate. `sweep.waive`/`bug.waive` now REFUSE `waived_by`
  `qa_sweep` and `nobody` — only a signed person gets through.
- Release a suspended target, log a bug without a `--demonstration` at
  all, or mint a `BUG#` by hand — the scripts refuse each.
  `--demonstration` must still fail when run UNLESS `--reproduced no`
  says there is no reliable pass/fail signal to check (see "On a
  finding" above) — but it is never optional, and never prose.
- Run the tick inline, hand it a fresh worktree, or skip `exe/hecks quality_control ask check_pull_requests`
  — `exe/hecks quality_control ask tick` is the order.
