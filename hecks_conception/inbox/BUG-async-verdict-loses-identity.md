# BUG — the async payment verdict re-enters WITHOUT the originating order's id (2026-07-03)

*Found when Chris eyeballed a PlaceOrder cascade in the served pizzas UI. This
breaks the REFERENCE async-boundary pattern — the Pizzas exemplar every domain
copies — so the defect propagates to every future charged_by/effect binding.*

## Observed (live, served demo)

`PlaceOrder` on Order #5 → cascade :
```
OrderPlaced            Order#5
OutboundEventRecorded  Order::5::OrderPlaced::Stripe
OutboundEventRecorded  Order::5::OrderPlaced::Stripe   <- DUPLICATE (same id)
OutboundEventClaimed   Order::5::OrderPlaced::Stripe
OrderAuthorized        Order#6                          <- WRONG AGGREGATE
OutboundEventDelivered Order::5::OrderPlaced::Stripe
```
Resulting state :
- Order #5 : customer=probe, status=**pending**, payment_ref=—  (the real order, STRANDED)
- Order #6 : customer=**empty**, status=**authorized**, payment_ref=ch_unknown  (PHANTOM)

## Bug A (correctness, serious) — verdict mints a phantom instead of transitioning

The Stripe success verdict re-enters via storehouse as `Order.Authorize`, but
WITHOUT `reference_to Order = 5`. `Authorize` is a transition command (upsert on
identity) ; with no id it inserts a NEW Order (#6, customer-less) and transitions
THAT to authorized. The customer's real order (#5) never authorizes.

The origin id is RIGHT THERE — the OutboundEvent aggregate_id is
`Order::5::OrderPlaced::Stripe`. The delivery / verdict re-entry path
(outbound-event handler + the hexagon `success "Order.Authorize"` binding) must
thread that origin id into the re-dispatched verdict command as its
`reference_to` id. Today it doesn't, so identity is lost at the async boundary.

WHERE to look : the outbound-event delivery in the runtime (OutboundEvent
Claimed → Delivered path) + how `success`/`failure` verdict commands are
constructed from the binding (pizzas.hecksagon `charged_by("Stripe", on:
"OrderPlaced") do success "Order.Authorize" ... end`). The binding likely needs
to carry the origin aggregate id (parseable from the OutboundEvent id, or
carried in its payload) into the verdict attrs. May be a framework gap (the
binding grammar can't express id-propagation) OR a delivery-path omission —
determine which ; if grammar, that is a Pizzas-exemplar extension per the
standing “everything references Pizzas” rule.

## Bug B (minor) — OutboundEventRecorded fires twice

Same outbound id recorded twice in one cascade. Idempotent by id (no durable
double row), but the double-record is wrong — the binding or the record path
emits it twice. Likely the same OrderPlaced reaching the charged_by binding
twice (cf. the historical multi-trigger fan-in) ; confirm it's not a real
double-charge risk once a live adapter host is attached.

## Scope / severity

- NOT the authz work (#750) — this is the hexagon async-boundary, orthogonal.
- HIGH leverage : Pizzas is the canonical async-boundary reference. A broken
  verdict-identity here is copied into every charged_by/effect domain. The
  system-prompt exemplar text asserts “the verdict re-enters the domain as a
  plain Authorize / Decline command” — it must re-enter ON THE SAME AGGREGATE.
- Needs a deliberate session (framework verdict-identity propagation + a
  regression test : PlaceOrder → exactly one Order, transitioned pending→
  authorized, no phantom, single OutboundEventRecorded).

## ROOT CAUSE (verified in code 2026-07-03)

- The binding declares `success "Order.Authorize"` / `failure "Order.Decline"`
  with NO attrs (examples/pizzas/bluebook/pizzas.hecksagon:70-73).
- The verdict dispatch attrs are built in
  `rust/src/runtime/driven_adapter_resolver.rs` (`enumerate_driven_dispatches`
  / `resolve_driven_adapters_at_depth`) from `dispatch.attrs` interpolated by
  `interpolate_event` (line 339). That interpolator ALREADY supports `{id}` and
  `{aggregate_id}` = the ORIGIN event's aggregate_id (lines 344-345). The
  binding just never uses them, so the verdict carries no id → Authorize
  (transition, upsert-on-identity) inserts a NEW Order.
- payment_ref=ch_unknown DID land on the phantom — the wrapped/world canned
  value merges in fine ; only the self-identity is missing.

### Two fixes

- **Shallow (bluebook)** : `success "Order.Authorize", id: "{id}"` (+ failure).
  Works via existing interpolation, zero runtime change — but a FOOTGUN : every
  domain copying the exemplar must remember it, and forgetting silently mints
  phantoms (what happened here).
- **Right (runtime, RECOMMENDED)** : a `charged_by`/effect VERDICT
  (`do success/failure end`) re-enters BY CONTRACT on the same aggregate that
  emitted the triggering event. The resolver should auto-inject the origin
  `aggregate_id` as the verdict command's self-reference id UNLESS the binding
  declares one. SCOPE CAREFULLY : a `for_each` driving dispatch (Kitchen sweep)
  legitimately targets OTHER aggregates by query — those must NOT inherit the
  origin id. So the injection applies to the effect-binding success/failure
  verdict path ONLY, not to driving/for_each dispatches. VERIFY the IR marks
  verdict dispatches distinctly from driving dispatches before implementing ;
  if it doesn't, thread a flag from the hecksagon parser (charged_by
  success/failure) through to the resolver.

### Bug B (double OutboundEventRecorded) — investigate together

Same outbound id recorded twice per cascade — likely the resolver enumerating
the handler on both the eager and the outbox/pump pass, or OrderPlaced reaching
the binding in two cascade passes. Check `enumerate_driven_dispatches` vs
`resolve_driven_adapters_at_depth` — are BOTH firing for one event? Idempotent
by id today, but a real double-charge risk once a live adapter host runs.

## Repro

Serve pizzas governed (or open), place an order as a permitted caller, read the
cascade + `state Order <n>` / `state Order <n+1>` : the n+1 phantom + stranded n
is the signature.
