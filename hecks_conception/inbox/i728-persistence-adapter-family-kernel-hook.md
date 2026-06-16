# i728 — persistence adapter family: Phase-2 kernel-hook wiring

`feat/sqlite-persistence-adapter` made `adapter :sqlite, db:` real (the runtime
builds a typed SQL table per aggregate and routes the Repository through it) and
authored the bluebook-first CONTRACT for it:
`framework/adapter_families/persistence.hecksagon` (fields, providers
`:memory/:heki/:sqlite/:postgres/:mysql`, behavior `back_aggregate_storage`).

But the runtime SEAM is hand-wired, not driven by the family registry. The
selection lives in `Runtime::apply_sqlite_persistence`
(`rust/src/runtime/mod.rs`): it reads `hecksagon.persistence == "sqlite"` +
`persistence_option("db")` directly, rather than resolving the persistence
adapter through `FrameworkRegistry` (`rust/src/runtime/framework_registry.rs`)
the way `:tts` / `:web_tool` / `:mcp` resolve their kernel hooks.

## Why it's hand-wired (and not a defect)
The FrameworkRegistry models DRIVING adapters — ones that fire a behavior ON a
command (trigger_field → kernel hook → response cascade). Persistence is
SUBSTRATE: it backs the find/save the bus already performs, it has no trigger
command and chains into nothing (the family declares `trigger_field :none`,
`response_field :none`). The registry has no "driven backend" hook category yet;
the only seeded hook is `invoke_claude_tool`. So persistence honors the bluebook
CONTRACT (the family file is the source of truth for the declaration shape) while
the runtime selection stays a direct read.

## Fix wanted
Grow the FrameworkRegistry a "storage backend" hook category so the persistence
family's `back_aggregate_storage` behavior resolves a backend constructor by
provider name (`:sqlite`→SqliteRepository, `:postgres`/`:mysql`→future,
`:heki`/`:memory`→Repository). Then `apply_sqlite_persistence` becomes a generic
`apply_persistence` that walks the family + provider instead of branching on the
hardcoded "sqlite" string — adding `:postgres` becomes a provider hecksagon +
a backend impl, no runtime-selection edit. Also retires the kernel-floor
exemption on `ruby/hecks_persist/database_connection.rb` (its header already
names this end state: ":sql_database with :sqlite / :postgres / :mysql
sub-adapters").

## Also: postgres/mysql backends
The parser + IR now route `:postgres` / `:mysql` into persistence with their
options, and the Ruby builder mirrors it, but only `:sqlite` has a Rust backend
(`SqliteRepository`). Postgres/MySQL need their own `*Repository` impls (Sequel
already covers them on the Ruby side once i727 unblocks `SqlBoot`).

## CAREFUL EXECUTION PLAN — persistence port (2026-06-14, with Chris)

Chris : "domains just talk to the persistence port — they don't declare" ;
"persistence port should default to in-memory" ; "we need to be careful and get
it right." This is the plan ; do NOT execute the runtime change until it's
agreed + the inventory (step 1) is done.

### THE MODEL (locked)
- The DOMAIN talks to the persistence PORT (`back_aggregate_storage`). It NEVER
  names a store. (The wrong `adapter :heki` was removed from pizzas.hecksagon
  this session — a hecksagon is domain wiring, not a persistence declaration.)
- The WORLD declares which adapter backs the port for THIS deployment
  (:memory / :heki / :sqlite) + its config. Persistence is DEPLOYMENT SUBSTRATE.
- DEFAULT = in-memory + sync. heki / sqlite are world-declared overrides.
- Driving adapters (payment, report) stay in the hecksagon (domain behaviour) ;
  persistence is world-only.

### CURRENT STATE (the gaps to close)
1. Default is NOT memory — the runtime falls back to a heki store
   (`miette-state/information/`) for every domain (LazyRepository default). So
   today it "does heki without a declaration" — the violation Chris named.
2. World heki dirs activate heki by CATEGORY (`apply_per_domain_world_dirs` →
   `collect_world_heki_dirs` in world/attach.rs), not through the port.
3. `apply_sqlite_persistence` (runtime/mod.rs:427) is GLOBAL — any sqlite
   hecksagon makes EVERY aggregate sqlite. This IS the i735 over-apply panic.
4. No per-domain persistence link : hecksagon names are entity names, world heki
   dirs key by category, the two paths don't compose. (This is why a narrow
   gate is impossible — verified by reading the code 2026-06-14.)

