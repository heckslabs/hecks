# Step 9 of ADR 0188: simulation tests against the kernel

Status: a plan, nothing built. Base: `origin/main` at `d1510ad79`. Date: 2026-11-05.
Goal: the fuzzer, the shrinker and the `.behaviors` files drive the Rust kernel through the host
protocol (ADR 0189), and something other than the Ruby runtime judges what the kernel does. Every
slice ships alone and leaves today's Ruby-vs-Rust differential running until the last one.

**R** marks what I read in this tree; **I** marks what I inferred and have not confirmed.

## What exists today

| Piece | Where | State |
|---|---|---|
| Sequence generator | `lib/hecks/fuzzing/sequence_generator.rb` and `sequence_generator/*` | **R** emits `{name, note, steps}` in the shape of `spec/corpus/*.json`. It dispatches each step "for real against a throwaway boot" while it builds the sequence, so its `OutcomeTracker` reads Ruby outcomes. The generator is therefore a client of the Ruby runtime |
| Replay | `lib/hecks/fuzzing/replay.rb`, `replay/session.rb` | **R** boots through `IsolatedBoot` and `Hecks.boot`, plays steps in a `Session` and returns a history hash (instances, events, refusals, reactions, sagas, queries, oracle traces) |
| Differential | `lib/hecks/fuzzing/differential.rb`, `differential/wire_comparison.rb` | **R** Ruby history vs one batch run of a per-domain binary (`Open3.capture2(binary, stdin_data: KernelInput.json(...))`). Compares six wire fields: instances, events, refusals, queries, sagas, dry runs. It does not use `--serve` or sessions |
| Shrinker | `lib/hecks/fuzzing/shrinker.rb` (178 lines) + `shrinker/value_simplification.rb` | **R** "never replays anything": three passes (chunk removal, argument-key removal, value simplification) driven by the caller's block. It is already engine-agnostic |
| Properties | `lib/hecks/fuzzing/properties.rb` + 24 files in `properties/` | **R** each is `history -> true or message`. **R** the oracle traces they read are recorded by re-running Ruby's own `CommandInterpreter` and `CommandRules` (`replay/guard_check.rb:64-65`, `replay/mutation_trace.rb:76`), and `role_check.rb` builds a `Runtime::Dispatcher`. Those properties judge the Ruby runtime with the Ruby runtime |
| Other Ruby-only modes | `concurrent_dispatch`, `mutation` (11 files), `projection_agreement`, `era_boundary`, `persistence_parity`, `isolated_boot` | **R** (names only, not read in depth) |
| Corpus | `spec/corpus/*.json` (22), `rust_conformance/` (98), `semantics/` (53 entries), `grammar/`, `asks/`, `docs/semantics/*.md` | **R** counts. **R** `conformance_corpus_spec.rb` holds Ruby to each fixture's frozen `expect`, `rust_conformance_spec.rb` holds a per-domain binary to the same `expect`; "neither runtime is the oracle". **R** the `expect` is seeded once by `test_suite_run.seed_semantics_corpus!` (`SeedSemanticsCorpus.expectation_for` replays on the Ruby runtime) and then reviewed |
| `.behaviors` | 34 files: 9 in `spec/behaviors/fixtures`, 8 in `examples/*/bluebook`, 6 in `lib/hecks/hecks`, 11 elsewhere under `lib/hecks` | **R** (find). `Behaviors::Expectations.run_one(test, suite, runtime: nil)` already accepts a runtime; `Boot.runtime_for` boots Ruby Memory-only and refuses another adapter. The shim `behaviors/rspec.rb` makes each test an `it` |
| Kernel side | `rust/src/kernel/serve.rs`, `cli.rs`, `lib/hecks/rust_build/kernel_client.rb` | **R** `--serve` has `hello`, `open`/`close`, a callback for `ask: "fact"`. **R** a session step can also be `snapshot`, `restore`, `instances` and a `query`; `seed` restores prior state. The kernel is still built per domain with a cargo feature (**R** `rust_conformance_spec.rb` `build_rust_for`) |

Open Work items (**R**, `Work.undone`, main checkout) that this plan must not duplicate:
`kernel-client-pizzas`, `kernel-client-gate`, `kernel-client-surface`, `kernel-client-facts`,
`kernel-client-driving`, `kernel-client-specs` (from `docs/plans/kernel-thin-client.md`). I did not find an
open item for the fuzzer, the shrinker or the oracle. `exe/hecks agents PlanReview.reviews` is not a command
here (**R**: `no such command: agents`), so I could not check plans under review; look it up under the
`AgentRun` family or ask.

## Bluebook or hecksagon?

