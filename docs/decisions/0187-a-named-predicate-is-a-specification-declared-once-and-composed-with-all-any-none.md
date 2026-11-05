# A named predicate is a specification, declared once and composed with all, any and none

**Status:** Proposed (2026-11-04). Not built. No grammar change is accepted yet: the keyword question in
Decision 1 is open.

## Context

Hecks has three places where a business rule is written, and none of them can share a rule with the
others:

- **`given`** is a named precondition. Its description is the refusal message. It belongs to one command
  or aggregate. `declared_by:` disambiguates a bare reference when two aggregates share a description; it
  does not compose (`lib/hecks/bluebook/dsl/aggregate_builder/rules.rb`).
- **`QuerySpecification`** is a stand-alone object that composes where-clauses, but only for queries
  (`lib/hecks/query_specification/`). It does not express a business rule.
- **Process managers and policies** have `ends_on` (an event) and nothing that stops a loop by state.
  `docs/implemented/guides/policies-and-process-managers.md` says a policy's termination is whatever a
  `given` happens to bound.

The same fact is written out more than once. `given("customer is active") { parent.customer.status ==
"active" }` appears in full in `docs/implemented/resolution-rules/cross-entity-given.md` and
`bluebook-entity-given.md`. That copying is the drift the Specification pattern (Evans; Fowler) exists to
prevent: a named, stand-alone predicate that says whether a candidate satisfies a rule, usable for
validation, selection and query building.

ADR 0137 already says "a named `given` or precondition is a specification" and adds no keyword. That is
accurate for one command. It does not cover reuse, composition, or a rule used by a query or a policy.

## Decision

1. **Declare a specification as a top-level named predicate. (Open: keyword or `given`.)** Recommended:
   a new `specification` word, because the same predicate is used in four places (`given`, query
   `where`, policy or process-manager termination, read-model filter) and ADR 0025 says a word earns its
   place by being used. Alternative: extend `given` to take a named predicate with no new word. The
   alternative keeps the vocabulary smaller but ties a shared rule to a refusal message and an owner.

   ```ruby
   specification "CustomerIsActive" do
     about Customer
     satisfied { status == "active" }
   end

   specification "MayTransact" do
     about Customer
     satisfied { all(CustomerIsActive, none(CustomerIsClosed)) }
   end
   ```

2. **Combinators are functions: `all`, `any`, `none`.** Not `&`, `|`, `!`. They read like the existing
   DSL calls and avoid Ruby operator precedence on the closed grammar.

3. **A specification's body stays inside the closed expression grammar (ADR 0022).** That is what lets one
   specification compile to a runtime check, a query `where`, and a read-model filter. A specification
   that needs custom Ruby is refused by model_check when it is used in a query, a read model or a
   termination.

4. **Use sites.**
   - `given MayTransact.about(:customer)` in a command. The refusal message is the specification's name.
   - `where CustomerIsActive` in a query. It compiles to the same where-clause.
   - `stops_when RetryExhausted` on a policy or `ends_when TransferCompleted` on a process manager, next to
     the existing `ends_on`. `ends_on` stays for event ends.
   - A read-model filter by a specification.

5. **Specifications compose only with specifications.** A specification may name another specification
   in its body. It may not read another aggregate's state except through `about` and a reference the
   aggregate already declares.

## Consequences

- One definition of "customer is active" serves every command, query and termination that needs it.
  Changing it changes all of them, and model_check can list every use site.
- The four use sites each become a new consumer of the specification compiler. None of them exists yet.
- `QuerySpecification` stays the query layer. The new object compiles into it; it does not replace it.
- Termination by state is not termination by proof. A specification stops a loop only when the state it
  reads changes. The reaction-depth backstop (`Dispatcher::MAX_REACTION_DEPTH`) remains.

## Open questions

- Whether a specification needs `about` at all, or can be declared over a value that is passed in.
- Whether a specification may span two aggregates (Decision 5 says no, except through a declared
  reference).
- The keyword in Decision 1.

## Related

- ADR 0022: the closed expression grammar a specification body must stay inside.
- ADR 0025: a word earns its place by being used.
- ADR 0135: the context map; a specification does not cross contexts.
- ADR 0137: a named `given` is a specification; this ADR extends that.