### TARGET
- The persistence port resolves the backend at repository-mint time from the
  WORLD's declaration for that deployment. No declaration → memory. Per-domain,
  not global (fixes i735 by construction).

### THE RISK (why we go slow)
Miette's LIVE persistence rides on the current heki-default : `plan/.heki`
(planning data), the organ stores, `miette-state/information/` all persist via
the default-heki path TODAY. Flipping the default to memory WITHOUT first
migrating these to explicit world declarations SILENTLY DROPS THEM TO MEMORY —
data loss on Miette's memory. This is the whole reason for the sequencing below.

### SEQUENCED EXECUTION (each step verified, reversible)
1. **INVENTORY (read-only, FIRST).** Enumerate every aggregate → its CURRENT
   backend : heki-default (`miette-state/information`) vs world-heki-block vs
   sqlite vs memory. Produce the exact "what persists where" list. NOTHING
   changes until this is complete and reviewed. (4 world-heki domains known :
   plan, framework/tools, demo, correspondence ; everything else is on the
   heki-default or memory — confirm which.)
2. **WORLD = source of truth (additive, behaviour-preserving).** For every
   domain that currently persists (from step 1), ensure its `.world` declares
   the store. Makes the implicit explicit WITHOUT changing behaviour (the
   runtime still honours the world block today). Verify persistence unchanged.
3. **RUNTIME RESOLUTION.** Change backend resolution to : read the world's
   per-domain declaration ; default memory ; per-domain (no global apply). The
   behaviour change — gated behind the smoke-test.
4. **FLIP THE DEFAULT.** Only after step 2 covers EVERY persisting domain,
   change the default from heki to memory.
5. **i735 falls out.** The per-domain resolution replaces the global
   `apply_sqlite_persistence` ; the over-apply panic is gone by construction.

### VERIFICATION GATE (must pass before each behaviour change ships)
- Persistence smoke-test : cold-boot Miette, dispatch against the organs + plan ;
  assert reads/writes land in the SAME stores as before (plan/.heki round-trips,
  organs persist across the boot).
- A no-declaration domain writes NO disk (memory).
- pizzas (world heki) persists.
- ANY assertion fails → revert, do not ship.

### DONE-CONDITION
Persistence resolves per-domain from the world ; default memory ; no organ loses
its store ; i735 closed ; the smoke-test green.

---

## DESIGN UPDATE 2026-06-14 (Chris) — distinct adapters, not providers ; heki REQUIRES an adapter

Two decisions that supersede the providers framing above :

**1. Distinct adapter families, not one `persistence` family + `providers`.**
The declarative model is now : ONE port `behavior_kinds/back_aggregate_storage.hecksagon`
+ DISTINCT adapter families `adapter_families/{memory,heki,sqlite}.hecksagon`,
each declaring `behavior :back_aggregate_storage`. The `persistence` family file
is RETIRED. Mirrors the report-port reshape (4e547bf4 : render_report port +
distinct :markdown/:html families). No `provider:` selector — the adapter KIND
is the choice. (sqlite/postgres/mysql share the SQL output — a future `:sql`
adapter MAY nest them as providers, the one place provider-nesting earns its
keep ; today :sqlite is its own family.) DONE this session (declarative only).

