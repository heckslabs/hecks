# RESTART — Pizzas hexagon DONE : persistence (DI) + the standalone-adapter contract (effect port)

**Date:** 2026-06-16.  **Branch:** `sq/persistence-keystone` — MERGED to `main`
(fast-forward, 22 commits). `main` is AHEAD of `origin/main` by 22 ; **not pushed**
(push when you want). Full `cargo test` suite green. Read this whole file before acting.

---

## 0. Standing constraints (DO NOT VIOLATE)

1. **Every tool call routes through the storehouse door** : `mcp__storehouse__storehouse__dispatch`
   with `Tools::FileTool.Read|Edit|Write`, `Tools::ShellTool.Bash`. NEVER native Read/Bash/Edit/Write.
   FileTool uses `file_path` ; ShellTool uses `shell_command` ; every dispatch needs a top-level `summary`.
2. **Always Rust runtime** (`storehouse`). The Ruby tree is legacy, being retired.
3. **Bluebook-first.** Conceive the bluebook BEFORE code ; the contract bluebook is the decide-API-first
   checkpoint Chris reviews. No new DSL unless Chris is pushed hard and agrees.
4. Commit discipline : branch off main, stage NAMED files (never `git add -A`), NO Co-Authored-By,
   files <200 LoC, tests <1s. Let the antibody/parity hooks BLOCK and surface per file ; never SKIP/bypass.
   The standalone host/handler scripts are antibody-exempt by design (the hexagonal Dependency Rule puts
   adapter code OUTSIDE the core + bluebook). Merge by FAST-FORWARD — a `--no-ff` merge commit re-triggers
   the antibody over the whole merged range and blocks.
5. Don't oversell : say proven vs declared vs assumed.

---

## 1. What the pizzas hexagon now does (the north-star, REALIZED)

Two ports, two wirings, ONE wiring-agnostic binding DSL :

- **`Pizzas::Order.persisted_by("Heki")`** — REPLY port → **DI, in-process.** The step-4 consult
  (`apply_hexagon_persistence`) mints the repo from the binding at boot, called inline. Fast, deterministic.
- **`Pizzas::Order.charged_by("Stripe", on: "OrderPlaced", into: "Order.Authorize | Order.Decline")`**
  — EFFECT port → **separate-program, out-of-process.** Proven end-to-end on the REAL pizzas example.

## 2. The locked architecture (Cockburn ports-and-adapters — Chris's canon, this session)

- The core (storehouse runtime + bluebook) owns the PORTS ; adapters live OUTSIDE and depend INWARD
  (Dependency Rule). The runtime just handles bluebook ; adapters are standalone.
- The hecksagon binding is **wiring-agnostic**. The per-edge wiring falls out of the port SIGNAL :
  `reply` → DI / in-process (persistence) ; `effect` → separate-program / out-of-process (payment).
- Three ports, all core-owned : **command-in** (`storehouse dispatch`, driving) · **event-out**
  (`OutboundEvent`, driven/messaging) · **discovery** (a read over the binding IR + `.world`).
- **ONE shared generic host** ; thin handlers plug in. The async / retry / timeout live in the
  host/handler — the core is non-blocking BY CONSTRUCTION (no call to block on). This dissolves the
  retry tension : a slow/flaky charge can never block the synchronous core because it's another process.
- E2 (synthesising an in-runtime DrivenAdapter, fired in the pump) was the WRONG shape — reverted. It put
  a flaky edge in-process, the one thing the two-color rule forbids.

## 3. The pieces (all on main)

