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
