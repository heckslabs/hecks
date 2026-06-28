# Storehouse self-hosting inventory (2026-06-27)

The runtime (`rust/src/runtime/`, ~18.3k LoC) decomposed against the goal :
**the runtime becomes a PROJECTION of bluebooks + declared primitives, leaving
only an irreducible seed hand-written.** Built from a 4-agent sweep of the ~40
runtime files. `mod.rs` (4169) is the conductor ; the rest are organs it
assembles + sequences.

## Destination legend
- **SEED** — irreducible native (the Value type, the I/O metal, the persistence DI touch, the specializer). Stays hand-written.
- **PROJECTED** — already a specializer golden target (generated). Done.
- **NEEDS-PROJECTION** — concept conceived in a bluebook ; the Rust is the hand-written impl that should be generated.
- **CONCEIVED:X** — aggregate X already exists (`runtime/dispatch` etc.) ; file is its unprojected impl.
- **NEEDS-CONCEPTION** — should be a bluebook ; not yet.
- **PRIMITIVE** — a declared `Storehouse::Primitive` kernel leaf (native impl, macrophage-guarded).
- **HECKSAGON/WORLD** — edge wiring : a family/adapter binding, driver, or world config.
- **FRONTIER** — aggregable in principle, but needs the kernel-interpreter / richer query grammar that `extraction.bluebook` + behaviors-conception wait on.

---

## A. Execution core  → `runtime/dispatch` (CommandDispatch / EventBus / PolicyBinding / LifecycleCheck / MiddlewareStack)

| File / concern | LoC | Destination | Status |
|---|---|---|---|
| `mod.rs` — Runtime struct + types | ~300 | SEED | done |
| `mod.rs` — boot / assembly | ~500 | SEED | done |
| `mod.rs` — dispatch-lifecycle walk | ~800 | CONCEIVED:Dispatch::CommandDispatch | needs-projection |
| `mod.rs` — gates (`authorize_entry`/`run_gate`/`service_gate`/`authenticate_check`) | ~300 | CONCEIVED:Dispatch::MiddlewareStack | needs-projection |
| `mod.rs` — cascade glue (`drain_*`, `dispatch_cascade`) | ~600 | CONCEIVED:Dispatch::PolicyBinding | needs-projection |
| `mod.rs` — adapter/query/projection infra | ~1700 | mix: HECKSAGON wiring + SEED | partial |
| `command_dispatch.rs` | 1430 | CONCEIVED:Dispatch::CommandDispatch | needs-projection |
| `interpreter.rs` | 560 | PROJECTED (golden: `interpreter_rs`) | done |
| `reaction.rs` | 394 | CONCEIVED:Dispatch::PolicyBinding (reaction delivery) | needs-projection |
| `pm_engine.rs` | 605 | CONCEIVED:ProcessManager | needs-projection |
| `policy_engine.rs` | 229 | CONCEIVED:Dispatch::PolicyBinding | needs-projection |
| `middleware.rs` | 152 | CONCEIVED:Dispatch::MiddlewareStack | needs-projection (reconcile `gating.bluebook` ↔ MiddlewareStack) |
| `acl_readmodel.rs` | 206 | NEW-AGGREGATE: Authorization read-model | needs-conception ; traversal core is FRONTIER |
| `aggregate_state.rs` | 156 | SEED (dynamic state container) | done |

## B. Storage / event-sourcing  → `framework/event_sourcing` + persistence family

| File | LoC | Destination | Status |
|---|---|---|---|
| `repository.rs` | 360 | PROJECTED (golden: `repository_rs`) | done |
| `persistence_resolution.rs` | 383 | PROJECTED (backend-map gate) | done |
| `persistence_adapter.rs` | 133 | HECKSAGON/WORLD (the in-process DI seam) | done |
| `lazy_repository.rs` | 485 | SEED (hydration wrapper) | done |
| `event_log.rs` | 228 | SEED (JSONL substrate) | done |
| `event_log_index.rs` | 333 | SEED (offset index) | done |
| `event_merge.rs` | 382 | SEED (merge daemon) | done |
| `event_shard.rs` | 375 | SEED (per-process shard) | done |
| `event_log_query.rs` | 389 | NEEDS-PROJECTION (where-pushdown) | flagged |
| `projection_fold.rs` | 229 | NEEDS-PROJECTION (fold log→state) | flagged |

## C. Primitives / resolvers / schedulers / registries  → `Storehouse::Primitive` + Driving + families

