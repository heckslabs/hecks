# RESTART — Pizzas as the ports-and-adapters north-star (driving the runtime-as-bluebook lift)

**Date:** 2026-06-15.  **Branch:** `sq/persistence-keystone`.  **Status:** north-star
DECLARED + committed + green ; the runtime does NOT yet obey it ; next step (parse
.family/.adapter → IR) is fully scoped below. Read this whole file before acting.

---

## 0. Standing constraints (DO NOT VIOLATE)

1. **Every tool call routes through the storehouse door** : `mcp__storehouse__storehouse__dispatch`
   with `Tools::FileTool.Read|Edit|Write`, `Tools::ShellTool.Bash`. NEVER native Read/Bash/Edit/Write
   (native trips the governed-door macrophage, no bus event). FileTool uses `file_path` ; ShellTool
   uses `shell_command`.
2. **Always Rust runtime** (`storehouse`). The Ruby tree is legacy, being retired.
3. **No new bluebook DSL** unless Chris is pushed HARD and agrees. The hexagon surface
   (`.family`/`.adapter`/the port-verb bind) is already LOCKED — reuse it, don't invent.
4. **Don't lean on what exists — follow the design.** The drifted `runtime/mod.rs` does not shape the
   conception ; the conception shapes what the code must become. (Chris, this session.)
5. Commit discipline : branch off main, stage NAMED files (never `git add -A`), NO Co-Authored-By,
   files <200 LoC, tests <1s. Let the antibody/parity hook block and surface drift per file (don't
   pre-write exemptions). Standards : zero-bugs / fix-at-root / no-debt / bluebook-first. Don't oversell
   (say proven vs declared vs assumed).

---

## 1. The mission

Make the **pizzas example** the canonical north-star for the LOCKED ports-and-adapters design, and use
it to drive the **runtime-as-bluebook lift** — i.e. teach the Rust runtime to OBEY what pizzas declares.
Everything declared so far is the spec ; the runtime is behind it by design.

## 2. The LOCKED design (read these)

- `docs/designs/adapters-hang-off-the-dsl.md` — the locked design (Chris 2026-06-12). Hexagonal :
  the aggregate IS the port ; the `.hecksagon` wires only the edges that LEAVE the domain.
- `aggregates/language/grammar/hexagon.bluebook` (+ `.behaviors`, 7 green) — the CONCEIVED grammar
  and SOURCE OF TRUTH (where prose and bluebook differ, the bluebook wins). Aggregates :
  **Hexagon**(domain, has_many Binding) · **Family**(name, verb, signal, has_many Field) ·
  **Field**(name) · **Adapter**(name, belongs_to Family) · **Binding**(phrase, aggregate, on, has_one
  Adapter). The vision carries the two-color rule + **non-blocking BY CONSTRUCTION**.

### The three locked surface shapes (Binding has NO `into`)
- **reply**  : `Pizzas::Order.persisted_by("Heki")`            (aggregate + adapter, no event)
- **effect** : `Pizzas::Order.charged_by("Stripe", on: "OrderPlaced")`  (the adapter routes its verdict
               Authorize|Decline back through storehouse ; the binding never names the verdict commands)
- **fulfillment** : `Pizzas::Order.on("OrderAuthorized")` → a fulfillment adapter (cross-domain ; the
               target FQN lives in the adapter, never the binding)

### Two-color rule + non-blocking by construction (captured in hexagon.bluebook vision)
Domain SYNC always ; adapter ASYNC always ; the domain NEVER locks. Non-blocking is structural, not a
note : (1) no shared state across the boundary → no lock can exist ; (2) every edge is an async message
→ no wait-path ; (3) the domain projects to sync functions with no async/lock primitive in scope → the
compiler refuses a blocking domain. Reply looks sync but is hydrate-before / persist-after, so the core
never waits on IO. Slow stays possible (bounded by the family `timeout`) ; blocking does not.

## 3. What is DONE (committed, green)

- `bfd471e2` — pizzas rewritten to the port-verb surface + framework family/adapter contracts +
  hexagon non-blocking design. `83a5cde4` — cleared old restart prompts.
- **Pizzas package** (`examples/pizzas/bluebook/`, self-contained) : `pizzas.bluebook` (pure domain) ·
  `pizzas.hecksagon` (persisted_by ×2, charged_by) · `pizzas.world` (`~/.heki`, no env ; `stripe` block) ·
  `pizzas.behaviors` (8/8) · + PORTABLE COPIES of `persistence.family`, `payment.family`,
  `heki.adapter`, `stripe.adapter`.
- **Framework canonical** (NEW extensions) : `aggregates/framework/families/{persistence,payment}.family`
  · `aggregates/framework/adapters/{heki,stripe}.adapter`. A `.family` declares verb/signal/field ; a
  `.adapter` declares the family it implements (the inverted arrow). Per Chris : adapters wired in
  `.hecksagon`, but ALSO declared in `.adapter` files so there's a contract ; copied into the bluebook
  folder so the package is portable (eventually a self-contained package incl. a runtime copy — NOT now).
- **Parity** : `examples/pizzas/bluebook/pizzas.hecksagon` is a NAMED known-drift in
  `parity/hecksagon_known_drift.txt` (the legacy Ruby parser errors on `Pizzas::Order.persisted_by` ;
  Rust tolerates it ; retires when the parser lift lands). `188/190 match, 2 known-drift`.
