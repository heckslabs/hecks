# A process manager has one name in the language and the runtime

**Status:** Accepted (owner, 2026-11-02): saga. Date: 2026-11-02. Found by the ubiquitous-language
survey of the same day; Tickets finding `ul-saga-vs-process-manager`. This record laid out both sides
and recommended process manager; the owner picked saga, and the language slice is built.

## Context

The thing a domain declares to coordinate several aggregates over time has two names.

**The language says process manager.** The bluebook keyword is `process_manager`
(`lib/hecks/hecks/deliver/deliver.bluebook`, `lib/hecks/quality_control/quality_control.bluebook`).
The language context declares it as the aggregate `ProcessManager`
(`lib/hecks/language/bluebook/process_manager.bluebook`), with `ProcessManagerName` and
`ProcessManagerText`. The `hecks` CLI and its help say process manager.

**The runtime says saga.** The same bluebook gives `ProcessManager` its states as `SagaState` and
emits `SagaDeclared` and `SagaStateAttached`. The interpreter is `Runtime::SagaInterpreter`
(`lib/hecks/runtime/saga_interpreter.rb`); the pending dispatch is `saga_pending_dispatch.rb`;
the store is `saga_persistence.rb` with `save_saga` and `NULL_SAGA_STORE`; the boot rule is
`SagaDurabilityRule`; the Rust kernel's `saga_log` is byte-compared in the differential specs. The
word appears in over a hundred Ruby files against about half that for `process_manager`.

**The decisions say saga.** [ADR 0169](0169-time-reaches-a-saga-as-a-command-an-inbound-clock-dispatches.md)
and [ADR 0170](0170-saga-state-is-as-durable-as-the-aggregates-it-coordinates.md), accepted by
the owner on 2026-11-02, both carry the word in their titles, and both describe the `process_manager`
keyword in their text. The two words are used as synonyms inside single sentences.

In the literature they are not synonyms. A *saga* (Garcia-Molina and Salem, 1987) is a sequence
of local transactions with a compensating transaction for each, so that a failure part-way is
undone by running the compensations in reverse. A *process manager* (Hohpe and Woolf, 2003) is a
stateful coordinator that receives events and decides which command to send next; it may run a
saga, and it may do things a saga does not, such as wait for time or correlate by a key. Hecks's
construct has `correlates_by`, `starts_on`, `ends_on`, `resumes`, `transition`, `dispatch` and
`compensates`: it is a process manager that can also compensate, which is the usual shape.

## Decision

**The word is saga.** It is what the runtime, the stores and the two newest decisions already say,
and it is the word the DDD community uses for this construct. The record's recommendation was
process manager, as the broader term; the owner chose the shorter one. The language moves to the
runtime's word; the runtime does not change.

The rule that follows is the one ADR 0103 set for "door": one word in the code, the bluebooks and
the live docs; dated records keep what they said.

The renames, in two slices:

| Today | Becomes | Slice |
|---|---|---|
| keyword `process_manager "Name" do` | `saga "Name" do`; `process_manager` refused by name, answered only under shadow-parsing for frozen era text | built |
| aggregate `ProcessManager` (`lib/hecks/language/bluebook/process_manager.bluebook`) | `Saga` (`saga.bluebook`); keyword rows carry `was: "process_manager"` | built |
| `ProcessManagerName`, `ProcessManagerText` | `SagaName`, `SagaText` | built |
| `DSL::ProcessManagerBuilder` | `DSL::SagaBuilder` | built |
| Rust parser keyword and context `"ProcessManager"`; `parse/process_manager.rs` | `"saga"`, `"Saga"`; `parse/saga.rs` | built |
| `policies-and-process-managers.md`, `reference/process_manager.md` | `policies-and-sagas.md`, `reference/saga.md` | built |
| "process manager" in live docs, help text, comments | "saga" | built |
| IR key `process_managers`; `ir::ProcessManager`; `Bluebook::ProcessManager` and its `Behaviour` | `sagas`; `ir::Saga`; `Bluebook::Saga` | open: Work `saga-internal-identifiers` |
| saga stores' `process_manager` column (`hecks_saga_instances`, `hecks_lambda_sagas`) | kept: a column rename is a shape move under ADR 0133's seals, and the column already lives in a table called sagas | kept |
| ADR 0169 and 0170 titles | kept, as dated records; a note under each says the word was settled here | built |

## Consequences

- A breaking grammar word, planned for 8.0.0 beside ADR 0163's: every client bluebook that
  declares one (`process_manager "…" do`) writes `saga` when it takes the bump. Work
  `saga-client-sweep` names lifeadelics, emaho and miette2.
- Frozen era text that still says `process_manager` keeps booting, because the DSL answers the old
  word under shadow-parsing, the way `report` still answers for `read_model`.
- The IR key `process_managers` and the Rust `ir::ProcessManager` are the one spelling left in
  code. They are compared byte-for-byte between Ruby and Rust and read by the kernel, the codegen
  and the host, so they move in their own slice, both sides at once, with the goldens regenerated.
- Custom persistence adapters are untouched: `save_saga` already carried the chosen word.

## Open question

- Whether `compensates` deserves its own noun once the construct is a process manager throughout.
  Today a compensation is a dispatch with a direction; if a compensation run needs an identity to
  report on, "saga" is free for it.
