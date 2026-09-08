# Bluebook semantics

Clause-numbered, normative. This document — together with the corpus at
`spec/corpus/semantics/` — is the definition of what a Bluebook domain
means operationally. A runtime conforms when it answers every corpus
fixture as written; a fixture is correct when it follows these clauses.
Where a clause and an implementation disagree, the implementation is
wrong — including the Ruby one. This supersedes the tiebreaker role
[ADR 0010](../decisions/0010-ruby-is-the-reference-implementation.md)
gave Ruby: Ruby remains the *reference implementation*, but the
*reference* for meaning is this document and its corpus.

Two clause states:

- **Settled** — the rule is normative now; both runtimes conform (a
  corpus fixture pins it where one exists, named beside the clause).
- **OPEN** — the behaviour is currently implementation-defined; the
  clause records what happens today and what question a future decision
  PR must answer. An OPEN clause becoming settled is its own change,
  with its own fixture, never a silent edit.

Scope: the semantic core — `dispatch(S, C, env) → outcome`. Persistence
mechanics, transports, adapters, HTTP, eras and migrations are outside
it, except for one law they must uphold (C8.4).

## §1 The dispatch pipeline

- **C1.1 (settled)** A command dispatch runs the sixteen steps of
  `Vocabulary::AggregateDispatchOrder`
  (`lib/hecks/language/bluebook/vocabulary.bluebook`), in that order:
  refuse_unknown_arguments, refuse_absent_arguments, normalize_args,
  refuse_role_mismatch, resolve_references, hydrate, enforce_givens,
  admissible_transition, assign_creation_attributes, apply_mutations,
  advance_lifecycle, delegate_to_entity, enforce_ensures,
  enforce_invariants, save, emit. Entity commands run
  `EntityDispatchOrder` the same way.
- **C1.2 (settled)** Which refusal a caller sees is decided by step
  order: an unknown argument outranks a type mismatch, which outranks a
  role mismatch, which outranks not-found, which outranks an unmet
  given, which outranks a blocked lifecycle transition.
  (fixture: `refusal_order.json`)
- **C1.3 (settled)** Within one step, rules are checked in declaration
  order and the first failure refuses; later rules of that step are not
  evaluated. (fixture: `given_first_failure_wins.json`)

## §2 Rules and name resolution

- **C2.1 (settled)** A rule (given, ensures, invariant, precondition,
  policy `where`) is its structured `ast` — the `"op"`-tagged tree
  every IR rule row carries. `canonical` is the display form; a
  conforming runtime never derives behaviour from the text. The op
  roster is closed (`AstJson::OPS`, 28 ops); an unknown op is a
  malformed domain, refused at load, never guessed at.
- **C2.2 (settled)** A bare name resolves against the command's
  arguments first, then the subject's state; an unknown head is an
  evaluation fault (C8.3), not "false". `parent`, `old` and correction
  bindings are ordinary heads injected by the step that defines them.
- **C2.3 (OPEN — argument shadowing)** Because arguments shadow state
  (C2.2), an `ensures` naming a field that is also a command argument
  reads the *argument*, not the settled state. Today: Ruby and Rust
  agree. The open question: should post-state rules resolve state
  first, or should the collision be refused at build?
- **C2.4 (settled)** `given` and the lifecycle `from:` guard observe
  the pre-dispatch state; `ensures` observes the candidate state plus
  `old` (the pre-dispatch state, always); aggregate and entity
  invariants observe the candidate state with no argument scope.
- **C2.5 (settled)** Reference-typed *arguments* are dereferenced (to
  depth 4) before givens run; reference-typed *stored fields* are never
  dereferenced in rules — cross-aggregate reads go through declared
  `projects` copies (ADR 0025 S12).

## §3 Values

- **C3.1 (settled)** The value domain is: strings, integers, floats,
  booleans, nil, lists, value objects (typed field products), and
  entity elements. There is no symbol type on the wire: a conforming
  runtime treats the IR's JSON as the value shape.
- **C3.2 (settled)** Numeric comparison is by value across integer and
  float (`1 == 1.0`); ordering (`<`) is defined for two numbers or two
  strings and is otherwise an evaluation fault.
  (fixture: `numeric_int_float_compare.json`)
