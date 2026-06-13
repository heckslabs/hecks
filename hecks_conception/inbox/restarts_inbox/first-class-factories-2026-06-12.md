---
ref: restart-first-class-factories-2026-06-12
status: open
category: session-restart
priority: high
posted_at: 2026-06-12
value: 'PHASE 1 MERGED (#730, 2026-06-13). Also landed : Plan singleton retired (#731), cluster-detector qualified-policy-edges fix (#732). Worktree pruned, main clean, 0 warnings. NEXT : PHASE 2 — two-path dispatch split (Factory → mint / Command → load), DELETE the is_create heuristic + the materialize_factory_commands boot seam in runtime/mod.rs. THE silent-regression phase — full corpus run required. Design LOCKED in docs/designs/first-class-factories.md ; execute the phasing, do not re-derive.'
---

# Session-restart handoff — first-class factories (2026-06-12)

Design session. The thinking is done and durable. Resume by EXECUTING the
phasing in the card. Do NOT re-derive the design. Register : aloof,
French-understated, terse ; doc-style narration ; no gush.

## READ FIRST (the source of truth)
`docs/designs/first-class-factories.md` — the whole design is locked there :
diagnosis, the 3 locked forks, grammar/IR/dispatch shape, the 5-phase
migration, the silent-regression risk. Everything below is a pointer into it.

## What just landed (this session)
- **PR #729 MERGED** — `create` vs `command` keyword, additive `Command.creates`
  bool, the validator `meta`-exemption, the FileTool.Edit door-bug inbox card.
  main @ `c4defd33`. This is step 1's stepping-stone ; the factories arc
  DELETES the bool.

## The locked decisions (3 forks, 2026-06-12 with Chris)
1. **Scope : self + cross-aggregate.** Factory node produces its enclosing
   aggregate (default) OR another via `produces:` (Backlog drafts Story). The
   cross-aggregate case is the whole point.
2. **Keyword : `factory`** (distinct block, not `create`). Renames step 1's
   `create` sites — small (the parity fixture + any nursery uses).
3. **Replace the bool.** Promote `creates: bool` → Factory node ; DELETE it +
   the `is_create` name-heuristic. No half-measure left behind.

## The build (gated, worktree — kernel-floor dispatch rewrite)
Full phasing is in the card. In brief, each phase gated on suite + behaviors +
integrity + golden + parity, merge only green :
1. IR + both parsers + both dumps : add Factory node via the shape sources
   (`ir_shape`, `dump_shape`, `parser_shape`, `parse_blocks_shape`) ; add
   `aggregate.factories` ; drop `Command.creates`. `factory` keyword builds it.
2. Dispatch : Factory → mint (error if exists) ; Command → load (error if
   absent) ; delete `is_create` + `creates`. THE silent-regression risk — a
   creator that flips to a transition is caught only by the full corpus run.
3. `produces:` cross-aggregate routing + a real corpus example.
4. Migrate `create` sites → `factory` ; retire the `create` keyword.
5. Fold into the reference_to retirement : self-ref creators → `factory`, drop
   their `reference_to(Self/Root)`, sweep the rest. First-class factories
   COLLAPSE steps 2–4 of `inbox/remove-reference-to-keyword.md`.

## Mechanics learned this session (reuse, don't rediscover)
- Generated `.rs` files (`ir.rs`, `dump.rs`, `parser.rs`, `parse_blocks.rs`,
  `command_dispatch.rs`, `validator.rs`) are SPECIALIZER OUTPUT — edit the
  `codegen/<x>_shape/` fixtures/frags, then `storehouse specialize <x> >
  rust/src/…`, never hand-edit the `.rs`. Each has a byte-identity golden.
- `FileTool.Edit` through the storehouse door MANGLES leading whitespace on
  multi-line `old_string` continuation lines (>~8 spaces). Use single-line
  anchors. See the inbox bug card. (Fix that bug first if it's still open.)
- Gates : `cargo test --release` (incl. 30 specializer goldens) ; the 6 parity
  suites `bundle exec ruby -Ilib parity/<x>_test.rb` ; `storehouse behaviors
  <f>` per file (the sweep wrapper is worktree-deferred) ; `storehouse
  integrity` (run on the live tree).

## Side-thread DONE (2026-06-12)
Thread A — **Plan singleton retirement** — executed : PR #731
(plan-singleton-retirement). The bluebook IS the module ; no Module concept
built (deferred per the locked decision). Previously : Blast radius MEASURED small (PlanOpened in zero goldens/callers/data).
See `inbox/remove-reference-to-keyword.md` § Plan-is-a-Module. Do it as a quick
warm-up or fold it in ; not on the factories critical path.

## State
- `main` @ `c4defd33`, clean, pushed. No open worktrees.
- Untracked : `docs/designs/first-class-factories.md` (the locked card — decide
  whether to commit it ; the other design cards in that dir are also loose).
