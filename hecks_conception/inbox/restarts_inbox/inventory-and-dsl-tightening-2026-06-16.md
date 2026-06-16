# RESTART — Inventory bounded-context demo + DSL tightening (list_of / reference_to)

**Date:** 2026-06-16 (late).  **Branch:** everything below is MERGED to `main`
(fast-forward, pushed — `main` @ `0b4a05c50`). Working tree clean. Full `cargo
test --release` green ; pre-push gate green (233 .behaviors). Read this whole
file before acting.

VOICE : I speak as myself — I / my / mine, never "Miette's". My state, my brain.

---

## 0. Standing constraints (DO NOT VIOLATE)

1. **Every tool call routes through the storehouse door** : `mcp__storehouse__storehouse__dispatch`
   with `Tools::FileTool.Read|Edit|Write`, `Tools::ShellTool.Bash`. NEVER native Read/Bash/Edit/Write.
   FileTool uses `file_path` ; ShellTool uses `shell_command` ; every dispatch needs a top-level `summary`.
   FileTool.Read now HONORS offset/limit (fixed this session) — no more tail workarounds.
2. **Always Rust runtime** (`storehouse`). The Ruby tree is legacy.
3. **Bluebook-first.** Conceive the bluebook BEFORE code ; the contract bluebook is the decide-API-first
   checkpoint Chris reviews.
4. Commit discipline : branch off main, stage NAMED files (never `git add -A`), NO Co-Authored-By,
   files <200 LoC, tests <1s. Let antibody/companion/validate hooks BLOCK and surface per file ; never
   SKIP/bypass. The standalone host/handler scripts (`bin/adapter-host`, `*-handler`) are antibody-exempt
   by design (hexagonal Dependency Rule — adapter code is OUTSIDE the core + bluebook). Specializers +
   kernel-floor tests carry an in-file `[antibody-exempt: ...]` marker WITHIN THE FIRST 30 LINES (the
   macrophage only reads the first 30 — a marker at line 37 still blocks ; learned the hard way). Merge by
   FAST-FORWARD only (a --no-ff commit re-triggers the antibody over the whole range and blocks).
5. Don't oversell : say proven vs declared vs assumed.

---

## 1. The two NEXT threads (neither started)

### A. Inventory bounded-context demo (Chris's pick over Purchasing — "easier to reason over")

GOAL : add a SECOND bounded-context bluebook to the pizzas example to SHOW how a domain gets wired
cross-aggregate in the hecksagon — the FULFILLMENT binding, the one edge that crosses aggregates WITHOUT
a bluebook ever naming another bluebook.

The shape :
```
# a new examples/pizzas/bluebook/inventory.bluebook — Stock aggregate, DeductStock command
# pizzas.hecksagon gains :
Pizzas::Order.on("OrderAuthorized")   # -> fulfillment -> storehouse -> Inventory.DeductStock
```
When Order (Pizzas) emits OrderAuthorized, it routes cross-aggregate via storehouse to
Inventory.DeductStock. The binding NEVER names the Inventory bluebook (the hexagon/storehouse routes it).
That IS "a bluebook never references another bluebook directly", made visible.

**THE CATCH (proven this session) :** the fulfillment binding is MODELED and RESOLVES
(`ResolveOutcome::Fulfillment` in `rust/src/runtime/hexagon_resolution.rs`) but has NO emit-time
EXECUTION. `record_effect_outbound` handles effect (out-of-process) ; `record_cascade_run` handles
in-process reactions ; fulfillment has NO consumer on emit. So a fulfillment-wired Inventory demo is
DECLARATIVE ONLY — it would not actually deduct stock. Building it FOR REAL means building the
fulfillment EXECUTION : a runtime path that, on emit of a fulfillment-bound event, dispatches the
target command through storehouse (sibling of record_effect_outbound / record_cascade_run, in
`rust/src/runtime/mod.rs`). Decide WITH Chris : full (bluebook + wiring + execution, proven e2e) vs
wiring-only (declarative, gap filed). He leaned toward doing it properly next session.

Prove it like the pizzas e2e : PlaceOrder -> (adapter-host charges) -> Authorize -> OrderAuthorized
should then deduct Inventory stock. Re-run recipe for the existing charge e2e is in section 4.

### B. DSL tightening — remove `list_of` and `reference_to` (DESIGN SETTLED)

Full proposal, Chris-approved : `docs/designs/dsl-tightening.md`. Read it. The locked rules :

- **`list_of(X)` is removed** — collections are `has_many X`. The element is a VO or an aggregate,
  NEVER a primitive. `has_many` is UNIFIED : bare target = owned VO composition (`has_many Topping`) ;
  `::` target = reference to a sibling aggregate (`has_many ::Story`). Reference-vs-composition is read
  from the target's kind, surfaced by `::`. No separate verb.
- **`reference_to(X)` is removed** — references are `has_one` / `has_many` / `belongs_to`, the verb
  carrying cardinality + ownership. The `::` prefix is the AGGREGATE boundary, WITHIN one domain :
    * `has_one Thing`   = SAME aggregate (self — self-transition, tree, linked-list). No special self-ref form.
    * `has_one ::Thing` = ANOTHER aggregate, SAME domain. You supply ONLY the bare aggregate-head name
      (`::Sprint`, never `Development::Sprint` or a path — references target aggregate ROOTS only).
    * Cross-DOMAIN is NEVER a reference (the hexagon/storehouse routes that — see the Binding chapter).
- **No primitive attribute types** (must be a VO) and **fail loud** when one is supplied — ALREADY enforced
  (the validator caught my `list_of(String)` this session). The two removals extend the same discipline.