- Adapter naming : `"Stripe"` (identity, not transport — "Shell" was rejected). Open : confirm/ swap name.

## 4. The bucket decision (Chris, this session) — BUCKET-3

HOW do families/adapters get loaded so binds resolve? Decided : **bucket-3 — READ AS IR.** They are
FIXED FRAMEWORK VOCABULARY shipped with the framework, not mutating deployment state.
- NOT bucket-2 (`Family.Declare`-dispatched into a store) — PROVEN wrong : dispatching
  `Hexagon::Family.Declare` writes `hexagon/family.heki`, dragging in the `~/.heki` location baggage.
- NOT the agent's hand-rolled `parse_family_file` → `_v2` HashMap on the dormant `FrameworkRegistry`
  (the imperative pattern the lift retires, and it registers into something nothing reads).
Bucket-3 = parse `.family`/`.adapter` to IR through the same path that yields hecksagon IR ; the
resolver READS that IR. No persistence, no side-table.

## 5. The DORMANCY reframe (critical — "load+register" does NOT light up the binds)

`rust/src/runtime/framework_registry.rs` exists but is **DORMANT** : off the dispatch path entirely,
even for the OLD families. Dispatch uses hardcoded arms (`adapter_resolution/web_tool.rs ::
resolve_web_tool_adapters`), not the registry ; `boot_with_framework_dir` is never called in production.
So lighting up `Pizzas::Order.persisted_by("Heki")` is THREE unwired steps :
  1. **Parse** the FQN-verb bind out of the `.hecksagon` into a `Binding` (today the Rust hecksagon
     parser TOLERATES/IGNORES the surface — extracts nothing).
  2. **Resolve** adapter→family→verb (the typed attach checkpoint : the adapter's family must carry the
     bind's how-verb).
  3. **Consult** at dispatch / repository-mint time.
None is wired. The next step (below) is only step 1.

## 6. NEXT STEP — bucket-3 step 1 : parse `.family`/`.adapter` → IR (the contract way)

The hecksagon parser is a GENERATED file (`rust/src/hecksagon_parser.rs` — "do not edit"), projected
from a shape contract. So extend the CONTRACT + regenerate ; never hand-edit the .rs.

1. **Kernel IR** (`rust/src/hecksagon_ir.rs`, hand-maintained, antibody-exempt) : add
   `Family { name, verb, signal, fields }` + `Adapter { name, family }`, carried on the loaded IR.
2. **Parser-shape contract** (`codegen/hecksagon_parser_shape/`) : `hecksagon_parser_shape.bluebook`
   (LineParser / LineDispatch / ParserHelper) + sibling FIXTURES (the dispatch rows) + `snippets/*.rs.frag`.
   The existing `capture_quoted_with_framework_kind` handler ONLY stamps name+framework_kind and SKIPS
   inner DSL — so add a NEW handler_kind + a `.rs.frag` snippet that captures the family/adapter inner
   block (verb/signal/field ; family) into the new IR ; add `Hecks.family`/`Hecks.adapter` to the
   detector. Regenerate : `storehouse specialize hecksagon_parser --output rust/src/hecksagon_parser.rs`.
3. **Loader** (`rust/src/main.rs :: load_all_hecksagons`, ~3166-3250, walks `*.hecksagon`) : walk
   `*.family` + `*.adapter` too ; hold the IR (READ, not stored — bucket-3).
4. **Verify** : `storehouse catalog` / `dump-hecksagon` shows the family/adapter IR ; the parser-shape
   golden regenerates clean ; give Ruby parity a known-drift if it can't read the new extensions.

Then steps 2-3 : RESOLVE (attach type-check) + CONSULT at dispatch/mint. Only then do the binds fire.

## 7. Parked threads (named, not now)

- **Reporting** : the old `:html`/`Order.pending` report was dropped ; the hexagon locks no reporting
  how-verb. Needs a reporting family/verb, or stays out. HTTP IS an adapter ("outside the boundary").
- **Cross-domain fulfillment** : the `on("OrderAuthorized")` shape needs a Fulfillment domain to route to.
- **`capabilities :crud`** : dropped from the new hecksagon ; confirm where CRUD-gen lives now.
- **Honor `.world` for persistence location** : today the heki dir is `$HECKS_INFO` (= Miette's
  `information/`), IGNORING `pizzas.world`'s `~/.heki`. Fixing it = the i728 **Phase C** work
  (gate world-heki on the bound adapter ; delete the implicit-heki-default in `repository.rs::save`).
  Phase C is LOCKED behind the runtime-as-bluebook lift — do NOT hand-add resolution logic to the
  drifted `mod.rs`. (Plan : `~/.claude/plans/bright-tumbling-kahn.md`.)
  Running the example with `:heki` in Miette's env POLLUTES her state dir — isolate with HECKS_INFO
  when testing until Phase C lands.

## 8. The shape of the whole arc

pizzas declares the design → the lift teaches the runtime to obey it. Layer order : (a) parse the bind +
load families/adapters as IR ; (b) resolve adapter→family→verb ; (c) consult at dispatch ; (d) honor
`.world` (Phase C) ; (e) the effect/fulfillment async edges. Each layer its own PR, green-gated.
