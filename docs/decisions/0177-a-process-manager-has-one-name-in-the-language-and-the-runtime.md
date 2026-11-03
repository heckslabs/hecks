# A process manager has one name in the language and the runtime

**Status:** Proposed. Date: 2026-11-02. Found by the ubiquitous-language survey of the same day;
Tickets finding `ul-saga-vs-process-manager`. The choice in the decision is the owner's; this
record lays out both sides and recommends one.

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

The owner picks one word. Both ways are laid out so the pick is a pick, not a search.

**Recommended: process manager.** The keyword a domain author writes is the ubiquitous language,
and the author writes `process_manager`. It is the broader term and the one that matches what the
construct does: coordinate, correlate, wait, and sometimes compensate. "Saga" then survives in one
place, as the name for the compensation path (`compensates`, and a future `SagaRun` if a
compensation run gets an identity), which is what the word meant to begin with.

Under this choice the renames are:

| Today | Becomes |
|---|---|
| `SagaState` | `ProcessManagerState` |
| `SagaDeclared`, `SagaStateAttached` | `ProcessManagerDeclared`, `ProcessManagerStateAttached` |
| `Runtime::SagaInterpreter` | `Runtime::ProcessManagerInterpreter` |
| `saga_pending_dispatch.rb` | `process_manager_pending_dispatch.rb` |
| `saga_persistence.rb`, `save_saga`, `NULL_SAGA_STORE` | `process_manager_persistence.rb`, `save_process_manager`, `NULL_PROCESS_MANAGER_STORE` |
| `SagaDurabilityRule` | `ProcessManagerDurabilityRule` |
| `saga_log` (Ruby and Rust) | `process_manager_log` |
| ADR 0169 and 0170 titles | kept, as dated records; a note under each says the word was settled by this ADR |

**The other way: saga.** It is shorter, it is what the runtime and the two newest ADRs say, and
the DDD community uses it loosely for exactly this construct. Under this choice the keyword
`process_manager` becomes `saga`, `ProcessManager` becomes `Saga`, the `ProcessManager*` value
objects follow, and the old keyword is refused by name. The language changes; the runtime does not.
The cost is a breaking grammar word in every client bluebook that declares one, and a word that
says less than the construct does.

Either way, the rule that follows is the one ADR 0103 set for "door": one word in the code, the
bluebooks and the live docs; dated records keep what they said.

## Consequences

- Under the recommendation: no client bluebook changes. The runtime renames are internal, except
  `save_saga`, which a custom persistence adapter implements; that adapter keeps working under its
  old name for one era with a deprecation refusal that names the new one.
- Under the alternative: a 7.0.0 grammar change beside ADR 0163's, refused by name.
- The differential specs that compare `saga_log` between Ruby and Rust rename their fixture key
  in both at once.

## Open question

- Whether `compensates` deserves its own noun once the construct is a process manager throughout.
  Today a compensation is a dispatch with a direction; if a compensation run needs an identity to
  report on, "saga" is free for it.
