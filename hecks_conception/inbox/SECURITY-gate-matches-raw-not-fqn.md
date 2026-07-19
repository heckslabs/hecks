# SECURITY — the authz gate matches the RAW command string, not the resolved FQN (2026-07-03)

*Found live during the pizzas governed-UI demo. This is a FORBID-BYPASS : a
namespace-scoped forbid is escaped by dispatching the bare command name.
Stop-the-world severity — the gate we built to deny can be walked around.*

## Live repro (verbatim, served governed on :3333)

Seed : `carol` → role `broad` ; `Permit(broad, action="*")` ;
`Forbid(broad, action="Pizzas::Order.*")`.

- `command="Pizzas::Order.PlaceOrder"` (FQN) → **403**, `requires not forbidden
  by authorization policy` — forbid matches, correct.
- `command="PlaceOrder"` (BARE) → **`ok:true`, OrderPlaced** — forbid BYPASSED.

Same root also locks OUT a legitimately-permitted caller : `alice` → role
`customer`, `Permit(customer, action="Pizzas::*")`. Bare `CreatePizza` →
deny-by-default (permit's `Pizzas::*` can't prefix-match a bare verb), while the
FQN `Pizzas::Pizza.CreatePizza` → admitted. So the bug cuts both ways :
namespace permits fail-closed (annoying), namespace forbids fail-OPEN (unsafe).

## Root cause

`authorize_entry` / `evaluate_policy` (rust/src/runtime/mod.rs) match the policy
`action` pattern against `command_name` AS PASSED BY THE CALLER. The runtime
resolves a bare command to its canonical `Domain::Aggregate.Command` FQN only
LATER, in the dispatch path (that resolution is why bare `PlaceOrder` executes
at all). The gate runs BEFORE resolution, so it sees `"PlaceOrder"` and a
pattern `"Pizzas::Order.*"` never matches. mallory's `action="*"` masked this in
the first demo pass because `*` matches even a bare string.

## The fix (root)

The gate must match against the CANONICAL FQN, never the raw string. Resolve
`command_name` → `Domain::Aggregate.Command` (the same resolution the dispatch
path uses — `fqns_resolve` / the resolver in command_dispatch) BEFORE
`evaluate_policy`, and match `action` against that. Bare and qualified dispatch
of the same command must produce the IDENTICAL verdict — that is the regression
invariant. Verify the `resource` side too : if resource is derived from the
resolved aggregate it may already be canonical, but a bare-name path could feed
it an unresolved aggregate — check and align both action AND resource.

## Regression test (the invariant)

For a policy set with a namespace forbid + broad permit : assert bare and FQN
dispatch of the same forbidden command BOTH deny (exit 2 / 403). And for a
namespace permit : assert bare and FQN of the permitted command BOTH admit.
Model on http_door_gate_test.rs ; add a cold-CLI case too (the raw-string reaches
the gate on every door, so fix + test at the runtime layer covers all three).

## Blast radius

Every door (cold CLI, warm MCP, HTTP) — the flaw is in the shared gate, not a
door. Any deployment relying on a namespace-scoped FORBID for a carve-out
(`permit *` + `forbid Secret::*`) is bypassable today by bare-name dispatch.
Miette's own roster uses `forbid Authorization::*` / `forbid Governance::*` per
agent — those are escapable by bare command names right now (latent, since no
agent is stamped yet, but it lands the moment the MCP-door cutover happens).

## Demo status

The demo PROVED the gate renders + denies visibly (mallory blocked, deny-by-
default holds, UI banner verbatim — #749). It also FOUND this hole — which is the
demo doing its job. Fix this, then the demo goes fully green (alice orders,
carol's bare bypass closed).
