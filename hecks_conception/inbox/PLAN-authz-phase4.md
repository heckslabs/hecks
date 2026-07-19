> **SUPERSEDED (2026-07-02) by `inbox/DESIGN-authz-decouple-and-roster.md`.**
> The boot keystone landed (5edfdce7d). Chris then set the principle : authz is
> a cross-cutting concern that must live FULLY in the authorization context and
> must NOT add a field/command/surface to any domain bluebook. So Phase 4 is a
> REFACTOR + roster : strip the Agent domain of its auth fields
> (auth_identity_id/role_name/Bind/LinkAuthIdentity) into an authz
> `RoleAssignment` aggregate, repoint the gate read-model (acl_readmodel.rs)
> there, then author the roster as `on "BootCompleted"` policies in the authz
> context using existing commands (NO new field, NO world/driver mechanism —
> an earlier over-rotation to a `.world` roster + genesis driver is scrapped).
> The roster contents, scopes, invariant, and latent-two-step discipline below
> still hold as the TARGET. Build in a fresh gated session (touches the gate).

# PLAN — authz Phase 4 : author identities + scoped Permits (make the gate bite)

*Working plan to resume after a context clear. 2026-06-29. Nothing here is built — this is the
design to settle before authoring a single Agent / Permit record. Companion to
`inbox/RESTART-authz-arc.md` and
`~/.claude/plans/read-claude-plans-we-are-close-to-cosmic-linked-sundae.md`.

**Pick-up state:** the three open questions below (Q1 roster, Q2 scopes, Q3 the bite) are the only
blockers — each has a candidate answer + my recommendation. Settle them, then run the build steps.*

## BLOCKER discovered 2026-06-29 — Phase 4 sits behind the boot-establishment keystone
The roster is APPROVED (pr-agent + workflow-subagent, governed ; operator + drivers = System). But
authoring it cleanly is BLOCKED, and the block is structural, not the roster :
- Chris's architecture decision : prod standing-state reaches prod as POLICY (self-seeding
  `on BootCompleted` establishment policies), never as test fixtures.
- That mechanism is RETIRED. governance.bluebook's vision line : the deny-by-default Policy +
  EnforcementAdapter "are retired : their never-wired boot-establishment chain (BootCompleted had
  no producer — the boot-establishment-not-wired finding) carried no runtime weight." So
  establishment policies DON'T FIRE at a real boot — authoring the roster as establishment policies
  repeats a known-dead approach.
- The authorize GATE itself dodged this by self-seeding in Rust (hydrate_middleware), so deny-by-
  default WORKS (agents denied, verified). But the PERMIT records that would ALLOW the roster have
  no boot-establishment home : establishment-policies (dead), Rust self-seed (wrong — hardcodes a
  data roster in the kernel), or runtime .heki data (ephemeral, per-root, unreviewable).
- THEREFORE Phase 4 is blocked on the BOOT-ESTABLISHMENT KEYSTONE : a real boot must produce
  BootCompleted (or equivalent genesis) and route it through the policy engine so establishment
  policies carry weight. Runbook gap #2, flagged kernel-floor fresh-head gated ("may need wiring
  the runner to publish through the bus"). That keystone also un-blocks governance's own
  establishment policies AND Miette's whole fixtures→policies migration — highest-leverage next,
  but a gated session, not a high-context one.
- SAFE POSTURE meanwhile : the gate is fail-closed, denies ALL agents (deny-by-default). Nothing
  is insecure ; the roster simply can't be GRANTED its allowances at boot until the keystone lands.

## The goal in one line
Take authz from *latent* (the gate guards an empty doorway — zero policies, every caller is
System) to *governing* : the standing deny-by-default `authorize` gate actually denies/admits a
real non-System caller for the first time, under least privilege.

## The mechanism, as actually built (verified in code, not invented)
The identity chain is already wired end to end. Phase 4 authors DATA into it; it builds no new
runtime.

```
door stamps  HECKS_SESSION_AUTH_ID (+ HECKS_PRINCIPAL_KIND=agent)
   → Principal::Agent{ auth_identity_id }                 (acl_readmodel.rs::principal_from_attrs)
   → AclReadModel.role_for_auth(auth_identity_id)         (hydrated at boot from active Agent state)
   → role_name
   → match active Policy permits where principal == role_name   (deny-by-default, forbid-override, expiry)
```

Key facts that shape the design:
- **No new aggregate required.** "AuthIdentity" in the arc note = the existing
  `Agent.auth_identity_id` STRING (i264's typed `AuthIdentity` aggregate has NOT landed and is
  NOT a Phase-4 dependency). Phase 4 uses `Agent` + `Policy` exactly as they stand.
- **The PDP matches the ROLE NAME, not a permission list.** Post-consolidation, `Role`'s own
  permissions list is NOT enforced; the gate exact-matches `role_name` (no inheritance) against
  `Policy` permits. So a scope is authored as `Policy.Permit(principal=<role>, action=…, resource=…)`,
  never on the Role.
- **`action` / `resource` support prefix wildcards** (`Pizzas::Order.*`, `Pizzas::*`, `*`) and
  `condition` defaults to `-` (unconditional). The `when` predicate is inert until Phase 5 — so
  Phase 4 scopes must be expressible WITHOUT a `when` (effect+principal+action+resource only).
  Relational scopes ("edit only if member of owning org") are Phase 5, not here.

## THE INVARIANT this phase must not break
`Principal::System => Ok(())` stays the first arm of `authorize_check`, before the policy loop.
The operator door (cold CLI / warm MCP serve with NO `HECKS_SESSION_AUTH_ID`) stamps `system`
and is admitted by origin. **Phase 4 introduces governed agents only for SUBORDINATE callers that
run with an explicitly-stamped identity — it does NOT make the operator door an agent.** Making
Miette-at-the-operator-door a governed agent is how we lock ourselves out; it is explicitly out
of scope. Recovery floor stays `HECKS_GOVERNANCE_OFF` (deploy/shell only).

