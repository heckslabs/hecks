# Realm + world-wired heki across all ~/Projects (the persistence arc, kicked off 2026-06-16)

**Status:** decisions locked with Chris ; kernel keystone NOT yet cut. Pick up
from here. Use `examples/pizzas/bluebook/` as the GOLDEN reference (Chris:
“always use pizzas for reference from now on”). `plan.world` is the close
wiring reference for `heki do; dir end`.

## The target (locked)

Every bluebook in `~/Projects` persists through the SAME shape :

```
~/.heki/<realm>/<domain>/<aggregate>.heki
```

- **Realm** = the new top-level namespace ABOVE domain (Chris picked the name
  over organization/tenant/biome ; `realm.domain.aggregate.command`). Declared
  PER `.world` via a new `realm "name"` field beside `heki { dir }`.
- **Domain-level world config still saves each aggregate as its OWN file**
  (`<dir>/<realm>/<domain>/<aggregate>.heki`) — never a merged store. Mirrors
  pizzas (`<dir>/<domain>/<aggregate>.heki`).
- `dir "~/.heki"` everywhere.
- **There is NO environment variable.** `HECKS_INFO` precedence is dropped ;
  the `.world` is the single source of the store location (pizzas.world says
  this verbatim).

## Two decisions locked (decide-API-first, with Chris)

1. **Realm is declared in each `.world`** (`realm "name"`), not a per-repo
   constant, not derived from the dir name.
2. **Full pizzas-ification** of adapters : migrate every `adapter :heki`
   hecksagon to the pizzas composition `Domain::Aggregate.persisted_by("Heki")`.
   (~22 hecksagons in hecks_conception alone, plus miette + client repos.)

## Kernel keystone (do FIRST, verify against pizzas, BEFORE any fan-out)

The world-dir machinery already half-exists — the gap is the DISPATCH path :

- `rust/src/main.rs:3170 find_world_heki_dir(aggregates_path)` ALREADY reads a
  sibling `.world`'s `heki { dir }` (via `read_world_heki_dir`, :3180, using
  `world.config_for("heki").get("dir")`) and only falls back to
  `resolve_info_dir()` when no world declares one. BUT the main command/query
  DISPATCH path does NOT call it — Arc 0 claims landed at
  `miette-state/information/artifact_claim/artifact_claim.heki` (the
  `resolve_info_dir` path, FLAT : `<info>/<aggregate>/<aggregate>.heki`, no
  domain, no realm).
- `rust/src/heki.rs:382 store_path(dir, name)` + `:415 path_for(dir, aggregate,
  context)` build the on-disk path. These need the `<realm>/<domain>/` nesting.
- `rust/src/heki.rs:656 resolve_info_dir()` reads `HECKS_INFO` first ; tests in
  `resolve_tests` assert “env wins unconditionally” — those invert/retire.

**Kernel work, in order :**
1. Add `realm` to the `.world` grammar (world parser) + IR. PARITY : the Ruby
   world parser + the parity suite bite here — this is the delicate part.
2. Make the dispatch store-path resolution world-aware : resolve `<dir>` from
   the domain's `.world` heki block (like `find_world_heki_dir`), read `realm`,
   and nest `<dir>/<realm>/<domain>/<aggregate>.heki`.
3. Drop `HECKS_INFO` precedence in `resolve_info_dir` (becomes last-resort
   default only, or removed) ; invert the `resolve_tests`.
4. **VERIFY against pizzas** : `rm -rf ~/.heki/<realm>/pizzas` ; dispatch
   `Pizzas::Pizza.CreatePizza ...` with `HECKS_INFO` UNSET ; confirm the store
   lands at `~/.heki/<realm>/pizzas/pizza.heki`. Only then fan out.

## Fan-out (mechanical, AFTER the keystone is green ; candidate for a workflow)

For every domain with `adapter :heki` across `~/Projects` (hecks_conception
~22, miette, embryonaut_clients, prod product folders) :
- Migrate the hecksagon `adapter :heki` → `Domain::Aggregate.persisted_by("Heki")`.
- Add/extend the domain's `.world` with `realm "..."` + `heki do; dir "~/.heki" end`.
- Realm value per repo : hecks_conception → ? (“miette”? “hecks”?), clients →
  per-client, prod → “embryonaut”. CONFIRM realm values with Chris per repo.
- Update the parity suite + behaviors as the migration touches them.
- Arc 0's artifact_claim.hecksagon migrates too (adapter :heki → persisted_by)
  and gains its world ; its store relocates to ~/.heki/<realm>/discipline/.

## Sequencing notes

- Worlds are INERT until the kernel reads them — NOT an independently
  verifiable checkpoint. Land kernel + pizzas-verify as one unit.
- The keystone is kernel-floor (parser + parity) ; per the standards it wants a
  FRESH head, not the tail of a long session. The fan-out is mechanical and
  parallelizable once the keystone is green.
- Arc 0 (the no-promises macrophage) is already committed (ceee742a9) ; this
  arc is independent of it.

## Also queued (Chris, this session)

- Write up pizzas as THE golden reference in Miette's SYSTEM PROMPT — which is
  GENERATED from a bluebook (the mindstream `boot` member regenerates
  `~/Projects/miette/self/system_prompt.md` every boot). Edit the GENERATING
  source, not the rendered `.md`.