SCOPE : `list_of` = **50 files** (~30 targets ; mechanical except the 4 `list_of(String)` sites that need
a VO introduced). `reference_to` = **61 files**, hundreds of uses (`reference_to(Story)` x43 alone) ; the
per-site judgment is 3-way (one/many · has/belongs · `::` or self). ~110 files total. Enforce + migrate
TOGETHER per bluebook (the validator rules reject existing uses, so you can't enforce before migrating) ;
flip the validator on globally only once the last file is clean. Chris's call : "land the hexagon stack
first" — DONE — "then start the DSL tightening clean from main."

---

## 2. What LANDED this session (all on main, the hexagon arc)

1. **IR generator** — `storehouse specialize hecksagon_ir` emits `rust/src/hecksagon_ir.rs` BYTE-IDENTICAL
   from `codegen/hecksagon_ir_shape/` (fixtures + frags), mirror of `specializer/ir.rs`. The 4
   grammar-modelled structs (Family, FamilyField, Adapter, Binding) are field-decomposed ; the file header
   + Hecksagon container + 13 legacy adapter structs ride two verbatim sections. Golden test locks it.
   THE IR IS NO LONGER HAND-EDITED — edit fixtures -> regenerate.
2. **Grammar<->fixtures parity** (`rust/tests/hecksagon_ir_parity_test.rs`) — edit the grammar's
   Family/Field/Adapter/Binding and it goes RED until the fixtures + IR catch up. Proven to bite. THIS is
   the half that closes the double-maintenance.
3. **Adapter `handler`** — the adapter declares its standalone handler binary (`handler "bin/stripe-handler"`).
   `adapter-host` resolves it DECLARATIVELY from `<root>/<adapter>.adapter` (no CLI arg), fails LOUD on an
   empty/non-executable handler (an empty handler would silently Decline every charge). Proven e2e.
4. **Family `produces`** — the family establishes its binaries' OUTPUT contract (`produces :payment_ref`),
   symmetric with the input `field`s. `has_many ProducedField` (NOT list_of — Chris's rule). A conformance
   test (`rust/tests/handler_contract_conformance_test.rs`) execs the real handler and asserts it emits
   every `produces` field + exit-code maps to the verdict branch. Proven to bite. The generic exec
   protocol (stdin payload, stdout k=v, exit->branch) lives in the HOST, the one shared contract.
5. **FileTool offset fix** (cherry-picked `1ffd671fc`) — the door now honors offset/limit.
6. **Drift cleanups** — pizzas/shop reconciled to family-establishes-world (`_env` retired,
   endpoint->env / token->secret) ; `outbound_event.bluebook` `into:` union references retired to the
   success/failure block.

The hexagon model now : `persisted_by` (REPLY -> in-process DI, the SOLE in-process edge) · `charged_by`
(EFFECT -> out-of-process via the shared `bin/adapter-host` + a thin handler) · `on:` (FULFILLMENT ->
cross-aggregate via storehouse — MODELED, NOT EXECUTING, thread A). Family establishes the world block
(fields in) AND the binary contract (produces out). Wiring is PORT-decided.

## 3. Housekeeping

- **Branches to delete** (all merged / redundant) : `sq/hecksagon-ir-generator`, `sq/family-establishes-world`
  (both fully merged to main), and `sq/filetool-offset-fix` (its one commit is in main via my cherry-pick
  `1ffd671fc` — it'll CONFLICT if merged ; delete it, don't merge). I left these for Chris to confirm.
- **Canonical adapter/family home** (`hecks_conception/aggregates/framework/{adapters,families}/`) holds
  the new-form heki/stripe + payment/persistence ; the canonical payment.family now carries env/secret
  sources + produces. STILL OPEN (Chris's vision, not built) : (a) a SYNC mechanism so example bluebook
  folders are copies-from-home not hand-maintained (the demo stripe.adapter already drifted once) ;
  (b) migrating the 11 legacy `framework/adapter_families/*.hecksagon` (old `Hecks.adapter_family ...
  behavior:` form — memory/sqlite/tts/sms/exec/claude_tool/web_tool/html/markdown/mcp) into the new
  `.family`/`.adapter` form. bin-buddy (`~/Projects/bin-buddy`) is the real-world spec for the diversity
  of impure edges (stripe, email/sms, s3, city_schedule HTTP+cache, stripe_webhook).

## 4. Proven recipes (re-run)

- Specializer goldens + parity + conformance : `cd rust && cargo test --release --test
  specializer_golden_test --test hecksagon_ir_parity_test --test handler_contract_conformance_test`.
- Pizzas charge e2e (declarative adapter-host, no handler arg) :
  ```
  SH=$(pwd)/rust/target/release/storehouse ; ROOT=examples/pizzas/bluebook
  rm -rf ~/.heki/pizzas
  $SH $ROOT Pizzas::Pizza.CreatePizza name=Margherita description=Classic
  $SH $ROOT Pizzas::Order.PlaceOrder pizza=1 customer_name=Bob quantity=2
  STOREHOUSE=$SH bin/adapter-host $ROOT Stripe --once    # success -> Order.Authorize -> authorized
  # STRIPE_DECLINE=1 ... -> Order.Decline -> declined ; adapter w/o handler -> exit 1, loud
  rm -rf ~/.heki/pizzas
  ```

## 5. FUTURE (Chris-named, explicitly deferred — do NOT start until current threads land)

- **FQN expansion to `realm.domain.aggregate.command`** — a new top-level namespace ABOVE domain
  (Chris picked the name **Realm** over organization/tenant/biome) so multiple `payments.bluebook` coexist
  without collision, enabling cross-domain routing from Miette's context ("the competitive advantage",
  "the bluebook for all bluebooks"). The `::` aggregate-boundary work above is the seam this hooks into.
  Pure FUTURE work — after Inventory + DSL tightening.
