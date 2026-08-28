# Resolution rule specs

A resolution rule is a DSL builder mechanism that lets a bluebook author omit
a declaration the runtime can derive on its own — `sets :field` alone
importing the owning aggregate's own `attribute :field, Type` instead of
requiring a byte-identical retype is the first one; see
[`implicit-command-attributes.md`](implicit-command-attributes.md) and
[`implicit-append-fields.md`](implicit-append-fields.md).

**Why this directory exists, separately from `docs/decisions/`:** an ADR
records *why* a decision was made — the trade-offs, the rejected
alternatives. A resolution rule spec records *exactly what the algorithm
does*, precisely enough that a second, independent implementation (Rust's
own parser, which reads `.bluebook` source directly rather than Ruby's IR —
[ADR 0023](../decisions/0023-rust-parses-and-compiles-bluebooks-directly.md))
can be written from the spec alone, without reading Ruby's implementation
and inferring intent from its comments.

That gap is real, not hypothetical: building
[`resolve_append_fields!`](implicit-append-fields.md)'s own order-preservation
logic took real debugging — a naive append-at-end insertion silently
reproduced the wrong order for every field except whichever one happened to
already be last, caught only because a codemod's own reboot-and-diff safety
net found the mismatch. A Rust-mirror agent working from "here's a diff, here's
some prose, go infer the algorithm" carries exactly that same risk on every
future rule, with no comparably cheap safety net catching it inside the Rust
port itself — the same order bug ported into Rust would surface only as a
`parser_parity_spec` diff late in the loop, not as an obviously-wrong
insertion while writing it. A precise, language-agnostic spec is how that risk
gets caught at write time instead.

## Format

Every rule spec covers the same six sections, in order:

1. **Motivation** — the redundancy this rule removes, with the real corpus
   evidence that motivated it (not a hypothetical example).
2. **Algorithm** — numbered, language-agnostic pseudocode. Precise enough
   that "does this input qualify" has one unambiguous answer for every case
   below.
3. **Qualifies / does not qualify** — an explicit table or list of concrete
   inputs and their outcomes, especially the near-misses that look like they
   should match but don't (and why).
4. **Known limitations** — anything the algorithm deliberately does not
   handle, named rather than silently scoped around. `AggregateBuilder`/
   `EntityBuilder` defer `entity`/`command`/`query` construction until
   their own block ends ([ADR 0028](../decisions/0028-aggregate-and-entity-builders-defer-construction-until-their-own-block-ends.md)),
   so a resolution rule generally does NOT need to name a declaration-
   order limitation the way `implicit-append-fields.md` used to — check
   that ADR before assuming a forward reference can't resolve.
5. **Reference implementation** — the exact Ruby file and method.
6. **Reference mirror** — the exact Rust file and function, once ported.
   `NOT YET MIRRORED` if it isn't (a rule spec is written when the Ruby side
   ships, generally before the Rust mirror — the mirror's own agent is who
   fills this section in).

## Using a rule spec to write a Rust mirror

A Rust-mirror agent's prompt should link the relevant rule spec(s) as the
primary source of truth for *what* to build, with the Ruby implementation
linked as a secondary cross-check (does the code actually match its own
spec — if not, the SPEC is probably still right and the CODE has drifted,
since the spec is what a human reviewed; flag the mismatch rather than
silently trusting either one). This replaces "read the Ruby diff and its
comments, infer the algorithm" with "read the spec, the algorithm is already
extracted."

## Rules

- [Implicit command attributes](../implemented/resolution-rules/implicit-command-attributes.md) — bare
  `sets :field` imports the owner's own attribute. **Implemented** — moved to
  `docs/implemented/resolution-rules/`.
- [Implicit append fields](../implemented/resolution-rules/implicit-append-fields.md) — bare self-referential
  fields inside `sets :list, append: { ... }` import the list element's own
  attribute, position-preserving. **Implemented** — moved to
  `docs/implemented/resolution-rules/`.
- [Cross-entity given sharing](../implemented/resolution-rules/cross-entity-given.md) — a piece's own
  `given`, shared across ANY piece nested under the same aggregate, not just
  that one piece's own commands. **Implemented** — moved to
  `docs/implemented/resolution-rules/`.
- [Chapter-wide given sharing](../implemented/resolution-rules/chapter-given.md) — an aggregate's own
  `given`, shared across any OTHER aggregate in the same chapter, when the
  two verifiably resolve the identical predicate. **Implemented** — moved to
  `docs/implemented/resolution-rules/`.
- [Chapter-wide entity-scoped given sharing](chapter-entity-given.md) — a
  piece's own `given`, shared across any OTHER piece anywhere in the same
  chapter, even nested under a DIFFERENT aggregate — one level down from
  chapter-wide given sharing, the same way cross-entity given sharing is one
  level down from an aggregate's own `given`. Rust mirror not yet built —
  stays here.
