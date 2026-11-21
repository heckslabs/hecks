# Architecture review rubric

The `architect` agent reviews plans against these rules. Each has a number so a finding can cite it.
Change a rule here and the reviewer follows; the agent file holds no rules.
The lenses are D (domain-driven design), H (Hecks), X (hexagonal), M (Hecks modeling) and C (Hecks craft).

## D. Domain-driven design

- **D1.** One command changes one aggregate. A plan that changes two in one step needs a policy and
  an event between them.
- **D2.** Aggregates refer to each other by id, never by holding the other aggregate.
- **D3.** An invariant lives inside the aggregate it protects, not in a caller or an adapter.
- **D4.** Names are the domain's own words. A new name that the bluebook does not use, or a second
  name for something it already names, is a finding.
- **D5.** Commands are intents in the imperative; events are facts in the past tense. A command
  does not describe a fact, and an event does not ask for anything.
- **D6.** Contexts do not share aggregates. What crosses a boundary is an event or an id, read through
  the context map.
- **D7.** Every new fact has one owner. If the plan does not say which aggregate owns it, ask.

## H. Hecks

- **H1.** Rules live in the bluebook. An adapter measures and fetches; it decides nothing.
- **H2.** One adapter per port. Two adapters on one port fail at boot (`WiringError`); a plan that
  adds an adapter to an existing port must say which one it replaces.
- **H3.** Commands return ids for later calls. Context is read-only, never used for a write.
- **H4.** Records are append-only. A change is a new record that supersedes, not an edit.
- **H5.** Repository work goes through Hecks commands (`LinkedTree`, `Landing`, `SendTrain`, `ReviewRequest`), not raw
  `git` or `gh`. A step no command covers is said so in the plan.
- **H6.** Generated files (a `Generated ... do not edit` banner) are never edited; the plan names the
  generator or its source.
- **H7.** The changed domain passes `model_check`. A plan that adds to a domain says how it will be
  checked.

## X. Hexagonal

- **X1.** Dependencies point inward. The domain does not know an adapter exists.
- **X2.** The domain owns the port: its shape is what the domain needs, not what the outside offers.
- **X3.** An adapter is thin: facts in, facts out. A conditional on domain meaning in an adapter is a
  rule in the wrong place (H1).
- **X4.** The plan can be exercised without the outside world, through behaviors. Stand-ins stay out
  of the real wiring.
- **X5.** Few ports. A port per source or per purpose is too granular; purposes and sources are data.

## M. Hecks modeling

Each rule has a test (when it applies), a smell (what a finding quotes) and the construct to reach for.
Read the bluebook of the plan's area first and cite its nearest example.

- **M1. Sagas.** Test: a flow spans aggregates or waits on an outside event. Smell: policies chained by
  hand, a script, or a loop that carries the flow; a saga whose state is not persisted (no `save_saga`
  on its hecksagon, the `saga_durability` boot notice). Use a `process_manager` (ADR 0180), as
  `GateAndBoard` and `MainIntegration` in `lib/hecks/hecks/deliver/deliver.bluebook`, and bind a
  persistence adapter for it.
- **M2. Rich value objects.** Test: a primitive carries rules (an id, money, a duration, a mark, a pair).
  Smell: a bare `String` or `Integer` attribute, or the same validation repeated in adapters or
  commands. Use a `value_object` with `matches:` and `invariant` (ADR 0067), as `FindingKey` in
  `lib/hecks/tickets/bluebook/tickets.bluebook`.
- **M3. Queries.** Test: the plan reads state. Smell: a read hidden in a command, in adapter code or in
  ad hoc SQL. Use a declared `query` and a port that `answers_query` (ADRs 0040, 0061), as `ServerEnv`
  in `lib/hecks/agents/agents.bluebook`.
- **M4. Read models.** Test: a view answers a question across aggregates or over many rows. Smell: a
  polling watcher, or a script that boots the domain to compute a view. Use a declared `read_model`
  with `group_by` and a reduction (ADRs 0050, 0052, 0055, 0078, 0079), as `CiRunPassedByStatus` in
  `lib/hecks/ci_pipeline/ci_pipeline.bluebook`.

## C. Hecks craft

What an excellent bluebook and adapter look like. A rule that restates D, H or X adds only its test;
the older number wins on a tie.

- **C1. One boundary (D1, D3).** Test: can one aggregate say what it keeps consistent in a sentence?
  Smell: an aggregate that holds unrelated facts, or an invariant checked by a caller.
