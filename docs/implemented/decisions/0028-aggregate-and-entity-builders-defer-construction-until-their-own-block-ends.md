# AggregateBuilder and EntityBuilder defer entity/command/query construction until their own block ends

**Status:** Accepted and built.

## Context

`AggregateBuilder`/`EntityBuilder` run their `do...end` block via a single
`instance_eval`. `attribute`/`value_object`/`identified_by`/`given` (block
form) all build eagerly, appending to a plain array as their own line
executes — and were never the problem. `entity`/`command`/`query` also
used to build eagerly: the moment `command "X" do ... end` ran, the
resulting `Command` was built and its own resolution logic ran
IMMEDIATELY, seeing only whatever the owner had declared *so far*.

Several resolution rules depend on that "so far" being complete, not
partial — [`docs/resolution-rules/`](../../resolution-rules/README.md)'s
`sets :field` (owner attribute import) and `sets :list, append: {...}`
(list element construct import), a command's block-less `given("desc")`
(references an aggregate-level precondition), a query's own positional-
parameter resolution, and (found only while scoping this change)
`identified_by`'s own single-field-value-object auto-unwrap for an entity
specifically. All five shared one root cause: eager, inline construction.

Three real cases in the self-hosted meta-domain
(`lib/hecks/language/bluebook/`) violated the "declare before you
reference" convention this depended on: `command "Handler"` before
`entity "Handler"`, same for `Dispatch` (nested one level further in) and
`Member` — the creator command lives on the OUTER construct by design (an
entity is never created through its own dotted verb) and is declared
before the entity it creates. A fourth, previously-undetected instance
surfaced only while verifying this fix: `spec/fixtures/model_check/
lifecycle_findings.bluebook` declares an entity's own single-field
identity value object *after* the entity — `identified_by`'s auto-unwrap
silently produced the wrong (un-unwrapped) result, caught by `spec/
parser_parity_spec.rb` once Ruby's output changed and Rust's didn't yet.

## Decision

`entity`/`command`/`query` no longer build immediately. Each pushes a
`[name, ..., block]` descriptor onto an owner-level pending list
(`@pending_entities`/`@pending_commands`/`@pending_queries`, each
preserving its own declared order). The owner's own `#build` gained a
first step, `drain_pending!`, that builds everything for real only once
`instance_eval` has fully finished — entities first and completely
(recursively — a nested piece gets the identical treatment, so `Dispatch`
inside `Handler` resolves too), then commands, then queries, since a
command's own `append:` resolution needs a list's element entity already
built (`.attributes` populated), not just named.

This is the SAME move `BluebookBuilder` already made one level up: build
every aggregate in the chapter first, then run cross-referential
validation (`validate_query_hops!`, `validate_projected_fields!`,
`validate_no_bidirectional_references!`) once `@aggregates` is fully
populated. Extended one level down rather than invented fresh.

Order is preserved throughout — each pending list keeps its own push
order, and `.map` at drain time preserves it into the final array, which
matters: the exported IR is array-order-sensitive
([`implicit-append-fields.md`](../resolution-rules/implicit-append-fields.md)'s
own "position-preserving, not appended at the end" is the sharpest
example of why).

## Rejected alternatives

**Keep eager construction, defer only resolution** (patch an already-built
`Command`'s attributes after the fact, once the owner's own block
finishes). Rejected: `Command`/`Entity`/`ValueObject` are never frozen and
mutation-after-`.declare` is already a proven pattern here
(`AggregateBuilder#stamp_references`, `Entity#stamp_children`), so this
was genuinely viable — but it means four separate patch mechanisms (one
per resolution rule) instead of one shared drain, plus a real footgun: a
`Command`'s `attributes_by_name` index is built once at `.absorb` time and
would go stale on any post-hoc mutation unless explicitly re-indexed,
easy to forget on a future fifth rule.

**A real two-pass parse — scan the block's source once for names/shapes,
then evaluate it for real.** Rejected outright, before either variant
(literal re-`instance_eval`, or a static Prism-based source pre-scan) got
built: `AggregateBuilder#build` already has full visibility into every
declared construct right after its ONE real `instance_eval` pass finishes
— the only actual gap was that resolution ran DURING that pass instead of
AFTER it. A second pass over source text — executed twice (real
side-effect risk, no precedent in this codebase) or statically re-parsed
(a second, parallel implementation of DSL semantics that can drift from
the real one) — solves a problem "defer to the end of the same single
pass" already solves for free, with less code and no new failure mode.

## Consequences

- Every future resolution rule inherits full-block visibility for free —
  no per-rule declaration-order limitation to name and work around, the
  way [`implicit-append-fields.md`](../resolution-rules/implicit-append-fields.md)
  used to have to.
- The three meta-domain cases (`Handler`/`Dispatch`/`Member`) are not yet
  migrated to drop their now-redundant explicit `attribute` declarations
  — harmless to leave as-is (an explicit local declaration always wins),
  named as optional follow-up, not required by this ADR.
- Rust's own parser (`rust/parser`, which parses `.bluebook` source
  directly rather than consuming Ruby's IR — [0023](../../decisions/0023-rust-parses-and-compiles-bluebooks-directly.md))
  needs the equivalent restructure to stay in parity — its own hand-
  written line-scanner has a different shape than Ruby's OOP builder, so
  the mechanism isn't a literal port; see `rust/parser/src/parse/
  aggregate.rs`/`entity.rs` for however that ended up landing.
