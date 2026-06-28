# RESTART — the auth door (decoupled Cedar PDP) — 2026-06-27

## What this is
Authn/authz at the storehouse dispatch door. The gate MECHANISM (middleware
stack) + the EXTERNALIZED, decoupled Cedar-shaped Authorization PDP — multi-team,
no per-command roles, evaluated in-process. Chris's directives that shaped it :
bluebook-first ; "it can all be storehouse service" (no DSL) ; "do the decoupling
now, ready for multiple teams out of the gate" ; "don't stomp on other agents" ;
no in-gate backdoor (Trusona time-bounded grants ; OIDC identity).

## LANDED on origin/main (all ff-only `HEAD:main`, no stomp on the parallel session)
Hashes (newest first) :
- 7865e5b46  bootstrap chain proven end-to-end + `authorize` is CANONICAL (rbac-authorize LEGACY)
- 770f85143  deploy-floor recovery (HECKS_GOVERNANCE_OFF stands gates down ; no backdoor)
- e32a4ca34  query-path gating (reads gated symmetrically with writes)
- 2e2352624  externalize authz — Cedar-shaped PDP (decoupled, multi-team)
- c9416f6aa  (earlier arc) Gate grammar + AuthIdentity conception
- f93e7a6c8 / 52e41ef0f / 4c7683e2e  (earlier) vetoing stack / registry hydration / authenticate gate

## Design (as built)
- DOOR : every command AND query flows through one dispatch ; `dispatch`(gated)/`dispatch_impl`(ungated) and `query`(gated)/`resolve_query`(ungated). Gate-checks use the ungated core, so no gate re-gates itself.
- GATE STACK (MiddlewareStack) : declared Gates (Gating::Gate, declared via Gate.Declare — NO DSL), boot-hydrated, vetoing before-gates. run_gate resolves a check key : `authorize` (PDP, CANONICAL), `authenticate` (active AuthIdentity), `rbac-authorize` (LEGACY role-on-command), OR any bluebook query (`Aggregate.Query`, allow-iff-row).
- PDP (Authorization domain) : Cedar rules `Policy{effect:permit|forbid, principal, action, resource, when, expires_at}`. Permit/Forbid (forbid overrides) / Retire / Active. Deny-by-default. principal matches "*"/auth_id/role. expiry via clock::now. `when` = FRONTIER (needs kernel-interpreter ; first cut : permit applies only if condition "-").
- BOOTSTRAP : System origin (admitted by origin) establishes identity + permit at session start — non-circular (never authenticate-to-authenticate). Gates declaration-gated (off until declared) so nothing breaks until policy authored.
- RECOVERY : HECKS_GOVERNANCE_OFF (deploy floor, not a credential) stands gates down. NO in-gate backdoor.

## Key files
- aggregates/framework/authorization/authorization.bluebook (+.behaviors 7/7) — the PDP
- aggregates/framework/agent/auth_identity.bluebook (+.behaviors 8/8) — identity
- aggregates/language/grammar/gating.bluebook (+.behaviors 7/7) — the Gate registry
- rust/src/runtime/mod.rs (EXEMPT) — run_gate, authorize_check (PDP eval), authenticate_check, service_gate, query (gated), authorize_entry (gate loop + HECKS_GOVERNANCE_OFF), hydrate_middleware
- rust/src/runtime/middleware.rs (EXEMPT) — the vetoing MiddlewareStack
- rust/tests/: authorize_pdp_test (9), session_bootstrap_test (3), gate_recovery_test (1), authenticate_gate_test (3), service_gate_test (3), gating_registry_test (3), deciderate_acl_test (7) — all green
- runtime/dispatch/dispatch.bluebook — the storehouse-as-bluebook (MiddlewareStack aggregate ; gating.bluebook should eventually reconcile INTO it)
- PLAN : ~/.claude/plans/we-ll-need-a-way-dynamic-pearl.md (full sequence + perfection-game + deep-research critiques + Trusona/OIDC + isolation)
- INVENTORY : hecks_conception/inbox/storehouse-self-hosting-inventory.md (runtime self-hosting map ; NOTE correction: command_dispatch/reaction/aggregate_state ARE golden — already projected ; the NOT-golden runtime set is middleware/policy_engine/pm_engine/acl_readmodel)

## REMAINING (genuinely separate work)
1. OIDC client / identity minting NEAR THE CHROME — validate the JWT at the web edge (rust/src/server/), sub->id, exp->grant TTL, claims->role. Real (b) integration ; server work, not a runtime slice.
2. FULL corpus role-strip sweep — remove `role` from every domain command (authorize PDP supersedes rbac-authorize). BROAD + collides with the active governance session — do when corpus is QUIET.
3. Legible-deny — extend Governance::Violation with gate+cause. DEFER : the other session is in governance/macrophage.
4. `when`-condition evaluation — waits on the kernel-interpreter grammar frontier (shared with extraction.bluebook).
5. Reconcile gating.bluebook (Gate) INTO runtime/dispatch MiddlewareStack ; relocate from language/grammar to runtime/dispatch.

## HOW TO CONTINUE (isolation — don't stomp the parallel governance session)
- Work in a fresh worktree off origin/main.
- Land ff-only : `git push origin HEAD:main` from the worktree (NEVER reset/merge local main — that races the other session). Rebase onto origin/main before pushing if it moved ; overlap-check.
- Worktree pushes DEFER the behaviors gate to CI ("CI is authoritative") ; run cargo test --release + the gate tests locally.
- A parallel session is actively on governance/macrophage on main — avoid governance files.
- Current worktree : .claude/worktrees/authz-pdp (branch worktree-authz-pdp) — may be removed ; recreate fresh.