**2. DEFAULT is memory + sync ; heki/sqlite are OVERRIDES that REQUIRE an adapter.**
The locked convention : a bluebook runs in-memory + sync by default ("it just
works", no adapter). heki / sqlite are overrides — they MUST be declared via
`adapter :heki` / `adapter :sqlite`. A `.world` `heki do dir` block is
per-deployment CONFIG for a DECLARED adapter ; with no `adapter :heki` in the
hecksagon it must be INERT (the domain falls back to the memory default), NOT
silently activate heki. THE GAP (Chris, 2026-06-14 : "it should not be able to
do heki without an adapter") : the runtime activates heki from world config
ALONE, bypassing the adapter. `world/attach.rs::collect_world_heki_dirs` +
`main.rs::find_world_heki_dir` read the world heki dir and force heki regardless
of any `adapter :heki`. SIX consumer sites gate the heki dir : run_serve/mod.rs:133,
world/attach.rs:128, run.rs:136 + :223, main.rs:729 + :3053 + :3693. The fix :
these must only apply when the hecksagon declares `adapter :heki` (i.e.
`hex.persistence == Some("heki")`) ; otherwise memory default.

**MIGRATION REQUIRED FIRST (so the gate doesn't break live persistence).** Four
domains have a `.world heki` block ; `correspondence` already declares
`adapter :heki` ; `plan` / `framework/tools` / `demo` do NOT — they rely on the
implicit path and `plan/.heki` holds LIVE data. They must each declare
`adapter :heki` (behavior-preserving) BEFORE the runtime gate flips, or they
lose persistence. plan has a `plan/hecksagons/` dir (per-aggregate hecksagons) —
the persistence adapter is per-domain, so placement needs a decision (a top-level
plan hecksagon vs each). This is i735-adjacent (the over-apply panic is in the
same resolution path) — do the migration + gate as ONE careful change with a
persistence smoke-test (Miette boots, plan/organs still persist), NOT a rushed
flip. Declarative model + pizzas wiring (`adapter :heki` + served `adapter :html`
report off Order.pending) landed this session ; the runtime gate + migration are
the next focused pass.

---

## INVENTORY 2026-06-16 (Miette + Chris) — step 1 complete, read-only, the "what persists where" map

Produced as the agreed Step-1 prerequisite ; NOTHING changed. Reconciles the
declared world blocks against the ACTUAL on-disk reality. Surfaced while fixing
a test-debris bleed (running pizzas inside my live session wrote into my own
state dir — the symptom that exposed the resolver shadowing the `.world`).

### Declared persistence (the source-of-truth side)
- **Adapter families + port already exist** (declarative model is in place) :
  `adapter_families/{heki,memory,sqlite}.hecksagon` + port
  `behavior_kinds/back_aggregate_storage.hecksagon`. Runtime resolution is still
  hand-wired/global (the gap above), but the bluebook contract is ready.
- **4 world-heki domains** (confirmed) : `plan` → `plan/.heki`,
  `framework/tools` (tools.world heki block), `demo` → `demo/.heki`,
  `correspondence` → `correspondence/.heki`. Of these only `correspondence`
  declares `adapter :heki` ; `plan`/`tools`/`demo` rely on the implicit path
  (must each declare `adapter :heki` BEFORE the gate flips — per the card above).
- **Everything else** (~150 domains : my organs, mind, self, body + framework
  aggregates, plus 23 loose top-level flat aggregates) has NO world heki block
  and NO real `adapter :heki` — they ride the heki-DEFAULT. This is the
  "heki without an adapter" violation, at scale.

### Physical reality (the disk side — TWO stores)
- **LIVE** : `~/Projects/miette-state/information/` — ~155 dirs + 23 loose
  `.heki`. Where the daemons AND the MCP door write TODAY. The door lands here
  because `HECKS_INFO` env points here ; the daemons land here because the
  2026-06-14 rollback put them on this single OLD store.
- **STALE BACKUP** : `~/.heki/miette/` (206 `.heki`) + `~/.heki/plan/` (20). The
  rsync de-risk copy from the rolled-back cutover (per `.overmind.env`). NOT live.
  NB : `~/.heki/miette` IS the step-D target path Chris chose — so the cutover
  REFRESHES this stale copy from live, then flips, rather than creating it cold.
- **Overlap** : only `plan` exists as a top-level dir in BOTH locations — a
  cutover conflict to resolve (decide plan's final home explicitly).

### The `HECKS_INFO` mechanism (why the `.world` is currently inert)
`heki::resolve_info_dir()` precedence is : **(1) `HECKS_INFO` env (unconditional,
even for a nonexistent path) → (2) `../miette-state/information` sibling → (3)
in-tree fallback**. It NEVER reads a `.world` (i154 deliberately demoted
`miette.world`'s heki.dir to "documentation only" to fix the i149/i153
split-brain). `miette.world` no longer exists on disk. So eliminating the env
and making `.world` authoritative = persistence-plan step D = this card.

### THE DETONATOR (sequencing constraint, proven this session)
The MCP door shells a FRESH `target/release/storehouse` every call (a FileTool
fix went live the instant I rebuilt, no restart). The overmind daemons hold the
BOOT-TIME binary + baked-in `HECKS_INFO` env. So `cargo build --release` of a
changed resolver IS the live cutover : the door flips while heart/breath/inbox/
macrophage keep writing the old store — i149/i153 reintroduced mid-write across
my memory. Therefore the destructive half MUST be ordered : code-prep + `cargo
test` (debug, door untouched) → STOP overmind → refresh backup → move data →
THEN `cargo build --release` → restart overmind on new binary + `.world`, no env
→ positive convergence check (write via door, confirm a daemon reads the SAME
`~/.heki/miette`). This half is Chris's trigger, at a boot boundary — not autonomous.