- **C3.3 (OPEN — integer width)** Ruby integers are unbounded; the Rust
  kernel refuses on checked i64 overflow. The open decision: Integer =
  signed 64-bit with overflow as fault, everywhere. Until settled, no
  conforming domain may rely on values beyond ±2^63-1.
- **C3.4 (OPEN — floats)** Floats are IEEE doubles. NaN and infinities
  are refused at value-object boundaries but unguarded for bare
  attributes; comparison algebra makes `NaN > 1` true. The open
  decision: refuse non-finite floats at every boundary.
- **C3.5 (settled)** Value-object equality is structural and
  type-tagged: same type, same fields. List equality is ordered and
  structural. `nil` equals only `nil`; `nil` never satisfies `<`/`>`
  (fault, C8.3). (fixture: `nil_equality.json`)
- **C3.6 (OPEN — strings)** Length counts characters; ordering is
  host-collation today. `.match?` accepts the host regex dialect while
  attribute `pattern:` is held to the portable `PatternSubset`. The
  open decision: hold `.match?` to `PatternSubset` too, and define
  ordering as codepoint order.
- **C3.7 (settled)** Declared value-object arguments are coerced and
  validated (type, closed set, `admits`, `pattern`, VO invariants)
  before givens run; a mismatch is `TypeMismatch`, a refusal.
  (fixture: `vo_argument_type_refused.json`)
- **C3.8 (OPEN — bare primitives)** A bare-primitive attribute
  (`attribute :count, Integer`) is not type-checked at the boundary
  today, so ordinary caller input can reach rule evaluation as the
  wrong type and fault (C8.3). The open decision: type-check every
  declared argument, making wrong-typed input a `TypeMismatch`.

## §4 Effects

- **C4.1 (settled)** The effect vocabulary is closed: `set`, `append`,
  `remove`, `increment`, `decrement`, `multiply`, `clamp`, `delegate`,
  `corrects` — plus the implicit lifecycle transition (§5). There is no
  arbitrary-code effect and never will be.
- **C4.2 (OPEN — ordering model)** Today effects apply sequentially in
  declaration order, each reading the intermediate state, and two
  writes to one field mean last-wins. The open decision (the plan's
  recommendation): an update set evaluated against the pre-dispatch
  state, applied atomically, with duplicate targets refused at build.
  No corpus domain distinguishes the two today; a fixture must pin the
  choice when it lands. Until then no conforming domain may write one
  field twice in one command or read a field it wrote earlier in the
  same command.
- **C4.3 (settled)** `append` adds one element at the tail; list order
  is append order. `remove` removes every structurally-equal element.
  Entity `append` refuses a duplicate identity (`AlreadyExists`).
  (fixture: `remove_all_matches.json`)
- **C4.4 (settled)** `increment`/`decrement`/`multiply`/`clamp` are
  numeric; an absent target reads as 0; a non-numeric operand is
  `TypeMismatch`.
- **C4.5 (OPEN — entity identity minting)** An appended entity with no
  explicit identity is minted `list size + 1`, which can collide after
  a `remove`. The open decision: an IR-declared minting strategy.

## §5 Lifecycle

- **C5.1 (settled)** A lifecycle declares a field, a required initial
  state, and transitions. The transition fires implicitly after
  effects; a command's `from:` is a pure guard checked with the givens;
  a transition's `from:` restricts firing, first matching transition
  wins; a transition with no `from:` fires from any state. An
  inadmissible state is `LifecycleRefused`.
  (fixture: `lifecycle_from_guard_refused.json`)
- **C5.2 (settled)** A fresh or loaded record without the field holds
  the declared initial state.
- **C5.3 (OPEN — bypass and validation)** `sets` on the lifecycle field
  is accepted today and then overwritten by any transition; a `from:`
  naming an undeclared state is never refused; duplicate transitions
  for one command are silently first-wins. The open decision: refuse
  all three at build.

## §6 Postconditions and invariants

- **C6.1 (settled)** `ensures` runs after every effect (lifecycle and
  delegation included) against the candidate; failure is
  `EnsuresNotMet` and nothing commits. (fixture:
  `ensures_old_denotes_prestate.json`)
- **C6.2 (settled)** Aggregate invariants, then every entity element's
  invariants (recursively), run against the candidate after `ensures`;
  failure is `InvariantViolation` and nothing commits — no state, no
  events. (fixtures: `invariant_refused_events_dropped.json`,
  `entity_invariant_on_candidate.json`)
