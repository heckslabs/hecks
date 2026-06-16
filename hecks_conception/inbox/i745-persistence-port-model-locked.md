# i745 — Persistence port + three adapters ; runtime never auto-selects (model locked)

**Filed:** 2026-06-15 (with Chris). **Supersedes** the "collapse Backend::Memory
­merged into the domain" momentary framing. **Extends** i728 (the persistence
adapter-family kernel hook) and its 2026-06-14 design update. Refined live while
wiring the hexagon `persisted_by` consult ; captured so the model isn't
transcript-only.

## The locked model

1. **The domain talks to a persistence PORT** (`back_aggregate_storage`). It
   never names a store and never knows which adapter answers find/save.
2. **In-memory is a repository-port ADAPTER, not a default and not a collapse.**
   The HashMap repository (`Backend::Memory`) is promoted from "implicit
   fallback" to a first-class adapter of the port — one of THREE :
   - **memory** — in-process HashMap (the "simple construct") ; no disk
   - **heki**   — `.heki` files on disk
   - **sqlite** — typed SQL table per aggregate
   All three declare `behavior :back_aggregate_storage` (the i728 2026-06-14
   distinct-adapter-families design — memory is one of the three, not the
   absence of the other two).
3. **The runtime NEVER auto-selects.** Which adapter fills the port is ALWAYS a
   wiring decision (`.world` / hexagon bind). The silent heki-default — every
   undeclared aggregate falling through to `miette-state/information` — is
   REMOVED. "No default" means the runtime never picks for you.
4. **Strict / production = fail loud when the port is unwired.** The dormant
   `unwired_aggregates()` check becomes enforced : an aggregate with no
   persistence adapter, in strict mode, is a BOOT ERROR — not a silent write.
   A bluebook MAY still run on its own in-memory (the memory adapter wired,
   explicitly or as the no-`.world` default) ; strict mode is the production
   guard against forgetting.
5. **Tests wire memory explicitly** (`force_memory_repositories` /
   `boot_in_memory`) — a deliberate choice, never a fallback.

## Why — the realisation chain

"Collapse in-memory into the domain" breaks the port : if the domain talks to a
port uniformly, in-memory can't be a special non-repository case — it must be an
adapter behind the same port. So the repository abstraction STAYS ; what changes
is that selecting an adapter is always explicit, and memory is a choice among
equals rather than the thing that happens when you forget.

## The runtime-discovered baseline (the proof, not a guess)

`storehouse backends <root>` (committed `ea01991e`) boots the runtime exactly as
production does and projects each aggregate's RESOLVED backend without hydrating.
Chris : "I don't trust inventories unless they are discovered at runtime."

`hecks_conception` today :
```
1182 heki  ·  69 memory  ·  0 sql        (1252 aggregates)
1065 UNWIRED · 187 wired
by store:
  1173 → miette-state/information   ← the SILENT heki-default (auto-select)
    69 → (memory, no disk)
     8 → aggregates/plan/.heki      (Plan::* — world-heki, wired)
     1 → aggregates/demo/.heki      (Demo::Demo — world-heki but UNWIRED)
```
Findings : (a) **1173 aggregates ride the silent default** — the auto-select the
model removes ; (b) **1065 are unwired** — the strict-mode migration surface ;
(c) only **2** domains resolve to a real world path (Plan, Demo) — the i728 card
GUESSED 4 ; the boot proved 2 (exactly why runtime-discovery) ; (d) `Demo::Demo`
is UNWIRED yet lands at `demo/.heki` — the "heki without an adapter" gap, in the
wild.

## Sequenced cutover (each step gated by the `backends` diff)

1. **DONE** — runtime-discovered inventory (`storehouse backends`).
2. **Port + 3 adapters first-class** (declarative / additive). Memory/heki/sqlite
   as proper port adapters wireable per domain. No behaviour change.
3. **Wire every currently-persisting domain explicitly** (`.world` = source of
   truth). Additive, behaviour-preserving — `backends` diff must be IDENTICAL
   before/after each domain.
4. **Kill the auto-select** (the FLIP). Remove the heki-default ; unwired → the
   memory adapter (non-strict) or fail-loud (strict). Only after step 3 covers
   every persisting domain. THE RISK : Miette's live stores (plan, organs,
   memory, census) ride the silent default today — flipping before they're wired
   is silent data loss. This is why the inventory + per-domain diff gate exist.
5. **i735 falls out** — per-domain resolution replaces the global
   `apply_sqlite_persistence` ; the over-apply panic is gone by construction.

## Verification gate (before any behaviour change ships)

- `storehouse backends` before == after for every domain not intentionally
  changed (a backend flip is an automatic stop).
- A no-`.world` domain writes NO disk (memory adapter).
- pizzas (world heki) persists ; cold-boot Miette round-trips plan/.heki + organs.
- ANY assertion fails → revert, do not ship.

## Provenance

Steps 1-3 of the hexagon lift (parse `.family`/`.adapter` → IR ; parse binds ;
resolve adapter→family→verb via `storehouse verify`) are committed + pushed on
`sq/persistence-keystone`. The `persisted_by` CONSULT (mint the bound adapter at
repository-mint) was found to be redundant-today (pizzas already heki ; default
still heki) and load-bearing only AFTER this cutover — so it waits on step 4.
