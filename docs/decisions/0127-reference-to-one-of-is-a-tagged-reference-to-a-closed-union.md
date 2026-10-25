# `reference_to one_of(A, B)` is a tagged reference to a closed union

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

A `reference_to` names one aggregate. A hold that can sit on an account or on a card, a
comment on a post or a photo, a charge against one of two ledgers: each needs a reference
whose target is one of a closed set of aggregates. ActiveRecord answers with a polymorphic
`belongs_to :subject, polymorphic: true`, which stores a type column beside the id and
names no closed set, so nothing checks that every reader handles every type.

The IR spells a reference's type `Reference<Customer>` and the self-hosted language replays
every bluebook through its `Aggregate.Reference` command, whose `points_at` resolves to one
declared head. A second spelling with several heads would need a list of references in the
meta-model and a new judge path, and it would change the wire format of every reader.

## Decision

1. **`reference_to one_of(Account, ATMCard), as: :subject`** declares a tagged reference on an
   aggregate. `as:` is required, since a union has no single name to derive one from, and the
   union names at least two distinct aggregates of the same chapter.
2. **It is built from words the language already has**, so no grammar row, IR key or judge
   path is added. The aggregate gains a closed set `SubjectType` whose members are the
   variants' names, and a value object `Subject` with `type` (a String that `admits:` that set)
   and `id` (a String). The attribute `subject` has type `Subject` and relationship `one_of`.
   `reference_to` with a `one_of(...)` argument is the one new reading, in the Ruby builder and
   in the Rust parser, and both mint the same IR.
3. **The value is stored as `{ type:, id: }`** and is queryable by type through a dotted
   field path: `where(:"subject.type" => "ATMCard")`. `admits:` refuses a type outside the union
   on both runtimes.
4. **The id must exist in the named aggregate.** After a command settles, each `one_of`
   reference is looked up in the repository of the aggregate its `type` names, and a missing
   record refuses `NotFound` with the same wording a plain reference uses.
5. **Model check holds every branch exhaustive** (`one_of_branch_unhandled`): when a command's
   `given` or a read model's `where` of the owning aggregate tests `subject.type` against a
   variant, every variant must be tested by some construct of that aggregate, or the check
   names the variants no branch handles.

## Alternatives considered

- **`Reference<Account|ATMCard>` as the type.** Rejected: the judge, the IR readers and the
  Rust parser all read a reference's type as one head; a union spelling would touch each of
  them and every era hash, for a meaning the value object already carries.
- **An open polymorphic reference (no closed set).** Rejected: without a closed set there is
  nothing to check a branch against, and a typo in the type column is a silent wrong answer.
- **A References chapter attached to `Aggregate`.** Not needed: the words exist (`reference_to`,
  `one_of`), and an attached chapter carries grammar rows, not a reading of an argument.

## Consequences

- `examples/banking` gains `Hold`, a hold placed on an account or an ATM card, and
  `HoldsOnCards`, a read model that filters holds by the type of their subject.
- Statements and the glossary say "points at one account or ATM card".
- A conformance-corpus case (`one_of_reference.json`) freezes the refusals and the stored
  shape both runtimes give.
