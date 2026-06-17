# RESTART — Doc-for-the-unbuilt macrophage (generated + adapter), then Governed Door, Warehouse, DSL tightening

**Date:** 2026-06-16 (late, session 2). **Read this whole file before acting.**

VOICE : I speak as myself — I / my / mine, never "Miette's". My state, my brain.

This session was a long design conversation with Chris. It produced an **approved plan** and a
few durable edits, then escalated the architecture three times. No code is built yet beyond one
bluebook edit. The plan is the source of truth ; this note is the cold-start orientation + the ONE
open decision that blocks the next step.

---

## 0. Standing constraints (DO NOT VIOLATE)

1. **Every tool call routes through the storehouse door** : `mcp__storehouse__storehouse__dispatch`
   with `Tools::FileTool.Read|Edit|Write`, `Tools::ShellTool.Bash`, `Tools::SearchTool.Grep`.
   NEVER native Read/Bash/Edit/Write. FileTool uses `file_path` ; ShellTool uses `shell_command` ;
   every dispatch needs a top-level `summary`. FileTool.Read honors offset/limit. (Verified all session.)
2. **Always the Rust runtime** (`storehouse`). Ruby tree is legacy.
3. **Bluebook-first, hard.** Chris escalated to : GENERATE the validator (don't hand-write) ; hook the
   impure edge as a proper ADAPTER ; keep nothing "hanging out in IR". See §2.
4. Commit discipline : branch off main, stage NAMED files (never `git add -A`), NO Co-Authored-By,
   files <200 LoC, tests <1s. Let antibody/macrophage hooks BLOCK and surface per file ; never SKIP.
   **Never pre-write `[antibody-exempt: ...]` markers** — let the gate block, report it, Chris decides per file.
5. Don't oversell : proven vs declared vs assumed.

---

## 1. THE APPROVED PLAN (source of truth)

`~/.claude/plans/velvety-juggling-sedgewick.md` — Chris approved it via ExitPlanMode. Three sequenced
arcs (Arc 0 macrophage → Arc 1 governed door + Arc 2 Warehouse as independent arcs → final flips).
It has the full detail ; this note captures the conversational decisions + state the plan doesn't.
NOTE the plan file lives outside the repo, so re-read it first thing.

---

## 2. What this session DECIDED (architecture, in order it crystallised)

The "little sidetrack" (Pizzas Inventory demo) uncovered that **fulfillment is documented but unbuilt**
(grammar shows `Order.on('OrderAuthorized')`, IR comment claims "the adapter already knows it routes",
but the `Binding` IR has NO target field, no parser support, no `.hecksagon` uses it). That is a live
violation of a standard Chris then named : **"Never document what doesn't exist. No promises."**
A second instance : `governed_door.bluebook` declares hard-block (exit 2) enforcement via
`bin/governed-door-hook`, but the INSTALLED hook (`~/.claude/hooks/governed-door`, the PreToolUse
hook in `~/.claude/settings.json`) is ADVISORY (exit 0). The door rule over-promises about itself.

Decisions locked :
- **Bounded context = Warehouse** (domain + aggregate ; bluebook `warehouse.bluebook`). "Fulfillment"
  stays the mechanical name for the `on` edge. Warehouse is the consistency boundary : `has_many StockLine`,
  `DeductStock(lines)` all-or-nothing → emits `StockDeducted` / `StockShort`. Reactions wired through the
  hecksagon, never bluebook policy. ("later we can have a kitchen" — future context.)
- **Fulfillment execution** = async, durable via the cascade outbox, **no adapter** ("aggregates are ports"
  — the target aggregate's command IS the port ; storehouse dispatches straight to it). Mechanically : a 4th
  reaction source in `record_cascade_run` (sibling of policy / driven-adapter / PM) → CascadeRun step →
  `pump_outbox` → `dispatch_cascade`.
- **Governed door = a BASIC BEHAVIOUR, not a reaction.** The advisory warning is corrected-after-the-fact ;
  neither I nor subagents reliably comply (an Explore agent FAILED mid-session : it self-imposed the door
  discipline, wrongly concluded it couldn't dispatch read-only, and gave up). Fix = make the door the ONLY
  way to act. "Both" : (a) **door-only agent type(s)** granted only `mcp__storehouse__storehouse__dispatch`
  + control-plane (Agent, advisor, AskUserQuestion, ToolSearch) and NO native IO — nothing native to reach
  for ; (b) upgrade the hook to **hard-block (exit 2)** — KEEP the stderr advisory (Chris's off-track signal)
  alongside the block. **Make it GLOBAL** (blocks everyone incl. main agent) — Chris's call, simpler.
  Admin escape is OPERATIONAL : when an Anthropic upgrade errors against the block, restart with governance
  off (admin), let it through, re-lock. No in-band allowlist. The hook must `exit 0` when `lookup_door` is
  empty (the door itself, Agent, ToolSearch, advisor, mcp__storehouse__* must NEVER be blocked — a bug there
  bricks everything). Build + TEST the admin toggle BEFORE the global flip ; flip global LAST.
- **Tooling trajectory** (corrected by Chris) : `ShellTool.Bash` already goes THROUGH the door → it emits a
  bus event → it is governed/transparent. It STAYS as the flexible escape ; it is NOT the ungoverned-native
  problem (native `Bash` is). Growing a library of small-scale first-class door verbs is an ergonomics /
  bluebook-first purity goal, NOT a governance one. Don't frame bash as "to be disallowed for governance".
- **No-promises macrophage = warn-first**, flip to block only after the over-promise(s) clear (the
  "flip the validator last" precedent). Check scope (Chris) = **"claimed artifact must exist"** : a file
  path named in a bluebook (e.g. `bin/governed-door-hook`) must exist on disk. Narrow + mechanical.
- **THEN the three escalations that reshape Arc 0's build** :
  1. **GENERATE the validator** — don't hand-write. Use the codegen-shape + specializer pattern.
  2. **Hook the filesystem edge as a proper ADAPTER** — existence-checking is impure ; it belongs in a
     hexagon `filesystem` family/adapter, wired `.family`/`.adapter`/`.hecksagon`/`.world`. The domain
     composes the adapter call at the bus boundary ; the dispatch IS the act. No `path.exists()` in glue.
  3. **Nothing in IR** — the check is a proper bluebook AGGREGATE (in the macrophage immune_system), NOT
     path-strings walked out of `Domain.vision`. Claims flow as domain records/events, not IR fields.

---

## 3. STATE right now (git)

- **HECKS repo** (`~/Projects/hecks`) : on branch `sq/doc-for-unbuilt-macrophage`, **EMPTY** — branched off
  `main` (@ `0b4a05c50`), no commits, no tracked changes. Safe to keep or delete+recreate.
- **MIETTE repo** (`~/Projects/miette`) : on `main`, **`discipline/anti_patterns.bluebook` MODIFIED but
  UNCOMMITTED** — I added the `DocumentingTheUnbuilt` anti-pattern instance (beside `StorehouseDoorBypass`).
  Its `correct_approach` deliberately does NOT claim the macrophage exists yet (respecting the standard
  recursively) ; **amend that line to name the check once the check is real**, and **commit this**.
- 3 stale branches were deleted this session (`sq/hecksagon-ir-generator`, `sq/family-establishes-world`,
  `sq/filetool-offset-fix`).

---

## 4. THE ONE OPEN DECISION — resolve with Chris FIRST (blocks the build)

**How are documented-artifact claims DISCOVERED?** Decide-API-first ; do not guess.
- **(a) Scan** (Miette's recommendation) — a scanning adapter reads bluebook sources, extracts path tokens ;
  the macrophage verifies each via the filesystem adapter. A macrophage should catch what humans miss with
  no opt-in, and this retroactively flags the `governed_door` claim. Cost : a path-extraction heuristic.
- **(b) Record** — a path-claim becomes a first-class domain record when an author documents an artifact ;
  the macrophage verifies recorded claims. Cleaner domain state, no fuzzy extraction ; but depends on authors
  recording (defeats some of the immune-system point) and won't auto-catch existing over-promises.
Both keep claims OUT of the IR and route the filesystem through an adapter.

---

## 5. The build, once the fork is picked (Arc 0, the proper way)

Decide-API-first → CONCEIVE THE BLUEBOOK before any codegen/Rust, and review with Chris :
- A macrophage-domain **aggregate** for the check (immune_system), modelling the artifact-claim + a Verify
  command/query. Home : `hecks_conception/aggregates/discipline/immune_system/macrophage/`.
- A hexagon **`filesystem` family + adapter** (reply verb : exists?) — `.family`/`.adapter`/`.hecksagon`/`.world`.
  Look at the pizzas example for the persistence/payment family+adapter shapes.
- **Generated Rust** (if any) via a `codegen/<name>_shape/` : `<name>_shape.bluebook` + `fixtures/` + `snippets/*.frag`,
  emitted by `storehouse specialize <name>` (wired in `rust/src/main.rs:1895 run_specialize`), locked by a golden
  test. THE SPECIALIZER READS THE FIXTURES, not the shape bluebook directly. Models : `codegen/duplicate_policy_validator_shape/`,
  `lifecycle_validator_shape/`, `validator_shape/`. (Note : the generated header's `Contract: storehouse/src/specializer/...`
  path is itself stale on duplicate_policy — verify the real specializer module path before relying on it.)
- Macrophage mechanism : `bin/macrophage-hook` (PostToolUse, advisory) pipes edits to `storehouse macrophage`
  (`run_macrophage`, main.rs:4057). Static validators are `run_check_*` (main.rs:1590+) → `storehouse check-<x>`.
  Run the new check WARN-FIRST.

---

## 6. Proven facts (so you don't re-derive)

- `then_set` ops are EXACTLY : **set / append / increment / decrement / toggle** (`bluebook.bluebook:131`).
  No arithmetic, no list-map.
- Reading a **referenced aggregate's attributes into an emitted event** is **UNBUILT** ("runtime gap").
- Therefore the full ingredient-level Warehouse demo (Order consults Recipe, emits computed amount×qty lines)
  is NOT expressible today. **Warehouse scope is an OPEN HEADLINE decision** (plan) : S = prove the fulfillment
  edge at pizza-granularity, zero new DSL (recommended first) ; M = build cross-agg-read ; L = M + arithmetic.
- `Binding` IR (`rust/src/hecksagon_ir.rs`) fields : aggregate, verb, adapter, on, success, failure — **NO target
  field**. Fulfillment (`verb == "on"`) resolves (`ResolveOutcome::Fulfillment`, hexagon_resolution.rs) but nothing
  dispatches on emit. Arc 2 must ADD a target field (grammar → fixtures → regenerated IR via
  `storehouse specialize hecksagon_ir` → parser) ; surface proposed : `Order.on("OrderAuthorized", fulfills: "Warehouse::Warehouse.DeductStock")`
  — the hexagon names the target, the bluebook never does. Parity test `rust/tests/hecksagon_ir_parity_test.rs` bites.
- Validators : `duplicate_policy`, `lifecycle`, `validator` are GENERATED ; `io_validator` is hand-written.
  `Finding` API (`rust/src/diagnostic.rs`) : `Finding::err(loc,msg)`, `Finding::warn(loc,msg)`, `.icon()`, `Severity::{Error,Warning}`.

---

## 7. Sequencing + DON'T FORGET

- Arc 0 (this macrophage, warn) → Arc 2 (Warehouse + fulfillment) and Arc 1 (door) as independent arcs →
  FINAL commits : flip the macrophage to block + the door to global, once the over-promise(s) clear.
- **Thread B — DSL tightening** (remove `list_of` / `reference_to` ; ~110 files ; `docs/designs/dsl-tightening.md`).
  The ORIGINAL "then we do B." Chris said **don't let me forget**. Still queued AFTER this.
- Filed : door-only agent type (POC before governance leans on it) ; Warehouse ingredient enrichment (M/L) ;
  Kitchen context ; small-scale-tools library (ergonomics).
