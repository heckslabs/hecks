# The corpus and independent properties judge the kernel, and nothing seeds the corpus from the kernel it judges

**Status:** Proposed. Step 9 of the plan in ADR 0188; slice 0 of `docs/plans/simulation-tests.md`.
Nothing here is built. Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

ADR 0188 point 5 makes the corpus the oracle and says property tests, QA findings and behaviors are
folded into it before any engine is deleted. Three things can fail a kernel run today: a frozen `expect`,
a divergence from the Ruby runtime (the differential), and a failed property.

Retiring Ruby as an executor removes the second outright. It hollows the third, because (**R**) the guard,
mutation and role traces the properties read are recorded by re-running Ruby's own `CommandInterpreter`
and `CommandRules` (`lib/hecks/fuzzing/replay/guard_check.rb`, `replay/mutation_trace.rb`), and
`role_check.rb` builds a `Runtime::Dispatcher`. Those properties judge the Ruby runtime with the Ruby
runtime. The sequence generator also reads Ruby outcomes while it builds a sequence (**R**).

The corpus survives, but (**R**) its `expect` was seeded once by `test_suite_run.seed_semantics_corpus!`,
which replays on the Ruby runtime, and then reviewed. It is a fixed set and not a generator of new cases.

## Decision

1. **Five layers judge the kernel, strongest first.**
   1. **The frozen corpus** (`expect` in `spec/corpus`, `docs/semantics`). Judges known cases; cannot find
      one nobody wrote.
   2. **Metamorphic and model-based properties**, which need no second evaluator: a refused step leaves
      the store byte-identical; a dry run equals the real outcome and mutates nothing; replaying a
      session's journal into a fresh session gives the same instances; `snapshot` then `restore` is the
      identity; two sessions never share a store; a null fact answer refuses exactly when `needs` named
      it; the same seed gives the same history. All use only the serve protocol (**R**: sessions,
      snapshot, restore and dry run exist). Cannot catch a rule the kernel gets wrong consistently.
   3. **Static checks from the front end.** `Bluebook::ModelCheck` (**R**, required by `properties.rb`)
      reads declared shape: sets, types, required. Independent only for shape; the expression part has no
      independent judge once Ruby's evaluator goes (**I**), and the corpus `grammar/` set is the only
      guard on it.
   4. **Version differential.** The candidate kernel against the last certified kernel (`edge`) on the
      same seeded sequences. Every divergence must be explained by a corpus change in the same pull
      request. It cannot catch a bug present in both, which is why layers 1 to 3 stay.
   5. **Ruby, until the gate below passes.** The Ruby-versus-kernel differential keeps running nightly
      (ADR 0188 point 5).
2. **A corpus `expect` is never seeded from the kernel it will judge.** That is a tautology. After Ruby
   stops running domains, a new `expect` is written by hand or from a `.behaviors` file and reviewed.
   `seed_semantics_corpus!` stays pointed at the Ruby engine until then and is retired with it.
3. **The retirement gate.** Ruby leaves as an oracle only when both the Ruby-versus-kernel differential
   and the version differential show no unexplained divergence over **14 consecutive clean nightly
   sweeps at double the current per-domain seed budget**. The gate is read from `nightly-main.yml`, not
   from a push run. The number 14 and the doubling are the plan's choice taken on the owner's "your call";
   the owner may set another when accepting. (**I**: the plan calls the budget `SEED_BUDGET`; that name
   was not found in the tree by search, so the build confirms where the budget lives.)
4. **A callback answer is part of the step.** A seeded sequence that reaches a `needs` fact asks the host
   for it, and ADR 0189 says such a dispatch is not replayable from its journal alone. So the runner
   answers from a clock the seed owns, never the wall clock, and records each answer on its step as a
   `facts` key, so a finding replays and shrinks. The corpus step shape (`verb`, `args`, `role`,
   `actor_id`) has no such field today (**R**), so Ruby and Rust parsers are held to it by
   `check_conformance`.
5. **The simulation vocabulary is the existing QualityControl and Fuzzing bluebooks.** If a coder finds it
   too large (not measured), splitting it out is a finding to report.

### Which parts are declared and which are code

Bluebook first.

- **Bluebook.** A Simulation (seed, domain, step count, the finding it produced, the shrunk repro) is
  domain vocabulary, so `Simulation.run!` is a command and not a script; with no command, that is a
  bluebook gap (CLAUDE.md). The nearest home is the Fuzzing and QualityControl bluebooks (decision 5).
  The `facts` key on a corpus step is data the corpus format declares.
- **Hecksagon.** Which kernel binary answers, which clock source, which persistence: wiring, Memory by
  default (ADR 0191).
- **Adapter and generator code.** The engine seam, the callback answerer, the sequence generator and the
  shrinker are imperative Ruby that drives a process. The shrinker is already engine-agnostic (**R**,
  "never replays anything").

## Consequences

- Every divergence the version differential finds needs a corpus change in the same pull request, so the
  corpus grows with the kernel.
- The oracle gap is real, not procedural: a rule both kernel builds get wrong the same way passes
  everywhere once Ruby is gone. The only mitigation is more corpus. This record states it so it is not
  taken for solved.
- Until the properties that re-run Ruby's interpreter are rewritten as layer 2 properties, a fuzz run on
  the kernel is half Ruby. The first slice must report which properties ran on which engine.
- A new corpus case seeded from Ruby encodes a Ruby bug as truth while two runtimes exist; review is the
  only guard until decision 2 removes the cause.
- `mutation`, `concurrent_dispatch`, `era_boundary` and `persistence_parity` need Ruby adapters, threads or
  eras; they stay in Ruby until their own steps.

## Rejected alternatives

- **Seeding the new corpus from the kernel.** Makes the kernel its own judge.
- **Keeping Ruby as the oracle indefinitely.** Keeps the second hand-written kernel ADR 0188 retires.
- **A shorter gate.** A single clean sweep says little about the cases a seed has not reached.
