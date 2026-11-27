# `NestedPieces` — retention note

**Kept.** Two things new to the fuzzed corpus, both confirmed live, not
theoretical.

## 1. A genuinely nested entity — never fuzzed before

`EntityBuilder#entity_impl` has supported "a piece nested inside a piece"
since ADR 0026 (S17). The only place that shape is actually declared
anywhere in this repository is the language's own self-describing meta-
bluebook, `lib/hecks/language/bluebook/process_manager.bluebook`
(`entity "Handler"` containing `entity "Dispatch"`) — used for grammar
and glossary tooling, never booted as a real domain, never fuzzed. No
example (`pizzas`/`banking`/`chess`/`roster`/...) and no prior
`qa/stress_domains` entry (`ledger_ordering`) declares two real levels of
entity nesting. `NestedPieces` does: `Workspace` -> `Board` (entity) ->
`Card` (entity nested inside `Board`) — confirmed booting, dispatching,
and querying correctly two hops deep (`spec/nested_pieces_spec.rb`'s
first two examples).

## 2. BUG#3's fix (PR #526) confirmed to generalize two hops deep

`EntityElement#element_of` used to coerce an offered addressing identity
through its own declared type — invariant included — BEFORE ever
checking whether a stored element matches it, when that identity arrives
as a flat/legacy command ARGUMENT rather than through `to: { entities:
[...] }`'s own routing envelope (`to:` resolves via `routed_identity`, a
raw string comparison against `element_identity` — already immune before
the fix too, the same convention `Identity.from` already used for a root
aggregate's own identity; see `spec/nested_pieces_spec.rb`'s own comment
on the two confirmation tests for exactly why the addressing style
matters). A root-level identity riding a flat argument that failed its
own invariant used to raise `InvariantViolation` where Rust's own
generated `extract_wants` (a raw scalar read, never a typed rebuild)
always answered `NotFound`.

PR #526 fixed this GENERICALLY, inside `element_of` itself — which
`locate_chain` calls once per hop, so the fix should be hop-depth-
agnostic by construction. Nothing had ever actually exercised a second
hop to confirm that rather than assume it, until this domain.
`spec/nested_pieces_spec.rb` now pins both depths as passing regression
tests, post-merge:

- **Hop one** — `Board.Label` addressed by `number: { value: 0 }`
  (non-blank, so it reaches coercion; `BoardNumber`'s own "positive"
  invariant fails) against a board-less workspace. Same single-hop shape
  BUG#3 was originally found on `Banking::Account.LedgerEntry.Amend`,
  confirmed fixed in a new business shape.
- **Hop two — new evidence.** `Card.Annotate` addressed by `sequence: {
  value: 0 }` (`CardSequence`'s own "positive" invariant fails) against a
  card-less board, nested two levels under `Workspace`. This is the
  first domain to actually prove the fix reaches this depth, rather than
  assume it from the single-hop case.

**Not yet done — real follow-up, not a gap in this note**: Rust-side
confirmation, the same open item `ledger_ordering/NOTES.md` already
names for the identical reason (Ruby-only for now, matching that
domain's own precedent). Next real work against this Target: run `bin/
project_rust qa/stress_domains/nested_pieces`, then diff Ruby vs. the
compiled binary for both confirmation dispatches `spec/
nested_pieces_spec.rb` already exercises — both are now expected to
agree (`NotFound` on both engines) if PR #526's own Rust-side companion
work also landed; hop two additionally answers the NEW question of
whether a compiled binary even GENERATES for a two-level-deep entity
command at all (untested — the only precedent, `ProcessManager::
Handler.Dispatch`, is the framework's own bootstrap meta-bluebook, not
an ordinary generated domain, though `rust/codegen/src/commands.rs`'s
own `entity_command_skip_reason` comment confirms it is at least KNOWN
to compile for that one case).

## 3. BUG#4 — a genuinely new, unrelated finding, logged and paused

Running `bin/qa_sweep nested_pieces --seeds 40` (Ruby-only property/
exception mode — no compiled Rust binary for this domain yet, see above)
surfaces a real, reproducible property violation on seed 2:
`Hecks::Fuzzing::Properties#mutations_match_recompute` — an independent
single-engine check, so this is a Ruby-only correctness question about
the fuzz harness itself, not a Ruby/Rust divergence — flags `Board.
AddCard`'s own `sets :cards, append: { sequence: :sequence }` as wrong:
the real dispatch correctly stores `{ sequence: { value: 821 } }` (a
properly `Value`-wrapped `CardSequence`), but `recompute_append` (`lib/
hecks/fuzzing/properties/dispatch_and_mutations.rb`) independently
re-derives `{ sequence: 821 }` (a bare, un-coerced scalar taken straight
from the raw generated args) and reports a mismatch.

**This is a fuzz-harness bug, not a domain bug** — `Board.AddCard`'s own
dispatch is correct; `recompute_append` has no knowledge of the append
target's declared field TYPES (unlike the real interpreter, which
resolves the owning entity/value-object construct and runs each field
through `Value.for_attribute` before storing), so it only ever coincided
with the real shape by accident for the pre-existing corpus (every prior
entity-owned `:append` target field happened to be a bare scalar, never
itself value-object-typed). `CardSequence` being VO-typed — required for
`BUG#3`'s own invariant to exist at all — is what exposes it for the
first time; this looks structural to any future domain combining
"entity-owned `:append`" with "a VO-typed appended field," not specific
to `NestedPieces`.

Logged as `QualityControl::Bug` `BUG#4` (sweep
`SW-nested_pieces-1789010259`), investigated, and **paused** — real, but
touching shared fuzz-property-check infrastructure every fuzzed domain
relies on; a type-aware fix needs the owning entity/aggregate construct
threaded into `recompute_append` and real verification across the whole
existing fuzzing spec suite, more than this session's own scope. See the
Bug's own `investigate`/`pause` reasoning in the ledger for the exact
proposed next step. **The sweep stays open and the target stays held on
purpose** (`hecks_qa`'s own documented behavior on a surprising check) —
the next real sweep against `nested_pieces` should start from a human
decision on BUG#4, not blind re-fuzzing.

A speculative runtime fix (porting `MutationApplier#entity_element`'s
own auto-mint/collision-check fallback into `EntityElement#
appended_to_element`, which has no such fallback for a NESTED-ENTITY
append target — a real, separate gap this domain also surfaced, since
its own pre-existing header comment claimed "nothing in this language's
own `EntityBuilder` can declare a nested entity to need it," which is no
longer true) was drafted, verified not to regress the existing suite,
and then **deliberately reverted** before this PR: it does not resolve
BUG#4 (confirmed by re-running `bin/fuzz` before/after — identical
output), and `Board.AddCard` always supplies its own `sequence:`
argument, so the auto-mint/collision-check branches it would add are
unexercised by anything in this repository — an unverified runtime
change with no failing-test demonstration of its own is not something
this loop ships. Left as a genuine, real observation for whoever next
touches `EntityElement#appended_to_element`, not a logged `Bug` (no
reproducing failure to log).
