# A finding is acknowledged on the declaration it excuses

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-28.

## Context

`model_check` reports findings that a model sometimes means: an aggregate larger than the
limit because one ledger holds every entry, a conformist that translates because its upstream
reads in the other's words. ADR 0137 item 6 decided the shape of an allowance and left it
unbuilt; ADR 0121 says an allowance belongs on its own declaration and not in a list kept apart
from it. This builds it.

## Decision

1. **An aggregate takes `acknowledges :kind, "reason"`.** The reason is required text. The
   kind must be one the check reports about an aggregate, and any other is refused when the
   bluebook is built, so an acknowledgement cannot outlive the check it answers. `:large_aggregate`
   is the first (ADR 0151 adds `:key_by_value` and `:orphaned_reference`). An aggregate that
   acknowledges it is not reported for size.
2. **A `.contextmap` relationship takes `acknowledges: { kind: "reason" }`.** The kinds are the
   findings about the relationship itself: `relationship_kind_mismatch`, `conformist_translates`,
   `unpublished_dependency` and `unused_relationship`. An undeclared coupling and a
   separate-ways breach have no relationship to carry the allowance, so they cannot be
   acknowledged; the fix is to declare the relationship or remove the coupling.
3. **A process manager's compensation does not count as a multi-aggregate write.** No check
   reports such a write (ADR 0137 item 2), so there is nothing for it to acknowledge. If one is
   ever added it reads a manager's forward steps only.
4. **The word is part of the IR.** An aggregate emits `acknowledgements: [{finding:, reason:}]`,
   empty when nothing is acknowledged. The language bluebook declares the word, the Rust parser
   reads and emits it, and the sentence form and Ruby renderer refuse an aggregate that holds
   one rather than drop it.

## Consequences

- Every frozen IR gains an empty `acknowledgements` list on each aggregate, and the `Bluebook`
  language's storage shape gains the field: an additive translation edge and a ledger move.
- The reason is text kept with the declaration, so a reviewer reads the allowance beside the
  thing it excuses.
- The sentence form has no phrase for an acknowledgement yet.
