---
ref: restart-conceiver-as-bluebook-2026-06-13
status: open
category: session-restart
priority: high
posted_at: 2026-06-13
value: 'Session banked one clean commit — 004ec1ed feat(references): bareword refs + has_many polymorphic owned collections (on branch order-boundary-reference''s worktree branch parser-in-bluebook). Three arcs remain open, each fenced for a fresh head because each is design-invention (modeling, not mechanical conversion). THE deep one : the behaviors conceiver (rust/src/behaviors_conceiver/generator.rs, 1579 lines of recursive heuristic logic) should be a BLUEBOOK that generator.rs projects from — the antibody correctly flags it as a gap (it is not a specializer target / corpus-claimed, unlike parser.rs). Conceive the conceiver''s domain first ; cut the projection on a clean head.'
---

# Session-restart handoff — conceiver-as-bluebook + retire the driver (2026-06-13)

Long session, descending the bluebook-first recursion : list_of → has_many ;
imperative driver → behaviors ; behaviors → projection ; and finally the
conceiver that does the projecting → itself a bluebook. One commit banked ;
three arcs queued, all design-invention (fresh-head work).

## BANKED (do not redo)

- **`004ec1ed feat(references)`** — bareword references (role/reference_to never
  quoted) + `has_many` polymorphic owned collections, resolved post-parse by
  locality in BOTH parsers (Ruby `AggregateBuilder#resolve_local_collections!`
  + Rust `parse_aggregate` frag, regenerated via `specialize parser`) :
    - bare + local VO     → composition (list Attribute, the list_of(X) IR)
    - bare + local entity → owned collection (same projected proxy ; identity
      from the entity class)
    - `::Aggregate`        → cross-aggregate reference (`split_qualified_type`
      folds leading-`::` empty domain to None for Ruby/Rust parity)
  - `extraction.bluebook` grammar refined (absorption mode push/merge, self-ref
    has_many children, bareword strategy, list_of eliminated) — VALID, parity-clean.
  - pizzas.bluebook is the canonical example showing every form.
  - Gates : pizzas parity byte-equal ; full corpus 291/291 ; smoke exit 0.

## OPEN ARC 1 — conceiver-as-bluebook (THE deep one, fresh head)

Chris : “generator should be bluebook.” The behaviors conceiver
(`rust/src/behaviors_conceiver/generator.rs`) generates a `.behaviors` suite
from a domain — setup-chain planning (recursive, depth-capped), precondition
parsing/satisfaction, sample-value synthesis, query-param wiring. That
transformation is a DOMAIN RULE and should be declared, not hand-coded. The
antibody flags generator.rs correctly : it is a genuine gap (not a specializer
target). Conceive the conceiver''s domain FIRST (how a domain projects to
tests), then project generator.rs from it. Design-invention — clean head.

**Folded in : a verified gap-fix (NOT committed — reverted to avoid adding more
imperative generator.rs ; re-express its LOGIC declaratively in the bluebook).**
The two gaps + their fixes, proven to take pizzas behaviors from 7/1-fail to 8/8 :
  1. `parse_precondition` : `size < N` (N>=1) is satisfiable by the EMPTY list a
     fresh create yields — add an arm `"lt" if n >= 1 => EmptyList(field)`. Was
     `_ => None`, which dropped the whole command (pizzas AddTopping, guarded by
     `toppings.size < 10`).
  2. `query_test` : wire each PARAM where-clause (IR value `:param`, leading
     colon) to the setup''s sample value for that field, so a parameterised
     query matches its own setup row. Literal wheres (value `pending`, no colon)
     need no input. (pizzas ByDescription : where value `:desc`, field
     `description` ; setup CreatePizza stores description=sample_value(Description)
     ="sample_description" ; emit `input desc: "sample_description"`.)
  Conceiver tests stay green (behaviors_conceiver_test 19, conceiver_parity_test
  5). The “two conceivers” are sibling RUST modules (conceiver/ bluebooks +
  behaviors_conceiver/ behaviors), structurally parallel ; NO Ruby mirror.

## OPEN ARC 2 — retire the imperative driver (pizzas.rb → behaviors)

Chris : “we don''t need an example app — it should all work through storehouse,
expressible through behaviours.” `examples/pizzas/pizzas.rb` is a hand-written
imperative driver (its “generated from PizzasBluebook” header is a lie — nothing
generates it). Replace its smoke role with **conceive-then-run** : regenerate
`pizzas.behaviors` from the bluebook + `storehouse behaviors` (no checked-in
artifact). Blast radius to rewire off pizzas.rb : pre-commit + pre-push hooks
(the smoke gate), `.github/workflows/ci.yml`, 4 skills, `CLAUDE.md`,
`ruby/hecks/smoke/commands/regenerate_examples.rb`,
`ruby/hecks/generators/docs/example_generator.rb`, README. Then `git rm
pizzas.rb`. Sibling drivers (standalone_app.rb, sql_app.rb, event_storm_app.rb,
repl_session.rb) are the same gap — confirm scope with Chris (just pizzas, or all).
DEPENDS ON ARC 1''s gap-fix landing (so the projected behaviors are 8/8 green).

## OPEN ARC 3 — the original parser-in-bluebook kernel interpreter (still open)

From the prior card (parser-in-bluebook-2026-06-13.md) : build the small kernel
interpreter that READS `extraction.bluebook` to parse any bluebook, so parser.rs
/ parse_blocks.rs + the Ruby DSL builders reduce to projections of one grammar.
This session landed the grammar REFINEMENTS (absorption mode, bareword, no
list_of) + a green `command`-interpreter PROOF (parity/grammar_proof.rb, untracked
scratch). The interpreter itself is unbuilt — design-invention, fresh head.

## Housekeeping
- Worktree `parser-in-bluebook` (off order-boundary-reference). generator.rs
  reverted to HEAD ; untracked scratch left in place : parity/grammar_proof.rb,
  parity/pizzas_parity_check.rb, examples/pizzas/bluebook/pizzas.behaviors
  (regenerable). Main-tree binary still carries the worktree''s committed
  parser changes (built via shared-target all session ; a plain `cargo build`
  in main/rust is a no-op since the shared target satisfies it). Resolves on
  merge of the worktree branch to main, or force with
  `cargo clean -p storehouse && cargo build --release` in main/rust.
- Build trick used all session : `cd worktree/rust && CARGO_TARGET_DIR=<main>/rust/target
  cargo build --release` reuses cached deps — ~15s rebuilds vs a cold worktree build.