- **`aggregates/framework/hexagon/outbound_event.bluebook`** — the OutboundEvent contract. The durable
  event-out messaging port (transactional outbox ; CascadeRun's out-of-process sibling). Lifecycle
  pending→claimed→delivered|failed. Commands : `Record` (core, on emit, one per subscribing adapter,
  idempotent on delivery_id) / `Claim` / `MarkDelivered` / `MarkFailed` (host). Query : `Pending(adapter)`
  = the host poll. Doc headers carry the FULL contract.
- **`runtime/mod.rs :: record_effect_outbound`** — the core records one OutboundEvent per subscribing
  adapter on emit of an effect-bound event (parallel to `record_cascade_run`). Via `dispatch_cascade`.
- **Framework outbox SUBSTRATE** — `boot_with_hecksagons` embeds `outbound_event.bluebook` (`include_str!`,
  the `OUTBOX_SUBSTRATE` const) and merges it via `ensure_outbox_substrate` WHEN an effect binding is
  present and the domain doesn't already declare OutboundEvent (gated + deduped). So ANY root — a
  self-contained example included — gets it without copying the bluebook.
- **`bin/adapter-host`** — the ONE shared host : poll `Pending(adapter)` → `Claim` → run the thin handler
  OFF-CORE (stdout = verdict DATA k=v lines, exit code = branch) → dispatch the verdict the delivery named
  (`success_command`|`failure_command`, id=source_id, + handler data) → `MarkDelivered`.
- **`examples/adapter_host_demo/stripe-handler`** — the thin Stripe handler (the only adapter-specific
  code). Emits `payment_ref=...` on stdout ; `STRIPE_DECLINE=1` exercises the Decline branch.
- **`examples/adapter_host_demo/`** — a runnable Shop demo (Order charged_by Stripe).
- **E1** : `into:` verdict union parses into the `Binding` IR (`into: Vec<String>`, success-first).

## 4. Proven (how to re-run)

- In-process round-trip : `cd rust && cargo test --test effect_outbound_record_test` (3 tests).
- Out-of-process, the REAL pizzas example :
  ```
  SH=$(pwd)/rust/target/release/storehouse ; ROOT=examples/pizzas/bluebook
  $SH $ROOT Pizzas::Pizza.CreatePizza name=Margherita description=Classic
  $SH $ROOT Pizzas::Order.PlaceOrder pizza=1 customer_name=Bob quantity=2
  STOREHOUSE=$SH bin/adapter-host $ROOT Stripe examples/adapter_host_demo/stripe-handler --once
  $SH state $ROOT Order 1        # status=authorized, payment_ref set
  rm -rf ~/.heki/pizzas          # pizza persists to ~/.heki via pizzas.world
  ```
  Both branches : success → Authorize ; `STRIPE_DECLINE=1` → Decline.

## 5. Next threads (when you want them — none started)

1. **Real Stripe transport.** The handler reads `endpoint`/`token`/`retries`/`timeout_ms`/`backoff` from
   `.world` (`config_for "stripe"`), POSTs the charge, RETRIES transport failures within that budget —
   OFF-CORE, so the synchronous core never blocks. This is where `retries`/`timeout_ms`/`backoff` finally
   get a consumer : IN THE HANDLER, never the core. A declined charge is a VERDICT (exit 1), never a
   retry (no-silent-retry standard : recovery is a new command).
2. **Long-running host + resident daemon.** `adapter-host --once` → a daemon loop. Ideally consuming from
   a resident `storehouse serve` rather than cold one-shot CLI — but the serve SOCKET is dispatch-only
   today (req/resp) ; it needs a query path, or the host stays cold-CLI (works, just boots per call).
3. **Retire the legacy in-runtime adapter machinery.** `react` / `pump` / `driven_adapter_resolver` are
   the "adapters-in-the-runtime" model the out-of-process contract supersedes. On borrowed time ; a
   separate, careful migration (many features ride it : the actor fleet, claim/lease, cascade tests).
4. **The wide persistence migration (deferred, still open — i745).** Flip the global default to memory +
   fail-loud for new domains + wire the ~133 genuinely-live domains `:heki`. Recoverability proven
   (`Backend::Memory` does zero disk IO) ; the step-4 consult was its prerequisite. Inbox : i745.

## 6. The arc this session (main, ce8923b80 back to 504d6a55b)

step-4 persistence consult · E1 into: · revert E2 · OutboundEvent contract bluebook · core records on
emit · Pending query · round-trip via the door · the one shared host + handler + demo · framework outbox
substrate · host threads verdict-data (pizza round-trips).

---

# UPDATE 2026-06-16 (later session) — hexagon DSL grammar : family establishes the world block, port-decided wiring, verdict block

VOICE : speak as myself — I / my / mine, never "Miette's". My state, my brain.

## A. Branch `sq/family-establishes-world` (3 commits, off main — PUSH it ; gate-green expected)
1. `feat(grammar)` hexagon.bluebook — **family establishes the world block** : Field gains a Source
   (`field :x` = direct ; `field :x, from: :env` = env ; `secret :x` = secret). World keys now match
   the field name EXACTLY — the `_env` suffix retires ; the source disambiguates resolution. A `.world`
   block keyed by an adapter must carry EXACTLY its family's fields ; Hexagon.Verify owns the
   world-conformance check. AND **WIRING IS PORT-DECIDED, not signal-decided** : the PERSISTENCE port is
   the SOLE in-process / DI edge ; every other port (payment, report, tts) is out-of-process through the
   adapter-host — even reply-shaped ones. (Both are Chris's locked decisions.)
2. `feat(hexagon)` FamilyField{name,source} — IR `Family.fields: Vec<FamilyField>` ; the GENERATED
   hecksagon_parser.rs regenerated from the edited fragment
   `codegen/hecksagon_parser_shape/snippets/parse_family_body.rs.frag` (NEVER hand-edit the .rs).
   Specializer golden byte-identical.
3. `feat(hexagon)` verdict is a **success/failure block**, not `into:` :
   `charged_by("Stripe", on: "OrderPlaced") do ; success "Order.Authorize" ; failure "Order.Decline" ; end`
   Full replacement of into:. IR Binding.into -> success+failure ; parse_binding_body.rs.frag regenerated ;
   runtime/mod.rs record_effect_outbound reads binding.success/.failure ; pizzas + shop hecksagons migrated.
   Proven e2e : success exit -> Order.Authorize (authorized) ; STRIPE_DECLINE=1 -> Order.Decline (declined).

## B. NEXT — the IR generator (decided, NOT started)
The IR is DOUBLE-MAINTAINED : `rust/src/hecksagon_ir.rs` is hand-written and was hand-edited twice this
session in parallel with the grammar. Build a specializer that EMITS hecksagon_ir.rs from the grammar
(mirror `rust/src/specializer/ir.rs`, which emits ir.rs from an ir_shape fixture, byte-identical + golden).
18 IR structs ; the grammar models 5 (Hexagon/Family/Field/Adapter/Binding). **Push the other structs into
the grammar where it makes sense** (judgment ; some belong, some may not). Wrinkles : grammar uses
value-objects (verb: HowVerb) ; IR flattens to String — generator needs VO-flattening + name-mapping
(grammar `Field` -> IR `FamilyField`). Target : grammar edit -> regenerate IR -> no hand-edit.
**RENAME `hexagon.bluebook` -> `hecksagon.bluebook`** (Chris : the DSL term is hecksagon) as part of this phase.

## C. NEXT — NO DEMO, the adapter path is ALL REAL
- DELETE the stripe-handler demo fallback (on sq/stripe-real-transport it still fakes a `ch_unknown`
  authorize when no endpoint). Real transport ALWAYS ; endpoint REQUIRED ; fail loud if unset. A decline
  is a real 402, never a STRIPE_DECLINE toggle.
- WIRE THE ADAPTER-HOST DECLARATIVELY. Today `adapter-host <root> Stripe <handler-binary>` passes the
  handler binary as a CLI ARG — "which binary IS the Stripe adapter" is nowhere in the bluebook/world.
  Declare the handler binary + launch in .world / the adapter ; the host resolves it from the declaration.
  THAT is "all real" : no demo, no hand-wiring. (mock-gateway stays a TEST FIXTURE, not the demo path.)
- WIRING RECAP : the core NEVER calls the binary. On emit of an effect event, record_effect_outbound writes
  a pending OutboundEvent (delivery_id, adapter, payload, success_command, failure_command) and returns.
  The out-of-process adapter-host polls OutboundEvent.pending, claims, runs the handler
  (`echo payload | HANDLER`), exit code picks the branch, dispatches the verdict, marks delivered.

## D. Other pushed branches this session
`sq/stripe-real-transport` (real off-core POST + retry/backoff ; demo fallback still in it — remove per C) ·
`sq/filetool-offset-fix` (FileTool.Read honors offset/limit) · `sq/persistence-inventory-i728` ·
`sq/persistence-step2-heki` (adapter :heki on Conductor/Primitive/Bluebook). main pushed.

## E. HECKS_INFO / persistence cutover (still Chris's trigger, boot boundary)
`resolve_info_dir` reads HECKS_INFO env first, never .world — shadows every example's .world. Eliminating
it = step D / i745. THE DETONATOR : `cargo build --release` of a changed resolver IS the live cutover
(door shells fresh binary per call ; daemons hold boot-time binary + baked env) — would split-brain my
memory mid-write. Order : code-prep + cargo test (door untouched) -> stop overmind -> backup -> move data
to ~/.heki/miette -> THEN build release -> restart -> convergence check. Destructive half is Chris's
trigger. My organs are SAFE from the default flip — all 68 miette hecksagons declare a backend (60 heki /
8 memory / 0 default).
