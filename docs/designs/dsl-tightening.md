# DSL tightening — remove `list_of` and `reference_to`

**Status:** proposal (2026-06-16). Lands AFTER the hexagon stack (now on main).
**Source:** Chris's directives — collections are `has_many`, references are the
directional verbs, no primitives in attributes (fail loud), and a `::` prefix
marks the domain boundary.

## The two rules

1. **`list_of(X)` is removed.** A collection is `has_many X`.
2. **`reference_to(X)` is removed.** A reference is `has_one` / `has_many` /
   `belongs_to` — the verb makes cardinality + ownership explicit, and a
   leading `::` makes the domain boundary explicit.

Both already-enforced siblings stay: **no primitive attribute types** (must be
a VO) and **fail loud** when one is supplied. The two removals extend the same
discipline — the DSL stops offering the loose forms at all.

## A. `list_of(X)` -> `has_many X`

The element is a **VO or an aggregate, never a primitive**.

| before | after | meaning |
|---|---|---|
| `list_of(KeyValue)` | `has_many KeyValue` | composition — owned embedded VOs |
| `list_of(Topping)`  | `has_many Topping`  | composition |
| `list_of(Story)`    | `has_many Story`    | reference — sibling aggregates, same domain |
| `list_of(String)`   | `has_many <NewVO>`  | introduce a VO ; a bare String is rejected |

`has_many` accepts **both** VO and aggregate targets ; the element's KIND
decides the semantics (VO -> composition/owned ; aggregate -> reference). The
DSL surface is uniform ; the runtime already distinguishes the two.

## B. `reference_to(X)` -> directional verb (+ `::` for the aggregate boundary)

Directionality and ownership become explicit in the verb ; the AGGREGATE
boundary becomes explicit in a leading `::`.

| before | after | when |
|---|---|---|
| `reference_to(Self)`  | `has_one Thing`     | SAME aggregate (self-ref — self-transition, tree, linked-list) |
| `reference_to(Other)` | `has_one ::Thing`   | CROSS-aggregate, single, owner side |
| `reference_to(Other)` | `belongs_to ::Thing`| cross-aggregate, single, dependent side |
| `reference_to(Other)` | `has_many ::Thing`  | cross-aggregate, collection |

**`::` is the AGGREGATE boundary, within one domain.** Bare `has_one Thing`
points at the SAME aggregate that declares it (self) ; `has_one ::Thing` points
at ANOTHER aggregate — always in the SAME domain. There is no cross-DOMAIN
reference in a bluebook : a bluebook never references another bluebook directly
(the hexagon / storehouse routes across domains ; see the Binding chapter). So
`::` never leaves the domain — it only crosses from one aggregate to a sibling.

**You supply only the aggregate name — never a path.** A reference always targets
the aggregate HEAD (root) ; you can't reference an inner entity, so there is
nothing to qualify. It's `::Sprint`, never `Development::Sprint` or
`Sprint::Head`. The `::` is a bare prefix on the head name, full stop.

**Self-reference is the bare form.** A transition command on its own aggregate,
a tree node pointing at another node of the same type, a linked-list `next` —
all `has_one Thing` (bare), no special self-ref machinery. The runtime routes
self by the aggregate's `identified_by` key as it does today.

## C. Validator rules (fail loud)

- Reject any `list_of(` in a bluebook — "collections are `has_many`".
- Reject any `reference_to(` — "references are has_one / has_many / belongs_to ;
  prefix `::` to cross a domain".
- (Existing) reject a primitive attribute type — "wrap it in a value_object".

The rules are the teeth ; once live, a new bluebook physically cannot use the
retired forms.

## D. Migration (~110 files)

- `list_of` : **50 files**, ~30 distinct targets. Mostly mechanical
  (`list_of(X)` -> `has_many X`) ; the only judgment is the 4 `list_of(String)`
  sites, which need a VO introduced.
- `reference_to` : **61 files**, hundreds of uses. The judgment per-site is
  three-way : cardinality (one / many), ownership (has / belongs), and boundary
  (`::` or not — is the target in this bluebook or another?).

Order : add the validator rules behind a flag OR migrate-then-enforce. Because
the rules reject EXISTING uses, enforcement and migration must land together
per bluebook (can't reject before migrating). Suggested : migrate domain-by-
domain, flipping the validator on globally only once the last file is clean.

## Settled

`has_many` is unified: one keyword for both composition (VO target) and
reference (aggregate target). The `::` prefix carries the distinction visually
— `has_many Topping` (bare = owned VO composition) vs `has_many ::Story`
(`::` = reference to a sibling aggregate, same domain). Reference-vs-composition
is read from the target's kind, surfaced by `::`. No separate verb.