- **C2. Commands guard and emit.** Test: does each command state its `given` guards and the event it
  emits? Smell: a guard written in an adapter, a command that emits nothing, a command that reads for
  an answer (M3).
- **C3. Policies react, sagas coordinate.** Test: does a policy do one reaction to one event? Smell: a
  chain of policies carrying one flow (M1).
- **C4. Sentence-form language (D4, ADR 0131).** Test: does the bluebook read as plain business
  sentences? Smell: a second name for a thing the language already names.
- **C5. Bare arguments.** Test: a single-field argument is written bare, `name=value`. Smell: a
  `.value` suffix on a new example or brief (ADR 0067).
- **C6. Declared over hand-written (H1, H6, ADR 0154).** Test: can the bluebook or hecksagon say it?
  Smell: hand-written Ruby that a declaration would project; code left standing beside a domain that
  a projection should produce.
- **C7. A port for every outside dependency (X5, H2).** Test: does the plan touch a clock, file,
  network, store or process? Smell: that call made inside a bluebook or reached around its port.
- **C8. Thin adapters (X3).** Test: does the adapter only translate facts in and out? Smell: a
  conditional on domain meaning, a validation, or a default the domain should own.
- **C9. Asks match a port.** Test: every question the domain puts to the outside is declared by
  one port's `asks`, as the `Machine` port's `asks "Sweep"` in `lib/hecks/agents/agents.ports.hecksagon`.
  Smell: an ask the plan makes with no port `asks` declaration to match it.
- **C10. Behaviors first.** Test: the `.behaviors` file changes before the bluebook. Smell: a plan
  that adds a command or policy with no scenario.
- **C11. Read the best example.** Test: the review names the best existing bluebook and adapter of the
  plan's area. Smell: a new shape that ignores a neighbour already doing the same job; cite the
  neighbour.

## S. Size of the answer

- **S1.** A finding prefers removal to addition. When a gap can be closed by leaving the feature out,
  the finding says so first, and only then proposes a mechanism.
- **S2.** The verdict names the smallest version of the proposal that still meets its goal.

## V. Verdict

A review exists so a coder can build, not so a plan is perfected. Of 364 verdicts to 2026-11-15, 313 were
`changes`, 41 `rethink` and 10 `sound`, so nearly every item took a second round. A finding is one of two kinds.

- **Blocking.** Building the plan as written would break a rule below with evidence from the repo or a tool
  result, or would fail: a source that does not exist (D7, H1), two adapters on one port (H2), an invariant
  outside its aggregate (D3), a generated file edited (H6), a domain that will not pass `model_check` (H7),
  a dependency that points outward (X1), an ask with no port `asks` (C9), an outside dependency with
  no port (C7), a read inside a command (C2, M3).
- **Note.** Everything else: a name that could be the domain's own (D4), a smaller slice (S1, S2), a check
  the plan could add, a missing line of detail the coder can settle from the code (D5, D7 when one owner is
  obvious), wording, and the modeling and craft rules not named above: M1 to M4 and C4, C5, C10, C11
  are notes unless the plan would fail or break a rule with evidence. A note carries no evidence of failure. A missing owner or source with no obvious
  answer is the D7 case that blocks.

The verdict follows from the blocking findings alone.

- `sound`: no blocking finding. Notes ride along under a `Notes` heading, and the coder applies them while
  building. They are not sent back for another review.
- `changes` (written `sound with changes`): at least one blocking finding. Each says what to change.
- `rethink`: the goal is better met another way, so the plan as a whole is dropped. It is not a stronger
  `changes`.

**Measuring it.** `VerdictMix` counts the verdicts; the `Reviews` rows carry `requested_at`, so a day's mix is
those rows bucketed by `requested_at / 86400`, read from the main checkout (a worktree's store is empty). Baseline on 2026-11-15: 313 `changes` of 364. To sample, read the `Reviews` rows whose
verdict is `changes` and ask of each: did the coder's build differ from the plan as first written, because of a
blocking finding? A blocking finding the build ignored was a note, and the lines above are tuned to it. The goal
is `sound` as the common verdict on items the coder then lands unchanged.

A plan that names which aggregate owns each new fact and how it is checked is not sent back for detail.
When unsure whether a finding blocks, it is a note.

## Plan questions

- What is the smallest slice that answers the need, and does the plan stop there?
- Which port does each new outside dependency use?
- What does the plan leave out on purpose, and does it say so?
