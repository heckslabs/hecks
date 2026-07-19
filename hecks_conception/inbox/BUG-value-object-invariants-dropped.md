# BUG (foundational) — value-object invariants are silently DROPPED at parse (2026-07-03)

*Found clicking through the pizzas demo : every invariant declared on a
value_object is decorative — the runtime never evaluates it. Affects EVERY
domain ; demonstrated by the Pizzas exemplar itself. Stop-the-world class :
unenforced validation is a silent correctness hole.*

## Live repro (governed pizzas door, bearer alice, all should REJECT)

```
CreatePizza price=-500      → ok:true  (Price invariant `cents >= 0`)
AddTopping  amount=0        → ok:true  (Topping invariant `amount > 0`)
PlaceOrder  quantity=0      → ok:true  (OrderItem invariant `quantity > 0`)
```
Every one admitted. The invariants are declared — pizzas.bluebook value_objects
Price / Topping / OrderItem each carry an `invariant "..." do <pred> end`.

## Root cause (verified in code)

`rust/src/ir.rs` : `pub struct ValueObject { name, description, attributes }` —
there is NO `invariants` field. Only `Aggregate.invariants` exists (ir.rs:385,
“aggregate-level invariants”). The runtime checker
`rust/src/invariants/mod.rs::check_invariants` iterates ONLY the aggregate's
invariant list (command_dispatch.rs:309 checks `agg.invariants` post-mutation).
So a VO-nested `invariant` block has nowhere to land in the IR — the parser
reads it and DROPS it (the ValueObject builder can’t store it). It never reaches
the checker. Aggregate-level invariants DO work ; VO-level ones vanish silently.

This is the worst failure mode : not an error, not a warning — the guard simply
evaporates, and the domain reads as if it’s protected.

## The fix (two shapes — pick one, deliberately)

A. **ValueObject gains `invariants: Vec<Invariant>`** ; the parser stores VO
   invariant blocks there ; `check_invariants` descends into each VO-typed
   attribute and evaluates the VO’s invariants against that attribute’s value
   (the predicate `cents >= 0` reads the VO’s own field). Most faithful to where
   the author wrote the rule ; needs the predicate evaluator to resolve a field
   against a nested VO value.
B. **Hoist at parse time** : lift each VO invariant to an aggregate-level
   invariant, rewriting the field path to reach through the VO-typed attribute
   (`price.cents >= 0`). Keeps one checker path ; needs the predicate grammar to
   express the dotted path, and the hoist must name which attribute holds the VO.

Either way : a VALIDATOR must also fire so this can never silently drop again —
if a value_object carries an `invariant` block and the IR/checker can’t enforce
it, that’s a parse ERROR, not a silent drop (the macrophage/antibody discipline
applied to the parser itself). And a behaviors/regression test : the Pizzas VO
invariants must REJECT their violations end-to-end through the door.

## Blast radius

Every domain that puts an invariant on a value_object — the idiomatic place for
“a Money can’t be negative”, “a Quantity is positive”, “an Email matches”. The
Pizzas exemplar (the reference every domain copies) does exactly this in three
places, so the canonical teaching example teaches a pattern that doesn’t run.
Fixing this + a parser validator is the highest-leverage correctness work
currently open.

## Full click-through triage (systematic sweep + verified 2026-07-03)

A systematic door sweep raised 9 items ; verified against cold door + posture,
the TRUE list is :

REAL framework bugs :
- **VO invariants dropped** (this file) — confirmed at BOTH cold + served doors,
  so framework-wide, not serve-specific. THE big one.
- **Required-attribute + type validation missing** : `CreatePizza` with NO
  price → ok:true ; `price=abc` (non-numeric Integer) → ok:true ;
  `quantity=lots` → ok:true. Attributes are neither required-checked nor
  type-coerced at the door. (Verify the intended contract : are declared attrs
  required by default? If so, real gap ; if optional, still needs type reject.)
- **Reference integrity unenforced → phantom** : `AddTopping`/`PlaceOrder` with
  `pizza=99999` (nonexistent) → ok:true, writes a ghost. Same upsert-on-absent
  class as the CancelOrder phantom + the just-fixed async-verdict phantom. ONE
  framework decision : should a command referencing an ABSENT root hard-error?

REAL but serve-surface (separate from validation) :
- **By-id state route broken** : `/domains/Pizzas/state/Order/10` → not found
  for EXISTING aggregates (tried many forms). Likely the serve data_dir split
  (FOLLOWUPS #14 : serve reads `<dir>/data`, store is `<dir>/.heki`) OR a route
  path bug — diagnose together with #14.
- **Parameterized query unreachable over HTTP** : `by_description` — the router
  keeps the query string in the verb (`verb=by_description?description=d`). No
  working HTTP form. Real serve query-routing gap.

NOT bugs (verified) :
- **“Auth bypass” (no token admitted)** : the demo posture is `open` — unstamped
  → System → admit-by-origin is the DOCUMENTED open-posture behavior (#746). A
  `governed` client denies it. Working as designed. (Fair design NOTE : under
  open, anonymous &gt; invalid-credential ; that is intended — open = trusted local.)
- **Cart persists to disk** : the demo root has NO `.hecksagon` (removed when
  assembling it), so the `persisted_by("Memory")` binding is not loaded → Heki
  default. Demo-assembly artifact, not a framework bug ; a hecksagon-present
  serve would wire Memory.

BLUEBOOK under-specification (exemplar polish, not runtime bug) :
- **Illegal transitions succeed** : Pizzas declares `transition "Authorize" =>
  "authorized"` with NO `from:` — so any-source is the DECLARED behavior. The
  exemplar SHOULD declare `from:` (e.g. Authorize/Decline `from: "pending"`) and
  CancelOrder SHOULD carry `given { status == "pending" }` to match its goal
  (“cancel a PENDING order”). Separately VERIFY the runtime enforces `from:` WHEN
  declared (authorization.bluebook uses it) — if `from:` is ALSO ignored, that is
  a second real runtime bug hiding behind the under-specified exemplar.

COSMETIC :
- Malformed JSON body → surfaces as an empty-command authz denial, not a 400
  parse error. No crash.

Coverage confirmed CORRECT : `given max 10 toppings` enforced ; async-verdict
phantom GONE (one PlaceOrder = one Order) ; invalid token denied ; unknown
command/agg/domain/query → clean 4xx (no 500s/panics) ; Kitchen.ExpireStale
single-event ; parameterless query works.

## Sibling findings from the same click-through (separate, lower severity)

- **Integer attr accepts non-numeric** : `CreatePizza price=abc` → ok:true. No
  type coercion/validation on an `Integer` attribute at the door — the string
  lands as-is. Should reject at parse-of-attrs.
- **Transition on absent id mints a phantom** : `CancelOrder id=99999`
  (nonexistent) → ok:true, OrderCancelled on 99999. The upsert-on-identity
  transition inserts a default then transitions it (the FINDING-authz #2 class,
  framework-wide : should a transition hard-error on a missing target?). Same
  root as the async-verdict phantom just fixed, different door.
