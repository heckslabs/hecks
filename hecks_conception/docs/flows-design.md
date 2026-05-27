# User Flows — flagship design (resolved 2026-05-27)

From the design interview. A Flow is the bus's executable journey-unit.

## Core model
- Source of truth: declared `.flow` artifact (bluebook-shaped), git-diffable, the bus runs it. No runtime-record drift.
- Behavior vs Flow: a behavior is the isolated ATOM (one command, reset world, asserts a unit contract incl. rejections). A flow is the stateful MOLECULE — ordered, state threads step-to-step, crosses aggregates, composes sub-flows.
- Story owns flows: Story has_many Flow as REFERENCES to canonical flow artifacts (single source; never copies steps). UseCase aggregate retired. Story.Forward/Execute = run the story's flows.
- Placement: Flow is a FRAMEWORK/bus primitive; Planning is the first client. Bus-caller (orchestration) IN SCOPE this sprint — Flow.Run drives the bus generally; acceptance is one consumer.

## Steps & assertions
- Step kinds: command, query, include-subflow.
- State threading: declared identities (the flow declares the entities/refs it works on; steps reference them). Named output-capture only where a value is genuinely system-produced.
- Assertions: inline expect per step. A step passes only when its assertion holds, not merely exit 0. REUSE the holds_when predicate engine (same vocabulary as invariants/guards) — rich predicates without a new engine. Vocab: equality, includes, event-emitted, absence, count. (Depends on holds-when-parens-bug fix.)
- Composition: parameterized IncludeFlow — a sub-flow takes inputs, e.g. include onboard-story(ref: s). Reusable shared journeys.
- Narrative: structured actor + intent (As a <role> I <action> so that <outcome>).

## Execution
- Isolation: in-memory-only runtime per run (fastest; flows test behavior/events, not the persistence path). Clean by construction — the clean use case.
- CONSEQUENCE: NO self-reset steps. The sandbox is discarded after each run, so a flow never cleans up after itself (the Reopen->RemoveFromSprint tail we used against the live store vanishes). A flow expresses ONLY the journey it proves; teardown is the runtime's job. Sandbox boots EMPTY (optionally a declared seed); a flow arranges any state it needs via its own early steps / an included setup sub-flow (arrange-act-assert, where arrange is steps).

## Grammar (resolved)
- A `.flow` reads like .behaviors: `Hecks.flow "name" do ... end` with `story`, `actor`, `intent`, `subject <handle>, ref: ...` (threaded identity, repeatable).
- Step: `step "Aggregate.Command", args... do expect { <holds_when predicate> }; expect_event "E" end`. A bare step (no block) dispatches without asserting and does NOT count toward coverage.
- `expect { predicate }` IS the holds_when engine (same vocabulary as invariants/guards). Query steps assert on result rows: `expect { count == 2 }`, `expect { includes(ref: "x") }`.
- Per-step actor override: `as: "Operator"` (defaults to the flow `actor`).
- Composition: `include "sub-flow", story: s` — sub-flow re-declares its params, caller passes values (reads like a function call).
- Failure: halt WITHIN a flow at first failed step; run-ALL flows at suite level, report each pass/fail (no cross-flow halt). Fixes one-failure-halts-everything.

## Golden & lifecycle
- Golden captures: normalized bus event stream + per-step assertion outcomes. Normalize volatile fields (timestamps, UUIDs, inv ids). The artifact IS the run, frozen.
- Storage: git, beside the .flow artifact (diffs show in review).
- Lifecycle tie: Verify/MarkReady gate on flow-green; Approve (operator) FREEZES the golden — done = golden frozen.
- Bless: an intended change is accepted by re-Approve through the bus (re-captures + freezes new golden; audited).
- Regression: a done story's golden that now diffs auto-Reopens it + requests re-approval. The plan is a living acceptance net.

## Coverage & gates
- Verb-coverage is EMERGENT then FROZEN (mirrors the golden): the verbs a story covers are discovered AS you build flows — the flows ARE the coverage record (the commands+queries their steps dispatch-and-assert; bare unasserted queries do not count). NOT a hand-declared list.
- At Approve, the union of covered verbs FREEZES as the story's coverage contract (derived from its flows), alongside the golden. Human judges sufficiency at Approve; the bus guards it after.
- Coverage gap = after freeze, a change makes a new verb relevant but no flow asserts it -> surfaced like a regression -> reopen.
- Coverage map (flow <-> verb) doubles as the index for FAST incremental golden re-runs.
- Regression trigger: command-level via the coverage map — a change touching verb X re-runs only flows covering X. Fast local (pre-commit) + CI re-runs ALL.
- Anti-drift macrophage: every flow step phrase must resolve against the lexicon; every assertion must reference a real IR attribute — validated at author time.

