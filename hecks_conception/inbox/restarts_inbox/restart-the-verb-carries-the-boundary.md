# Restart — "The verb carries the boundary"

_The relationship-grammar session. Designed the association grammar with Chris,
conceived the chapter, and landed the two hardest kernel pieces. 2026-06-18._

## The locked design (relationship grammar)

Every edge is BY IDENTITY ; the **verb carries the boundary**, in ENGLISH (no `::`).

| keyword | scope | cardinality | meaning |
|---|---|---|---|
| `list_of(X)` | inside | many | embed a collection of owned members |
| `reference_to X` | inside | one | one internal member, by local identity |
| `has_one X` | cross | one | one other root, by global identity |
| `has_many X` | cross | many | a collection of other roots, by global identity |
| `belongs_to X` | cross | one | dependent on another root |

- inside (`list_of`/`reference_to`) = composition, local id ; cross
  (`has_*`/`belongs_to`) = reference, global id. DDD-grounded (Evans: inside you
  HAVE, across you reference by identity ; Vernon Rule 3).
- **NO `::`** — it's codey. Cross-CONTEXT is the English `belongs_to Story from Plan`
  (`from <Context>`), resolved by name ; ambiguity is an ERROR, not a silent guess.
- `has_one` cross carries an Evans smell-caution (a cross 1:1 often wants merging
  or `belongs_to`) ; `has_many` cross is the healthy one-to-many. Not a ban.
- **create-vs-update is NOT a relationship** — it's a persistence UPSERT keyed on
  identity (absent -> insert, present -> update). No `reference_to(Self)`, no name
  heuristic, no `creates` marker. The chapter lives at
  `aggregates/language/grammar/relationship.bluebook` (+ .behaviors), VALID + green.

## Worktree `upsert-on-identity` — 4 commits, ALL GREEN (718 cargo, 114 behaviors, byte-identity)

```
52e1ce747  feat(grammar): English `from <Context>` cross-context reference (retire ::)
e7276b66a  feat(runtime): upsert-on-identity dispatch — retire name heuristic + reference_to(Self)
77e4c27b7  fix(dispatch_query): recognize runtime-subdir specializer targets at their real path
f340d4de8  chore(antibody): exempt imperative-by-nature files (tests / benches / build.rs)
```
NEEDS MERGE to main (Chris's review). Card said merge only green — it is.

## REMAINING work

1. **Stage 2 part 2 — the ambiguity validator.** A bare cross leaf (`has_one Story`)
   that resolves to >1 aggregate must ERROR ("did you mean `from <Context>`?") — the
   no-silent-guess rule. `Story` is ambiguous (5 aggregates) ; `Pizza` (6). This is
   a validator rule, likely in the validator specializer / lifecycle_validator.
2. **Stage 3 — macrophage flags `::`.** In `discipline/immune_system/macrophage/`,
   add a per-rule sibling (i595 family idiom : BluebookFirst, Warnings…) that flags
   `::` in `.bluebook`/`.hecksagon` (codey -> English `from`) + boundary mismatches
   (inside verb at a root, cross verb at a VO). Detection in `bin/macrophage-hook`.

## BLOCKED (Chris's, do not touch)

Main-tree commits — the **relationship chapter**, **pizzas perfection-game (a+b)**,
and **main `bin/antibody-check` fix** — can't land in main because the pre-commit
**parity gate fails on Chris's in-progress `world/parser.rs` drift** (session-start
git status: `world/parser.rs`, `world_parser_test.rs`, `world_known_drift.txt`,
`pizzas.world` all modified before this session). Reconcile that (its own
`parity/world_known_drift.txt`) and the 3 main pieces commit clean. The antibody
fix is staged in main (uncommitted) AND committed on the worktree (f340) — reconcile
on merge.

Uncommitted in MAIN working tree (mine, ready once world-drift clears):
- `aggregates/language/grammar/relationship.bluebook` + `.behaviors` (the chapter)
- `examples/pizzas/bluebook/pizzas.bluebook` + `.behaviors` (perfection-game a+b:
  wired Price + items, asserted emits ; 8/8 green)
- `bin/antibody-check` (the imperative-by-nature exemption, staged)

## Discipline learned this session (CRITICAL for the kernel work)

- **`command_dispatch.rs`, `dispatch_query.rs`, `parser.rs` are GENERATED** from
  `codegen/<target>_shape/snippets/*.rs.frag`. NEVER hand-edit the `.rs` — edit the
  snippet, then `storehouse specialize <target> > rust/src/.../<target>.rs`. The
  byte-identity golden test enforces this. (I hand-edited command_dispatch.rs first
  and the golden caught it ; moved the change to the snippets.)
- **Build release before `is-dispatched` / byte-identity tests** : they shell
  `rust/target/release/storehouse`.
- **Worktree commits** : the antibody hook uses `$REPO/bin/antibody-check` (MAIN's,
  not the worktree's) + `STOREHOUSE_BIN`. To commit Stage-0-style work in a worktree,
  set `HECKS_BIN=$WT/rust/target/release/storehouse` so `is-dispatched` uses the
  worktree binary (with the runtime-subdir fix), and ensure MAIN's `bin/antibody-check`
  has the test exemption.
- **`is-dispatched`** recognizes specializer targets ; runtime-subdir targets
  (command_dispatch, repository, interpreter, reaction, aggregate_state,
  event_driving, persistence_resolution) now match at `rust/src/runtime/<name>.rs`
  (was only flat `rust/src/<name>.rs` — the 77e4 fix).
- **`from` is Ruby-eval-incompatible** (space-separated bareword) → demo.bluebook is
  in `parity/known_drift.txt`, same class as north-star FQN binds, retires with the
  Ruby parser. If you add more `from` sites, they'll each need a known-drift line
  until the Ruby parser is lifted.

## Pizzas note
CLAUDE.md's smoke `ruby -Iruby examples/pizzas/pizzas.rb` is STALE — pizzas went
fully bluebook, no `.rb`. Worth fixing when you touch CLAUDE.md.