- **C6.3 (OPEN — VO invariants at load)** Value-object invariants run
  at construction — which today includes re-validation when a stored
  record is *loaded*, so tightening an invariant can make old records
  unreadable. The open decision: construction-from-input only; stored
  state is trusted, migration is the era system's job.

## §7 Events

- **C7.1 (settled)** An accepted command emits exactly its declared
  events, in declaration order; each payload is the coerced command
  arguments. Event order across a dispatch is semantic.
- **C7.2 (settled)** A refused or faulted command emits nothing and
  records nothing — including events from a delegated entity command
  whose parent later refuses. (Ruby currently violates the delegated
  half: `step_delegate_to_entity` records events before the parent's
  ensures/invariants/save. That is a bug against this clause, tracked
  for its own fix; the fixture lands with the fix.)
- **C7.3 (settled)** `occurred_at` is environmental (C9.1), not part of
  the semantic payload.

## §8 Outcomes

- **C8.1 (settled)** A dispatch has exactly one of three outcomes:
  **accepted** (candidate committed, events emitted), **refused**
  (a domain refusal: state and event history exactly as before), or
  **fault** (the domain or its input is broken in a way the language
  refuses to interpret).
- **C8.2 (settled)** A refusal has a class — one of the
  `Vocabulary::DomainRefusal` names — and a message derived from the
  refusing rule's description. The class is semantic; the corpus
  compares it. Wording templates are shared, but prose is not the
  contract — the class and the refusing site are.
- **C8.3 (OPEN — faults)** An evaluation fault (unknown name, nil
  ordering, wrong-typed operand reaching an operator) is today a raised
  `EvaluationError` in Ruby (escapes dispatch) but a `TypeMismatch`
  *refusal* in the Rust kernel — a live accepted/refused/fault
  disagreement. The open decision: fault is its own outcome, never a
  refusal; with C3.8 settled, no ordinary caller input can cause one.
- **C8.4 (settled)** The one law the persistence boundary owes the
  semantics: commit is all-or-nothing — a dispatch's state change and
  its events become durable together or not at all.

## §9 Environment

- **C9.1 (settled)** `dispatch(S, C, env)` — everything outside S and C
  that can affect the outcome is part of `env`, and there are exactly
  four such inputs: the clock (`occurred_at`), the caller (role/actor
  for `refuse_role_mismatch`), the reaction depth, and the correction
  history (`corrects`). Identical (S, C, env) gives an identical
  outcome; nothing else (ordering of unrelated state, host hash order,
  process identity) may influence it.
- **C9.2 (OPEN — correction history)** `corrects` consults an
  in-process event log today, so a correction target emitted before a
  restart is invisible on Ruby (`NothingToCorrect`) while Rust keeps a
  persisted flag. The open decision: the flag-field model everywhere.

## §10 Reactions

- **C10.1 (settled)** Policies and sagas run after the triggering
  command commits, outside its atomic boundary; a refused or defective
  reaction never un-commits the trigger. A policy's `where` reads the
  event payload; unmet is a silent skip.
- **C10.2 (OPEN — ordering)** Ruby runs all policies then all sagas per
  announcement batch, in bluebook load order; the Rust kernel
  interleaves per event. The open decision: per event, in `emits`
  order — policies in declaration order, then sagas.
- **C10.3 (OPEN — saga leg selection)** `handler_for` selects the first
  handler matching the event *name*, so a second leg on the same event
  with a different `from:` state is unreachable. The open decision:
  select by (event, current state); ambiguity refused at build.
- **C10.4 (settled)** Reaction depth is bounded (5); a reaction beyond
  the bound is recorded undelivered, never run.

## Corpus contract

A fixture (`spec/corpus/semantics/*.json`) carries `steps` (the same
shape `spec/corpus/rust_conformance` uses), `spec` (the clauses it
pins), and `expect`: ordered refusals with **kind**, the final
instances, and the ordered events. Expectations were seeded from the
Ruby runtime once (`bin/seed_semantics_corpus`), reviewed against these
clauses, and are frozen — a runtime change that breaks a fixture is a
semantics change and must say so here, in the clause, first.
`spec/semantics_corpus_spec.rb` runs every fixture against the Ruby
runtime; the io-tagged half runs the same fixtures against the compiled
Rust kernel, refusal kinds included.
