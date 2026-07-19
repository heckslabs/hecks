# PLAN — The outbox is middleware, not domain injection

**Decided with Chris, 2026-07-18.** A user's bluebook must hold ONLY the SME's
ubiquitous language (see standards.md "The bluebook holds only the SME's
ubiquitous language"). Today the runtime INJECTS the framework `OutboundEvent`
aggregate into every effect-emitting domain's IR — so ToolShed's served page
shows `Outbound Event` beside Tool/Member/Loan. The tool-shop owner never says
"outbound event." It must not be in their domain. Fix : the outbox becomes a
shared storehouse middleware, applied generically AROUND the domain — wired
exactly like the Gate/authorize middleware already is.

**Aligns with an already-conceived plan** : `event_sourcing.bluebook` vision
already says "OutboundEvent becomes a read model of undelivered events,
CascadeRun an event-reactive consumer, dispatch_audit a pure audit projection."
This card executes that intent.

## The mechanism today (recon 2026-07-18, all in rust/src/runtime/mod.rs)
- `ensure_outbox_substrate` (mod.rs:434-457) : parses the compiled-in
  `OUTBOX_SUBSTRATE` (`include_str!("../../resources/outbound_event.bluebook")`,
  mod.rs:420) and PUSHES each aggregate into `domain.aggregates` — gated on
  `has_effect` (any hecksagon binding with a non-empty `on:`). This is the
  injection.
- Call site : `boot_with_hecksagons` (mod.rs:373). NOT called on the bare
  `boot_with_data_dir` path — so injection only happens with hecksagons + an
  effect binding.
- The drain : `record_effect_outbound` (mod.rs:1250 call inside `dispatch_impl`;
  def 1754-1857). BAILS if `self.domain.aggregates` has no `OutboundEvent`
  (mod.rs:1759 — the coupling), else dispatches
  `Hecks::Framework::Hexagon::OutboundEvent::OutboundEvent.Record` via
  `dispatch_cascade` onto the SAME runtime / the injected aggregate (mod.rs:1847).
- Storage : ordinary records of the (injected) OutboundEvent aggregate, in the
  user domain's own repository set.
- Delivery : `run_host/mod.rs` (`storehouse host`) reads `rt.all("OutboundEvent")`
  filtered to pending, Claims (pending→claimed at-least-once guard), execs the
  handler, verdicts success/failure, MarkDelivered/MarkFailed. Already generic —
  reads by aggregate name, dispatches lifecycle by name. UNAFFECTED by moving the
  aggregate to a shared realm.
- In-process variant : `drain_outbound_to_quiescence` (embed.rs:268,
  routes.rs:246) drains inline via the same run_host handler.

## The pattern to mirror — the GATES (never injected, applied generically)
- `MiddlewareStack` is state on the Runtime (mod.rs:241), NOT in any domain.
- `hydrate_middleware` (mod.rs:1021-1060) reads every active `Gate` via
  `self.all("Gate")`, builds `MiddlewareEntry{name,phase,handler,pattern,order}`,
  self-seeds a standing `authorize` before-gate if none. Re-run whenever a `Gate`
  lifecycle command applies (mod.rs:1105). Called on EVERY boot path.
- Applied per-dispatch at the door : `authorize_entry` (mod.rs:694-724) runs
  `self.middleware.before_matching(command)` by pattern ; a Deny aborts. No
  domain aggregate is ever touched.
- `middleware.rs` already defines `Phase::After` — but notes it is NOT WIRED
  (no after-gates exist yet). The outbox is the first After-gate.

## The refactor (fresh-head, gated worktree, KERNEL-FLOOR)
1. **Delete the injection** : remove `ensure_outbox_substrate` + `OUTBOX_SUBSTRATE`
   (mod.rs:420-457) and its call at mod.rs:373. User domains stop carrying
   OutboundEvent.
2. **OutboundEvent becomes a standing framework aggregate** — runtime-owned,
   like Gate / Violation. The runtime always has the outbox repository (in a
   framework realm), read via `self.all("OutboundEvent")`. The drain's
   `self.domain.aggregates` guard (mod.rs:1759) becomes "the framework outbox
   always exists."
3. **`record_effect_outbound` becomes an AFTER-phase middleware entry** — wire
   `Phase::After` in middleware.rs, hydrate an outbox after-gate the same way
   `hydrate_middleware` hydrates gates, and move the mod.rs:1250 hook into the
   after-middleware loop. The recording logic (binding match, delivery_id,
   verdict command qualification) is unchanged — only its HOME moves from a
   hardcoded dispatch hook to a generic after-gate.
4. **Delivery host** : unchanged (already generic).
5. **Served UI** : ToolShed page now shows only Tool/Member/Loan — the symptom
   that started this — with NO page-filter needed, because the substrate was
   never in the domain.

## Gates to run (kernel-floor)
- Full `cargo test --workspace` (the effect/outbox/host tests : run_host,
  drain_outbound, dispatch_cascade, the effect binding integration tests).
- Parity (dump.rs / canonical_ir.rb : make sure removing the injected aggregate
  doesn't change canonical IR for effect domains — it SHOULD, that's the point ;
  update goldens that pinned the injected OutboundEvent).
- Behaviors corpus.
- Live : boot the pizzas / bin-buddy effect example, dispatch an emitting
  command, confirm delivery still works via `storehouse host` AND the domain IR
  no longer contains OutboundEvent.

## The generalization (its own standard, once proven here)
ANY framework substrate the runtime injects into a user domain is the same bug.
The storehouse applies cross-cutting concerns as MIDDLEWARE ; it never mutates
the user's domain IR to carry them. Outbox is the first ; audit / cascade-run
(per event_sourcing vision) follow the same move.
