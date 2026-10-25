# A reference to a record that ends needs a policy for its holders

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

ActiveRecord's `has_many :cards, dependent: :destroy` says, beside the association, what
happens to the children when the parent goes. Hecks has no such option and should not
grow one: there is no delete verb in the language, a record's life ends at a lifecycle
state, and what happens to other records when it does is a reaction, which the language
already states as a policy on the ending event (`for_each` over the holders' rows,
`trigger` a command on each).

What Hecks lacked was the check. A chapter could declare `reference_to Account` on
`ATMCard`, give `Account` a `closed` state nothing leaves, and say nothing about the cards
of a closed account. Nothing reported it.

## Decision

1. **`model_check` reports an `:orphaned_reference`** (`ModelCheck::OrphanChecks`, beside
   `ReferenceChecks`) for each holder X, each aggregate Y it references, and each way Y's
   life ends, when no policy on that ending acts on X's rows.
2. **An ending is a transition into an ending state**: a state the lifecycle reaches, that
   is not its default, and that no transition leaves. A lifecycle with an unconstrained
   transition can leave every state, so it has no ending. The ending's events are the
   ones its command emits; an ending whose command emits none is reported as such, since
   no policy could hear it.
3. **A policy acts on X's rows** when it is `on` one of the ending's events and its
   `for_each` query or its `trigger` command belongs to X.
4. **Only a holder that can itself end is checked.** A holder with no ending of its own (a
   statement, a receipt, a ledger line) is a record that outlives what it points at by
   design, and no command could end it anyway.
5. **References are read within one chapter.** A reference to an aggregate of another
   domain, or an ending heard across a `translates`, is not checked here.
6. **The finding is a warning.** Many terminal states are completions, not deaths: a
   settled transfer or a built design still exists and its holders are history, not
   orphans. The IR cannot tell a completion from a death, so the check cannot be sure, in
   the same way `:stuck_state` warns "fine if that is meant to be terminal". An error
   would fail the gate on correct models with no way to say so.

## Alternatives considered

- **A `dependent:` option on `reference_to`.** It would put a reaction inside an
  attribute and duplicate what a policy says. Rejected: one idea, one way (ADR 0025).
- **An error with a per-domain allowlist.** `ALLOWED_FINDINGS` is pinned empty and a
  domain's allowance belongs on its own declaration (ADR 0025). Rejected for now.
- **A word that marks an ending state as a death, or a reference as outliving its
  target** (say `outlives:` on `reference_to`). It would let the check tell completions
  from deaths and become an error. Not built: it is a new language word with a Rust
  parity cost, and the warning should first show how often it is wrong.
- **A guard on Y's ending command instead of a policy** (`restrict_with_error`). A
  cross-record guard needs an owning aggregate (ADR 0081); the check does not yet
  recognise one as handling the ending.

## Consequences

- `hecks model_check` over the corpus reports orphaned references in banking, the
  quality-control chapters and two QA fixtures. Banking's cards are retired when their
  account closes (`examples/banking/bluebook/closures.bluebook`). Several other banking
  findings are real but a policy alone cannot close them: the command that would end the
  holder refuses once its parent has ended (`Cancel`, `Void` and `Reject` need an open
  account, `FreezeAccount` and `Decline` a customer who is not closed). Those need a
  modelling decision, not a policy, and stay as warnings.
- A future delete verb, if one arrives, is a second kind of ending and joins the same
  check.
