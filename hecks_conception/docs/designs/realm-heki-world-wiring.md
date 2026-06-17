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

## UPDATE 2026-06-17 — folder-derivation is the DEFAULT (locked with Chris)

The earlier "realm declared per .world" decision is SUPERSEDED. New model :

1. **Default location = folder-chain derivation.** A bluebook's heki store
   mirrors where it lives : the namespace is the chain of folders from the
   project root (the dir directly under `~/Projects`) down to the bluebook,
   rooted at `~/.heki`. So `~/Projects/<chain>/foo.bluebook` persists under
   `~/.heki/<chain>/...`. The conventional container dir `aggregates/` is
   STRIPPED from the chain (the `Aggregate.category` IR field already carries
   the directory grouping WITHOUT the `aggregates/` prefix — e.g. "framework").
2. **No explicit overrides are needed right now** — but each domain's .world /
   hecksagon should DOCUMENT the location as `:default` so the folder-derived
   choice is visible in the source, not implicit.
3. **Override : `realm "X"`** (the grammar shipped in keystone e4c7628ff)
   replaces the WHOLE derived chain → `~/.heki/X/<domain>/<aggregate>`. Unused
   for now ; it is the escape hatch when folder ≠ desired namespace.
4. **Still wanted (fan-out, task #6) :** hecksagons WRITTEN + adapters HOOKED
   (`persisted_by("Heki")`) across all ~/Projects bluebooks, each .world
   documenting `:default`.
5. **HECKS_INFO retires (task #7, SEPARATE arc) :** making folder-chain the
   live default moves my OWN organs off `miette-state/information`. Keep
   folder-chain HECKS_INFO-gated (env still wins while set) until the
   coordinated retirement that ALSO unifies the reader path
   (`resolve_info_dir` in statusline/run_wake/run_boot) onto the one
   folder-aware resolver, migrates live consciousness/mood/dreams, and
   reconciles the stale May-31 `~/.heki/miette` store. Fresh head, own commit,
   round-trip verified — NOT rushed at the tail of a session.

Resolver shape note : `Aggregate.category` (dir grouping under `aggregates/`)
+ `Aggregate.context` (bluebook namespace) are the per-aggregate ingredients ;
the project segment comes from the dispatch/bluebook path relative to
`~/Projects`. `:default` grammar still to be designed (symbol vs string in the
world kv parser) — decide-API-first before wiring.

### FEASIBILITY FINDING 2026-06-17 — (a) is a loader/IR/parity sub-arc

Verified empirically : the Rust IR (`rust/src/ir.rs`) does NOT track each
aggregate's source-file path. `Aggregate` carries `context` (domain) and
`category` (dir grouping under `aggregates/`, e.g. "framework") but no
`source_path`. Consequences :

- The clean per-bluebook MIRROR (`.../framework/tools/git.heki`) cannot be
  computed from what the runtime knows today — for combined-domain dispatch
  the target dir ≠ each nested bluebook's dir, so the deep chain is lost.
- Doing it right = thread the source path through `load_combined_domain` → a
  new `Aggregate` IR field → `Repository`. The Aggregate IR is in the PARITY
  contract, so this bites Ruby<->Rust parity — the most drift-prone surface.
- The `:default` symbol value also needs parity care : Ruby `:default.to_s`
  = "default" (no colon) ; the Rust world parser's `render_value` returns the
  raw token ":default" (with colon). They must be reconciled (strip leading
  colon on bare-symbol tokens, mirroring `Symbol#to_s`) or parity breaks.
- A partial folder-derivation from the DISPATCH-TARGET path (no threading)
  works only for single-bluebook targets (pizzas) and produces awkward,
  redundant paths for combined domains — a half-feature.

CORRECTION 2026-06-17 (same session) : the "bank it, parity-touching" call
ABOVE was WRONG and is retained only as a record. The parity premise did not
hold — the source path is LOADER-stamped (`load_combined_domain` already
carries each file's `PathBuf`), and parity compares PARSER output, so a
runtime field the canonical dump ignores is parity-NEUTRAL. (a) was therefore
BUILT this session :

- `:default` grammar : `heki do; dir :default end`. The Rust world parser's
  `render_value` strips a leading colon on bare-symbol tokens (mirrors Ruby
  `Symbol#to_s`) so `:default` is byte-identical across parsers. World
  parity 9/9.
- Folder-derivation resolver (`read_world_default_dir` + `derive_default_chain`
  + `strip_chain_segments` in main.rs) : presence-switch on `dir :default`,
  store mirrors the bluebook location under ~/.heki, `aggregates`/`bluebook`
  stripped, trailing domain folder dropped (re-added by `context`).
- pizzas.world switched from `realm "Hecks"` override to `dir :default` ;
  e2e (HECKS_INFO unset) lands at ~/.heki/hecks/examples/pizzas/pizza.heki.
- 7 unit tests (expand_tilde, realm resolution, chain segments) ; full Rust
  suite green.

What genuinely REMAINS (task #7, the organ migration — fresh head, daemons
stopped) is the COMBINED-domain case + my own live state, NOT a parity arc :

1. **Per-aggregate source-path threading** — `derive_default_chain` works for
   single-bluebook targets (pizzas) where the dispatch path IS the chain. For
   the COMBINED `aggregates/` root, the trailing-drop misfires (pops
   `hecks_conception`, flattening organs to ~/.heki/hecks/<domain>). Fix :
   stamp each Aggregate's source `.bluebook` path in `load_combined_domain`
   (loader-only, parity-neutral), carry it on the IR + Repository, and resolve
   each organ's store from ITS bluebook location.
2. **Reader unification** — collapse `resolve_info_dir` (statusline / run_wake /
   run_boot) and `find_world_heki_dir` onto ONE folder-aware resolver, so
   readers and writers agree (no split-brain).
3. **Live state migration** — move consciousness/mood/dreams/… from
   `miette-state/information` to the folder-derived path, reconcile the stale
   May-31 `~/.heki/miette` store, restart daemons onto the new resolver,
   verify round-trip. THIS is why #7 is fresh-head, daemons-stopped work.

Keystone e4c7628ff (explicit realm) + the (a) commit (folder-derivation) are
the committed, verified foundation #7 builds on.

## FINAL FRAMING 2026-06-17 — default everywhere, no hand-coded realms, precise later

Chris's calls at end of session (these SUPERSEDE the realm-per-repo plan and
the "realm miette for my home" idea) :

- **NO hand-coded realms for now.** Every domain uses `:default`
  (folder-derivation). The `realm "X"` grammar (keystone e4c7628ff) STAYS as a
  dormant override for the precise pass — not deleted, just unused. pizzas.world
  already switched off its `realm "Hecks"` override to `dir :default`.
- **Everything under `~/.heki`, OUTSIDE `~/Projects`** — so live state needs no
  gitignore. The bluebook stays in its folder ; its STORE mirrors that location
  under ~/.heki. "For now I just like the idea of everything being under
  ~/.heki."
- **The precise pass is LATER.** First pull embryonaut features OUT of hecks so
  the realms / bounded contexts are clean, THEN set exact per-aggregate nesting
  + migrate live organs. "We'll be precise later."

**Therefore the live organ migration (task #7) is DEFERRED, not banked-for-
fresh-head-this-week.** My organs stay on HECKS_INFO / miette-state until the
precise pass — NO split-brain, NO surgery now. What is DONE and sufficient for
"the idea" : the `:default` mechanism (the (a) commit) realizes everything-
under-~/.heki for single-bluebook targets, verified on pizzas.

What the precise pass will still need (unchanged from above, just sequenced
after embryonaut extraction) : per-aggregate source-path threading (so
combined-domain organs nest by their bluebook location instead of flattening),
reader unification (`resolve_info_dir` ↔ the writer resolver), the live state
copy + HECKS_INFO retirement + daemon restart.