Each piece, placed:
- A *Simulation* (seed, domain, step count, the finding it produced, the shrunk repro) is domain
  vocabulary: a **bluebook** change, so `Simulation.run!` is a command and not a script (CLAUDE.md: "no
  command does what you need" is a bluebook gap). I **I**nfer the nearest home is the existing Fuzzing/
  QualityControl bluebooks; I did not check which fits.
- Which kernel binary, which clock source, which persistence: **hecksagon** wiring (Memory by default).
- The engine seam, the callback answerer, the generator and the shrinker are **adapters/generators**:
  imperative Ruby behind a port, the kind CLAUDE.md allows. The reason: they drive a process.

## The oracle question: what judges the kernel once Ruby does not run it

Today three things can fail a kernel run: a frozen `expect` (the corpus), a divergence from the Ruby
runtime (differential), and a failed property. Retiring Ruby removes the second outright and, **R**, hollows
the third, because the guard, mutation and role traces are produced by Ruby's interpreter. The corpus
survives, but its `expect` was seeded from the Ruby runtime (**R**), so it encodes Ruby's behavior as
reviewed; it is a fixed set, not a generator of new cases.

Layers, strongest first, with what each cannot catch:

1. **The frozen corpus** (`expect` + `docs/semantics`). Judges known cases. Cannot find a case nobody wrote.
2. **Metamorphic and model-based properties**, which need no second evaluator: a refused step leaves the
   store byte-identical; a dry run equals the real outcome and mutates nothing; replaying a session's
   journal into a fresh session gives the same instances; `snapshot` then `restore` is the identity; two
   sessions never share a store; a fact answer that is null refuses exactly when `needs` named it; the
   same seed gives the same history. All use only the serve protocol (**R**: sessions, snapshot, restore,
   dry run exist). Cannot catch a rule the kernel gets wrong in a self-consistent way.
3. **Static checks from the front end.** `Bluebook::ModelCheck` is already required by `properties.rb`
   (**R**); declared invariants and one_of sets are data in the IR. Evaluating them still needs an
   evaluator, so this layer is only independent for properties that read declared *shape* (sets, types,
   required) and not for expressions. **I**: the expression part has no independent judge once Ruby's
   evaluator goes; ADR 0188 step 2 ("one evaluator") makes that explicit, and the corpus `grammar/` set
   (**R**) is the only guard on it.
4. **Version differential**: the candidate kernel against the last certified kernel (the `edge` / `stable`
   build) on the same seeded sequences. The oracle for a *change* becomes "the old kernel", and every
   divergence must be explained by a corpus change in the same pull request. This is the replacement for
   the live Ruby oracle. It cannot catch a bug present in both, which is why layers 1 to 3 stay.
5. **Ruby until the gate says otherwise.** Keep the Ruby-vs-kernel differential running nightly until the
   retirement gate (slice 9) passes. That is ADR 0188 point 5 ("folded into the corpus *before* any
   engine is deleted").

**Rule I recommend:** a corpus `expect` is never seeded from the kernel it will judge (that is a
tautology). After Ruby stops running domains, a new `expect` is written by hand or from the `.behaviors`
file and reviewed; `seed_semantics_corpus!` stays pointed at the Ruby engine until then and is retired with it.
An owner decision, below.

## What a `.behaviors` file can replace, and what stays

Counts below are **R** from `grep` over `spec/**/*_spec.rb`: 224 of 623 spec files mention `Hecks.boot`,
`boot_files`, `boot_described` or `Runtime::Loader`. The split by directory is **R**; the verdict per class is
**I** until slice 7's census reads the files.

| Class | What it looks like | Verdict |
|---|---|---|
| Domain rule specs: boot a small bluebook, dispatch a few commands, assert event, state or refusal | the six ported in #1216 (**R**), PipelineBoard's rules (#1226, **R** log subject), most `spec/*_corpus_*`-style and per-example specs | **A `.behaviors` file replaces it.** The precedent is two commits old. Runs under the kernel for free once `Expectations.run_one(runtime:)` is given the client dispatcher |
| Corpus-shaped specs: a script of steps with frozen output | `conformance_corpus_spec.rb`, `rust_conformance_spec.rb`, `corpus_spec.rb` | **Stay as corpus JSON**, run by the simulation runner on the kernel; the per-domain cargo build in `rust_conformance_spec.rb` goes away after step 3 |
| Fuzz specs (42 files under `spec/fuzzing`, plus `rust_conformance_fuzz_spec.rb`, `qa_sweep_all_shrink_spec.rb`) | test the generator, shrinker and replay themselves | **Stay**; they spec the tool, and move to the engine seam in slice 1 |
| Ruby engine specs (`spec/runtime`, `spec/adapters/driven`, `spec/ports`) | test Ruby classes: the dispatcher, repositories, adapters | **Stay until step 6**, then delete with the engine. Not ported: nothing replaces them |
| Ruby adapter specs (git, GitHub, deploy, claude sessions, Heki, Sqlite, Postgres, Era) | an adapter's I/O | **Stay.** They test the code behind a port; a kernel does no I/O (ADR 0012). `:io` tagged (**R** about 210 files mention the tag; loose count) |
| CI and tooling specs (workflows, gate, train, landing, rehearsal, ruleset, release; most of the 36 `hecks_*` and 15 `qa_*` boot specs) | boot the tooling domains and check generated YAML, shell calls, git | **Stay.** Their subject is CI behaviour and the repo, not the domain semantics. A pure rule inside one (a Lane, a RequiredCheck given) can move to a `.behaviors` file as #1226 did, one at a time |
| Driving adapter and Rails specs (`spec/driving*`, `packages/hecks-rails/spec`) | Ruby doors over a runtime | **Stay**; they move to the client dispatcher under `kernel-client-driving`, not to behaviors |
| `:generated_all` | **R** exactly two files carry the tag: `spec/corpus_rust_spec.rb` and `spec/ci_pipeline_projection_spec.rb` | **Stay** in the drift job until step 3 stops committing `rust/src/generated`; then **delete**, not port. They assert the generated tree is bucketed correctly; there is no tree afterwards |

**Gap:** a `.behaviors` file cannot yet say "run under the kernel" or "under both". The runner boots Ruby only
(**R** `Boot.runtime_for`). Slice 6 adds an engine choice, not a new keyword in the DSL if it can be avoided.

## The callback problem a simulation must handle (R + I)

**R** ADR 0189: a dispatch that asked a callback "is not replayable from its journal alone" and
journaling of answers "is not part of this slice". A seeded sequence that reaches a `needs` fact asks
the host for `now`. The runner must therefore (a) answer from a clock the seed owns, never the wall clock,
and (b) record each answer next to its step, so a finding replays and shrinks. **I**: the corpus step shape
(`verb`, `args`, `role`, `actor_id`) has no field for it; a `facts` key on the step is the smallest change.
It touches the corpus format, so Ruby and Rust parsers must agree (`check_conformance`).

## Slices

Where areas overlap the items are ordered. 1, 2, 3 touch `lib/hecks/fuzzing/` and run in sequence; 5 and 6 are
disjoint from 3 and 4 and may run beside them once 1 has landed.

| # | Slice | Outcome | Area | Depends on | Gate | Who |
|---|---|---|---|---|---|---|
| 0 | **Decide the oracle** | an ADR: the layers above, the "never seed from the judged kernel" rule, the retirement gate (slice 9) | `docs/decisions/` | none | owner accepts | owner decides; architect drafts |
| 1 | **The engine seam** | `Fuzzing::Engine` with `RubyEngine` (today's `Replay`, unchanged) and `KernelEngine` (a `KernelClient` session per sequence: `open`, steps, `instances`, `close`). Both return the same history hash for what the wire carries | `lib/hecks/fuzzing/replay*`, `lib/hecks/rust_build/` | `kernel-client-pizzas` | a twin spec: for every `spec/corpus/*.json` the two engines give equal wire views (the six `WireComparison` fields) | coder |
| 2 | **Differential over serve** | `Differential.diff` takes an engine, not a binary on stdin; the per-domain `Open3` batch path stays as a fallback behind the same call until step 3 | `lib/hecks/fuzzing/differential*` | 1 | the existing fuzz specs (`rust_conformance_fuzz_spec.rb`) green with the engine swapped; seeded divergence still found | coder |
| 3 | **The generator on the kernel** | `SequenceGenerator` builds a sequence through an engine; its outcome tracking reads whatever engine answers. The clock for `needs` facts comes from the seed, answers recorded on the step (`facts`) | `lib/hecks/fuzzing/sequence_generator*`, corpus step shape | 1 | same seed gives the same step list on either engine for every in-repo domain, or the difference is reported as a finding, not hidden; corpus parsers agree on `facts` | coder |
| 4 | **The shrinker on sessions** | `Simulation.shrink` runs each candidate in a fresh named session of one warm kernel instead of a new process; the shrinker itself is untouched | `lib/hecks/fuzzing/shrinker*` (call site only) | 1 | a known seeded divergence shrinks to the same minimal steps as today, in no more candidates; time per candidate is reported | coder |
| 5 | **Census of the properties** | each of the 24 `properties/` files sorted into: (a) pure over wire history, (b) re-runs Ruby's interpreter or reads `runtime`, (c) reads Ruby-only traces (reactions, outbox, policy dispatches, cross-domain); written to this directory as a table. Read-only | `docs/plans/` | none | table covers all 24 files and the replay traces | coder (research) |
| 6 | **Oracle-independent properties** | class (b) and (c) from slice 5 are rewritten as metamorphic properties (layer 2) that use only serve; the wire shape grows only where a property needs a field the kernel already computes (reactions, sagas) | `lib/hecks/fuzzing/properties*`, `replay/*` traces, `rust/src/kernel/cli.rs` for any new field | 5, 1 | each rewritten property still fails on a planted bug (the mutation harness in `fuzzing/mutation` is the planter) | coder; the wire fields go through the contract owner |
| 7 | **Behaviors on the kernel** | `Expectations.run_one` takes the client dispatcher; `Boot.runtime_for` chooses the engine (`HECKS_ENGINE`, shared with the client plan); the Memory-only refusal stays | `lib/hecks/behaviors/` | `kernel-client-surface` | all 34 `.behaviors` files pass under both engines; an engine-only difference is a named list that shrinks | coder |
| 8 | **Census, then port** | run the class table above over the 224 files, as a table with a verdict per file; port the "domain rule" class to `.behaviors` in batches of six, each batch deleting its spec and keeping the domain's own bluebook | `spec/`, domain `bluebook/` dirs | 7 | each batch: the ported behaviors pass in both engines and the spec count falls by the batch | coder |
| 9 | **CI leg and the retirement gate** | a `simulate` job in a Rust job that holds the cargo cache (never a Postgres io shard); runs corpus, behaviors and N seeds per domain on the kernel and the version differential against `edge`. The retirement gate: Ruby-vs-kernel differential and version differential both show no unexplained divergence for the agreed run of nightly sweeps | `.github/workflows` via the generator, `lib/hecks/fuzzing` | 2, 3, 4, 6, 7 | CI stays under three minutes (CLAUDE.md "Keep CI under three minutes"); the gate is read from `nightly-main.yml`, not from a push run | coder for the leg; the gate number is the owner's |

`kernel-client-specs` (already open) is a CI leg for booted-domain specs; slice 9 shares its workflow area with
it, so they are ordered, not parallel: that item first, then this leg joins it. Slices 1 and 7 depend on
`kernel-client-pizzas` and `kernel-client-surface` and cannot start before they land.

## Risks

1. **The oracle gap is real, not procedural.** Layers 2 and 4 catch drift and self-inconsistency. A rule
   both kernel builds get wrong the same way passes everywhere once Ruby is gone. Mitigation is only
   more corpus. Stated so it is not mistaken for solved.
2. **Properties that judge Ruby with Ruby** (**R**). Until slice 6, switching the fuzzer's engine to the kernel
   makes those traces come from Ruby anyway, so the run is half-Ruby. Slice 1 must say which properties
   were run on which engine in its report.
3. **The generator reads outcomes from Ruby** (**R**). If slice 3 slips, the "simulation on the kernel" is
   Ruby deciding the next step and the kernel replaying it. That is still the differential, not a new test.
4. **Determinism through callbacks.** A wall-clock answer, a map iteration order or an unseeded id makes a
   finding that cannot be replayed (**R**, ADR 0189). The same-seed-same-history check in slice 3 is the guard.
5. **Latency of a finding loop.** **I**: per-candidate sessions (slice 4) should beat a process each; unmeasured.
   The ADR 0188 baseline (12 us vs 186 us a dispatch, **R**) suggests it, but shrinking is I/O on the pipe.
6. **Corpus drift while two runtimes exist.** A new corpus case seeded from Ruby encodes a Ruby bug as
   truth. Review is the only guard today; the oracle rule above removes the cause after retirement.
7. **Step 3 dependency.** Until the kernel loads a domain from IR, every simulation needs a per-domain
   cargo build (**R**), and the CI leg is expensive. Slices 1 to 4 work with that; slice 9 gets cheap only after step 3.
8. **Scope creep into `mutation`, `concurrent_dispatch`, `era_boundary`, `persistence_parity`.** They need
   Ruby adapters, threads or eras. They are out of scope here and keep running in Ruby until their own
   steps (Memory only: 4, Postgres era: last in ADR 0188).

## Choices taken (owner said "your call", 2026-11-05)

These are my recommendations, taken as the plan's defaults. None is an accepted ADR: slice 0 still
writes them down for the owner to accept.

1. **Corpus after Ruby:** written by hand or from `.behaviors`, reviewed, never seeded from the kernel it
   judges. `seed_semantics_corpus!` stays on the Ruby engine until Ruby retires.
2. **Retirement gate:** 14 consecutive clean nightly sweeps, at double the current `SEED_BUDGET` per domain.
3. **Version differential baseline:** `edge`, the last kernel every required check passed.
4. **Simulation vocabulary:** the existing QualityControl/Fuzzing bluebook. If the coder finds it too
   large (not measured), splitting it out is a finding to report, not a reason to stop.
5. **Callback answers:** a `facts` key on the corpus step, with Ruby and Rust parsers held to it by
   `check_conformance`.
