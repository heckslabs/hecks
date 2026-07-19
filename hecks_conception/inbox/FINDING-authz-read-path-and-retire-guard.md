# FINDING — two authz observations from the Phase 6 lockout check (2026-06-29)

*Surfaced while verifying Phase 6 Half A (gating.family) against the live binary. BOTH are
pre-existing and SEPARATE from the Phase 6 vocabulary change. The command-path lockout invariant
itself HOLDS — verified live : System admitted, agent ghost DENIED (exit 2, Violation recorded).*

## 1. [CLOSED 2026-06-29, commits 1830973eb + 6b5b019dc] Read paths admitted an unpermitted agent
Fixed across ALL caller-facing data-read doors :
- cold-CLI query (`dispatch_hecksagon`, both resolve_query sites) — 1830973eb
- cold-CLI by-id read (`cmd_state` / `storehouse__state`) — 6b5b019dc
- warm serve query (`run_serve::handle_request` is_query branch, the DEFAULT MCP path) — 6b5b019dc
Each now stamps the principal + runs `authorize_entry` (exit 2 / ERROR sentinel on deny), mirroring
the command path. Regression locked by `cli/tests/cold_read_gate_test.rs` (query + state, agent
denied / System admitted). Completeness sweep confirmed the remaining rt.find sites are non-doors
(post-dispatch state echoes + the verify-projection audit gauge), not caller data-read doors. The
warm gate shares the authorize_entry covered by authorize_pdp_test::query_deny_by_default + the
cold test ; a dedicated warm test is omitted to avoid an env-race flaky test (daemon-spawn harness
is the follow-up). Original write-up below.

## 1. The cold-CLI QUERY path admits an unpermitted agent (read-bypass?)
Observed (governance ON, HECKS_GOVERNANCE_OFF unset) :
```
HECKS_PRINCIPAL_KIND=agent HECKS_SESSION_AUTH_ID=ghost \
  storehouse <root> 'Authorization::Policy.active'
-> exit 0, returns the rows   (ADMITTED)
```
but the COMMAND path with the same principal is correctly denied :
```
... storehouse <root> 'Authorization::Policy.Retire' id=x
-> exit 2  GOVERNANCE (authz): ... denied : requires an authorization permit ; caller ghost
```
The runtime HAS a gated read entry (`mod.rs` ~3786, `authorize_entry` in the query path), and the
self-seeded `authorize` gate has pattern "*". So either the cold-CLI query path does not route
through that gated read entry, or the gate's before_matching doesn't match the query phrase. The
arc INTENDS reads to be gated (explain : "the caller's access is gated like any read ; agents are
denied, so explain is not a policy-enumeration oracle"). If plain queries are ungated at the cold
door, an unpermitted agent can READ any aggregate — a real authz hole once Phase 4 makes the gate
bite real agents. NEEDS : confirm whether the cold-CLI query path calls the gated read entry ;
if not, wire it (same authorize_entry the command path uses). Re-run the lockout check after.

## 2. [NOT A BUG — by-design upsert, 2026-06-29] `Policy.Retire` on a nonexistent id returns ok:true
Re-diagnosed : this is the documented UPSERT-keyed-on-identity semantics (Relationship chapter :
"absent -> insert ; present -> update" ; command_dispatch.rs:246 "absent -> insert"). Retire on a
missing id INSERTS a default Policy — whose `status` defaults to "active" — so the
`given("status == active")` guard PASSES against the freshly-inserted default and retires it. The
guard WAS enforced ; my original "guard not enforced" framing was wrong. Whether a transition
command SHOULD upsert-then-act on an absent target (vs hard-error "no such X") is a framework
design question, not an authz bug — and changing it touches every transition command, not this one.
Leaving as-is. Original write-up below.

## 2. `Policy.Retire` on a nonexistent id returns ok:true (given-guard not enforced?)
Observed :
```
storehouse <root> 'Authorization::Policy.Retire' id=__probe_nonexistent__
-> ok:true, state.status="retired" (all other fields empty)
```
Retire declares `given("rule must currently be active") { status == "active" }` — a nonexistent
rule has no active status, so the guard SHOULD have blocked it. It did NOT persist a row (no
policy.heki contains the id ; active set stayed empty), so the durable damage is nil — but the
ok:true response is misleading and suggests the `given` precondition is evaluated against a
default/empty load rather than failing closed on a missing aggregate. NEEDS : confirm whether
`given` guards fail closed when the referenced aggregate is absent ; if a missing reference_to
target should hard-error (not load an empty default), that is the fix. Likely a general
reference_to-load-vs-given-guard question, not authz-specific.

## Disposition
Neither blocks Phase 6 Half A (shipped, ec5246efc). #1 is the more important — it is an authz
read-bypass that matters the moment authz governs real agents (Phase 4). #2 is a smaller
guard-semantics question, broader than authz. Both are fix-when-prioritized, not stop-the-world
today (authz is still latent : zero policies, operator door is System).
