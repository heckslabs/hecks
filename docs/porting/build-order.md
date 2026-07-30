# A staged build order, with checkpoints

`bin/parity` (`docs/porting/conformance-kit.md` §3) is all-or-nothing — it needs a substantially
complete runtime before it produces any signal at all. Building blind until everything compiles is
a bad way to get feedback. This is a suggested staged path instead: build one layer, check it
against an already-existing artifact, then move to the next.

Persistence adapters are **out of scope for this kit by design** — bring your own, or bring one over
from elsewhere. "If the bluebook runs correctly, that's a real win" on its own; nothing below depends
on a specific storage engine, and every checkpoint here can run entirely in-memory.

## Stage 1 — Parser → IR

Parse `.bluebook` source into the IR shape documented in `conformance-kit.md` §1.

**Checkpoint:** produce byte-identical (after key-sorting) IR for a known `.bluebook` source,
compared against `spec/golden/ir/*.json`. Start with `Pizzas.json` — it's the smallest, and exercises
attributes, commands (both `set` and `append` mutations), a lifecycle, and non-closed value objects
without needing entities, policies, process managers, or read models yet. `Banking.json` and
`Meta.json` exercise closed-set value objects (`members`), entities, and cross-aggregate references
— useful once the basic shape is solid.

## Stage 2 — Expression evaluator/resolver

Build the predicate sublanguage against `grammar.md`'s two grammars (outer boolean/comparison, inner
arithmetic/dotted-lookup). Embed `rust/src/bluebook/expression/operators.json` directly for the
comparison algebra rather than re-deriving `Vocabulary::Comparison`'s table by hand.

**Checkpoint:** port the case list in `spec/expression_spec.rb` — every literal, every operator,
every sign test, arithmetic, `.size`/`.empty?`/`.to_s`/`.modulo`, precedence, and error-message case
it covers (skip its two AST-cache-identity tests specifically — those test an internal
Ruby-implementation caching detail, not a spec requirement). `rust/src/bluebook/expression/tests.rs`
and `evaluator.rs`'s own test module are the same case list from the other side, useful for
double-checking a case `expression_spec.rb`'s prose doesn't make obvious in isolation. Error message
text is part of the contract (`conformance-kit.md` §3) — match it exactly, not just the pass/fail
verdict.

## Stage 3 — Command/entity dispatch

Build dispatch against `behavior-notes.md`'s reference-resolution, domain-refusal, and
dispatch-order sections. Embed `rust/src/runtime/mutation_ops.json` for increment/decrement sign
rather than re-deriving `Vocabulary::MutationOp`'s table.

**Checkpoint:** trace a real dispatch and confirm it visits steps in the order
`Vocabulary::AggregateDispatchOrder`/`EntityDispatchOrder` declare (both existing runtimes have a
`trace`/`dispatch_trace` mechanism for exactly this — `behavior-notes.md`'s dispatch-order section).
Confirm `DomainRefusal`'s seven members (`GivenNotMet`, `InvariantViolation`, `LifecycleRefused`,
`NotFound`, `TypeMismatch`, `UnknownArgument`, `UnknownVerb`) are each reachable and each distinct
from an actual runtime crash — this is the single easiest place for a new implementation to
accidentally let a bug wear a refusal's clothes, or vice versa (`behavior-notes.md`'s "domain refusal
vs. runtime crash" section documents the exact bug shape to watch for).

## Stage 4 — Query

Build query evaluation against `behavior-notes.md`'s query-comparator-semantics section.

**Checkpoint:** `Vocabulary::QueryComparator`'s eight members (`eq`, `ne`, `gt`, `gte`, `lt`, `lte`,
`in`, `contains`) each behave per spec — especially the `in`/`contains` array-or-CSV convention,
already independently reimplemented four times across this codebase and worth getting right the
first time rather than rediscovering by trial and error against the parity corpus.

## Stage 5 — Full corpus

Run `spec/parity/*.json` end-to-end: dispatch every step in order, compare the full resulting
`{instances, events, refusals, reactions, sagas, queries}` output against a reference run
(`conformance-kit.md` §2-3 documents the exact shape and the byte-exact comparison rule). This is
the real, final gate — every checkpoint before it is a staged approximation of this one check, useful
for localizing a failure to a specific layer before the whole corpus has to agree.

A new implementation doesn't strictly need `bin/parity`'s shell-script machinery to do this — the
comparison it needs to reproduce is: run the script, canonicalize (sort JSON object keys, nothing
else), diff. Cross-reference against a reference run recorded from Ruby or Rust; nothing about the
comparison itself is specific to either language.