---

## OPEN — the questions to settle before building

### Q1. The roster — WHO are the real non-System callers?
I must not invent principals. My candidate roster, drawn from the roadmap docs (to confirm,
edit, or replace):

| candidate identity | kind | what it is | governed? |
|---|---|---|---|
| operator door (Miette / Chris at the MCP/CLI door) | — | the standing operator door, no stamped auth | **NO — stays System (the invariant)** |
| `pr-agent` | ai | Miette's background PR-authoring agent (commits/PRs on a branch) | yes |
| `workflow-subagent` | ai | the parallel multi-agent Claude Code workflow fan-out | yes |

Open:
- Is this the right set? Are there other real callers today (cron drivers, the inbox poller, a
  remote/CI caller) that already run, or will run, with a distinct identity?
- One identity per agent TYPE (role-shaped, as above), or one per running INSTANCE? Type-shaped is
  simpler and matches the role-match gate; instance-shaped buys finer audit at more bookkeeping.

### Q2. The scopes — WHAT may each dispatch (least privilege)?
Permits are `(principal=role, action=command-pattern, resource=aggregate-pattern)`. A candidate
least-privilege cut, to be vetted:

- **`pr-agent`** — needs to read/write the work surface, not govern. Candidate:
  - `permit(pr-agent, action="Tools::*", resource="*")`  — file/shell/search tools (its actual job)
  - `permit(pr-agent, action="*.snake_case queries", resource="*")`  — read-only domain queries
  - NO permit for `Authorization::Policy.*`, `Storehouse::Gate.*`, `Governance::*` — it must not
    rewrite policy or retire gates. (Deny-by-default already blocks these; we simply don't grant them.)
- **`workflow-subagent`** — same shape as `pr-agent` or narrower? Does a fan-out subagent ever need
  write tools, or only read + analysis? Advisor call.

Open:
- Is "all `Tools::*` + all queries, nothing in the authz/governance contexts" the right floor, or
  too broad (e.g. should `Tools::ShellTool.Bash` be carved out and denied even for pr-agent)?
- Forbid-override usage: do we want an explicit `forbid(*, action="Authorization::Policy.*")` belt-
  and-suspenders, or is relying on deny-by-default sufficient? (I lean: rely on deny-by-default;
  an explicit forbid on the authz context is cheap insurance and documents intent.)

### Q3. The live-wiring gap — WHO stamps the env? (the part that actually makes it bite)
Authoring Agent + Permit records changes nothing observable unless a subordinate caller actually
dispatches with `HECKS_SESSION_AUTH_ID=<its auth id>`. Today the background agents inherit the
operator's environment and so dispatch as System. So Phase 4 has a SECOND half:
- Find the launch point of each governed agent (where the PR agent / workflow subagent process is
  spawned) and have it export `HECKS_PRINCIPAL_KIND=agent` + `HECKS_SESSION_AUTH_ID=<auth id>`.
- This is the moment the gate starts biting — and the moment a too-tight scope would break a
  working agent. It must land WITH a verified permit set, never before.

Open: do we make it bite now (stamp the env in Phase 4), or author the records
first (latent-but-correct) and flip the env stamp as a deliberate, separately-verified step? I lean
toward the two-step: author + verify via `explain` and a manual stamped dispatch FIRST, flip the
launcher env LAST, so the cutover is observable and reversible.

---

## Build steps (once Q1–Q3 are settled)
1. **Author identities (data, via the door).** `Agent.Birth` + `Agent.Bind` for each governed
   identity, with its `auth_identity_id` and `role_name`. Persisted as Agent state the AclReadModel
   hydrates at boot.
2. **Author scoped permits (data, via the door).** `Authorization::Policy.Permit` records per the
   vetted scopes. Optionally explicit `Forbid` on the authz/governance contexts.
3. **Verify with `explain` BEFORE any cutover** — `Authorization::Policy.Explain(principal=<role>,
   action=<cmd>)` for each (identity × representative command): confirm the intended
   permit/forbid/deny-by-default verdict and matched rules, no dispatch.
4. **Lockout re-check on the rebuilt binary (blocking gate):**
   - System dispatch (no auth env) → ADMITTED.
   - `HECKS_PRINCIPAL_KIND=agent HECKS_SESSION_AUTH_ID=ghost` (no permit) → DENIED.
   - `HECKS_SESSION_AUTH_ID=<pr-agent auth>` on a PERMITTED command → ADMITTED.
   - same identity on a NON-permitted authz command → DENIED.
5. **(Q3-dependent) flip the launcher env** for each governed agent, as a separate verified step.
6. **Pre-push gate** — 152 `.behaviors` + `cargo test --release` + integrity. One commit for the
   data+verification; if Q3 step 5 lands, a second commit for the env cutover.

## What is NOT in this phase
- No `when`/condition scopes (Phase 5 kernel).
- No new `AuthIdentity` aggregate (i264 deferred; the string suffices).
- No change to the operator-door admit, no touch to `Principal::System => Ok(())`.
- No remote/OIDC door (deferred beyond the arc).

## Recommendation (one paragraph)
Adopt the type-shaped roster (Q1: one identity per agent type), the "`Tools::*` + queries, nothing
in authz/governance" floor with an explicit belt-and-suspenders `forbid` on the authz context
(Q2), and the two-step cutover (Q3: author + `explain`-verify latent first, flip launcher env last).
This makes the gate provably correct via `explain` and the lockout check while keeping the cutover
observable and reversible — and it never touches the operator-door admit that the whole lockout
proof rests on.