## Sizing signal
- One flow per story is the healthy default. A SECOND flow raises a SOFT advisory (consider splitting) — a sensor, never a block.

## Sequencing
- Walking skeleton first: take done-is-done end-to-end through the whole pipeline (declare -> run -> assert -> golden -> regression-detect), then widen + add the gates.

## DSL: declared, not hand-coded (Path B - decided)
- Flow's DSL primitives (flow/step/subject/expect/expect_event/include/as) are NOT hand-coded in the Ruby+Rust parser. They are DECLARED via the meta-bluebook (f4) as a BEHAVIOR-SHAPED construct; the parser/IR/validator are GENERATED from that declaration (parser meta-shape / Futamura). Drift-free to the floor - the DSL is data, not code that can diverge from the spec.
- f4 (meta-bluebook DSL) is a CO-REQUISITE FOUNDATION, scoped concretely: declare the flow construct as a behavior-extension via the parser meta-shape. Flow is the FIRST real consumer of f4 (mirrors Flow-the-bus-primitive having planning as its first client). The kinship 'a flow is a kind of behavior' becomes the implementation lever: extend the existing behavior construct, ride its parser meta-shape, do not write a new parser.
- Resequenced walking skeleton: (0) flow-meta-construct - declare the flow construct via meta -> (1) flow-primitive - the flow DSL exists & parses -> (2) declare done-is-done.flow -> (3) run VERIFY -> (4) freeze golden on Approve -> (5) prove a change auto-reopens via golden diff.

## Level 3: the fixed point (decided) - bluebook defines languages, and itself
- The DSL foundation is a LANGUAGE WORKBENCH: a `Hecks.language "X" do ... end` definition declares a DSL whole (constructs, grammar, IR shape, validation), and the parser/IR/validator/dumper are GENERATED from it. Not 'add a construct' - 'define a language'.
- This generalizes a pattern already PROVEN narrowly here: hecksagon_parser_shape (generated parser) and byte-identical generated validators (the 2nd Futamura proof). Level 3 makes it first-class.
- .flow is the FIRST declared language - small (behavior-shaped), real, useful. It proves the workbench before we aim it at anything bigger. The flagship flow feature ships ON the workbench.
- Fixed point: define bluebook IN bluebook (bluebook-self-host), generate the bluebook parser from that definition. Gated by fixed-point-gate: generated parser IR == hand-written IR, BYTE-IDENTICAL across the corpus (a diff fails). Same golden-diff machinery as the Flow golden - the feature and the fixed point share rigor.
- HONEST MAGNITUDE: Level 3 is a multi-sprint arc, research-grade. De-risking sequence: (a) workbench, (b) .flow as first citizen + the flow feature [this is already flagship], (c) bluebook-self-host, (d) byte-identity fixed-point gate. Do NOT let the fixed-point ambition delay (b) - .flow-on-the-workbench delivers the flagship even if (c)/(d) spill to a later sprint.

## The endgame: everything is bluebook (later epic)
- The workbench + fixed point generalize: EVERY hand-coded DSL (.hecksagon, .behaviors, .world, .fixtures) can be redefined AS a language-definition bluebook, parser generated.
- DEEPEST WIN: retires the parity apparatus at the root. Today each DSL has a Ruby parser AND a Rust parser kept in agreement by the 11 contracts + known_drift + the parity suite. Generated-from-one-definition => both parsers are projections of one source => parity is STRUCTURAL, not tested. The drift-detection machinery for parsers retires because the drift cannot exist.
- Migration is safe + incremental: one DSL at a time, each gated by byte-identity (generated IR == hand IR), retire the hand-parser only when its generated twin matches. Same golden discipline as flows + the fixed point.
- Scope: backlog epic (everything-is-bluebook), AFTER the Sprint-2 foundation. .flow + bluebook-self-host de-risk it.