| File | LoC | Destination | Status |
|---|---|---|---|
| `exec_dispatcher.rs` | 152 | PRIMITIVE: Process.Spawn (record EXISTS) | partial |
| `web_tool_dispatcher.rs` | 774 | PRIMITIVE: WebTool | needs-conception (Primitive record) |
| `llm_dispatcher.rs` | 213 | PRIMITIVE: Llm | needs-conception |
| `shell_dispatcher.rs` | 190 | PRIMITIVE: Shell | needs-conception |
| `compute_dispatcher.rs` | 135 | PRIMITIVE: Compute | needs-conception |
| `adapter_llm.rs` | 142 | PROJECTED (golden) | done |
| `adapter_env.rs` | 132 | HECKSAGON/WORLD (adapter config) | needs-conception |
| `driven_adapter_resolver.rs` | 590 | HECKSAGON/WORLD (driven-on bindings) | needs-conception |
| `driving_adapter_resolver.rs` | 207 | HECKSAGON/WORLD (Driving) | needs-conception |
| `loop_driver.rs` | 490 | CONCEIVED:Driving (LoopDriver) | needs-projection |
| `cron_schedule.rs` | 352 | FRONTIER (pure cron matcher — Driving/Cron backend) | needs-conception |
| `drive_scheduler.rs` | 158 | FRONTIER (interval ticker — Driving/Interval backend) | needs-conception |
| `framework_registry.rs` | 664 | SEED / FRONTIER (boot adapter-family routing) | blocked-on-grammar |
| `primitive_registry.rs` | 292 | SEED (seeds the Primitive records) | blocked-on-grammar |

## D. Query / projection / observability  → `runtime/query`, `runtime/projection`, session log

| File | LoC | Destination | Status |
|---|---|---|---|
| `query.rs` | 449 | PROJECTED (where/order/limit baseline) | done — BUT see gaps below |
| `event_driving.rs` | 108 | CONCEIVED:Dispatch::EventBus | done |
| `dispatch_detail.rs` | 414 | CONCEIVED:SessionLog::StorehouseEntry | done |
| `storehouse_log.rs` | 519 | PRIMITIVE (stdout/file log leaf) | done |
| `projection.rs` | 124 | NEEDS-CONCEPTION (fold from event_sourcing) | FRONTIER |
| `prompt_scaffolder.rs` | 125 | FRONTIER (awaits :llm adapter bluebook) | needs-conception |

---

## Cross-cutting gaps (not single-file)

1. **Auth on queries (the read-path gate is missing).** The gate stack runs only on commands (`dispatch → authorize_entry`). Queries go through `resolve_query`, which never gates — reads have only `scope_to` ROW-scoping, no "can you run this query" gate. Fix : a **gated query entry** that runs the before-gates, keeping `resolve_query` as the ungated core (which `service_gate` already calls) — the SAME gated-outer/ungated-core split commands have (`dispatch`/`dispatch_impl`). **NEEDS-WORK.**
2. **`acl_readmodel` should be a conceived Authorization read-model** — but its role-hierarchy transitive closure can't be a `where`-filter ; it's FRONTIER until the recursive-query grammar lands.
3. **The 5 `*_dispatcher` primitives need `Storehouse::Primitive` records** (Process.Spawn has one ; web_tool/llm/shell/compute don't yet).
4. **The Driving schedulers** (loop_driver/cron/drive) map to the Driving grammar but aren't projected from it.

## The seed (what stays hand-written, by construction)
mod.rs Runtime-struct + boot-assembly ; `lazy_repository` + the event-log I/O metal (`event_log`/`index`/`merge`/`shard`) ; `aggregate_state` (the Value container) ; `primitive_registry`/`framework_registry` boot glue ; and the **specializer** itself — the one true fixed point.

## Projection order (the roadmap)
1. **Gates → MiddlewareStack** : reconcile `gating.bluebook` ↔ `Dispatch::MiddlewareStack`, project the gate logic. (Runtime built ; reconcile + project.)
2. **Query-path gating** : close gap #1 (read-auth symmetry).
3. **Primitive records** for web_tool/llm/shell/compute (declare the leaves).
4. **command_dispatch / policy_engine / pm_engine → project** from `runtime/dispatch`.
5. **Driving schedulers → project** from the Driving grammar.
6. **event_log_query / projection_fold → project.**
7. **acl_readmodel + recursive-query grammar** (FRONTIER) — the kernel-interpreter dependency `extraction.bluebook` shares.

The gates are step 1 — the first thread, already half-pulled (the runtime exists ; reconcile + project remains).
