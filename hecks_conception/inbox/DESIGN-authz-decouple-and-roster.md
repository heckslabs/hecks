# DESIGN HANDOFF — authz decoupled from Agent + the roster (Phase 4, corrected)

*For a fresh, gated kernel session. Touches the gate read-model
(`acl_readmodel.rs`) — kernel. Designs the refactor + roster ; a follow-up
session builds it. SUPERSEDES the earlier "establishment-mechanism" design
(world roster + genesis driver) — that was an over-rotation and is fully scrapped :
no `.world` roster, no genesis driver, no new field/surface. None of it is wanted.*

## The principle (Chris, 2026-07-02)

Auth/authz is a cross-cutting concern. Supporting it must NOT require adding a
field, command, or surface to a domain bluebook — and it must live FULLY in the
authorization context. The **Agent domain** ("a being that dispatches") must not
carry auth : no `auth_identity_id`, no `role_name`, no `Bind`/`LinkAuthIdentity`.
Business domains carry no authz (the authorization vision already says so). The
gate reads ONE context : authorization.

Bluebook IS the home for the roster SHAPE — establishment policies using EXISTING
commands. What's forbidden is adding fields/surfaces to SUPPORT authz. (The
earlier over-rotation invented a `.world` roster + a genesis driver kind to avoid
putting the roster in a bluebook — wrong reading. Bluebook is fine ; just don't
pollute domains with auth, and keep authz fully external to Agent.)

## Current state (verified in code)

- **Agent** (`aggregates/framework/agent/bluebook/agent.bluebook`) carries auth :
  `attribute :auth_identity_id`, `attribute :role_name` ; `command "Bind"` (sets
  role_name), `command "LinkAuthIdentity"` (sets auth_identity_id). `identified_by :name`.
- The gate's RBAC read-model (`rust/src/runtime/acl_readmodel.rs`) hydrates
  `role_for_auth: HashMap<auth_identity_id, role_name>` by walking `rt.all("Agent")`
  (`hydrate`), skipping retired + requiring BOTH fields non-empty.
- Gate (`rust/src/runtime/mod.rs` `evaluate_policy` ~903) : principal matches
  `"*" | auth_id | role_name` ; action/resource prefix-glob
  (`middleware::pattern_matches`) ; forbid overrides ; condition must be `"-"`.
  **Authz gates the ENTRY dispatch only, NOT cascades** (mod.rs:1054).
- The door stamps `HECKS_SESSION_AUTH_ID` → `Principal::Agent{auth_identity_id}`
  (`acl_readmodel.rs` stamp-from-env) — ENV-driven ; it does NOT read the Agent
  record. So stripping Agent's auth fields does not touch the stamping path.
- The keystone (5edfdce7d) routes `BootCompleted` through the policy engine —
  establishment policies fire at boot. USE AS-IS ; no new boot capability needed.

## The refactor (four moves)

### 1. Strip Agent to pure identity
`agent.bluebook` : remove `auth_identity_id`, `role_name` attributes, the
`Bind` + `LinkAuthIdentity` commands, and the now-unused `AuthIdentityId` /
`RoleName` value objects. Agent = `{name, description, kind, status}` — keep
`Birth`, `Retire`, the status lifecycle. Update `agent.behaviors` (drop the
Bind/Link cases).
**CHECK CONSUMERS FIRST** : grep `auth_identity_id`, `role_name`, `"Bind"`,
`"LinkAuthIdentity"` across `rust/src` + bluebooks + behaviors. Anything reading
`Agent.role_name`/`auth_identity_id` must move to the authz source (move 2). The
`Dispatched`/`dispatched_by` provenance uses the agent NAME (still present) —
verify it's unaffected.

### 2. Authorization owns identity↔role
Add a small aggregate to the authorization context (`authorization.bluebook` or a
sibling in `aggregates/framework/authorization/`), e.g. **`RoleAssignment`** :
`identified_by :auth_identity_id` ; attributes `auth_identity_id`, `role_name`,
`status` (active/retired) ; commands `Assign` (upsert auth_id→role), `Unassign`.
This is where RBAC's identity→role lives now — preserves the vision's RBAC
("roles keep RBAC ; sub keeps direct grants") while getting it OUT of Agent.

### 3. Repoint the read-model
`acl_readmodel.rs` `hydrate()` : read `rt.all("RoleAssignment")` instead of
`rt.all("Agent")`, building the SAME `auth_identity_id → role_name` map.
`evaluate_policy` UNCHANGED. This is a repoint (~one loop), not a rewrite. Move
the re-hydrate trigger from Agent-lifecycle to RoleAssignment/Policy-lifecycle.

### 4. The roster (establishment, authz-context only)
A bluebook of `on "BootCompleted"` policies (in the authorization context or a
dedicated roster bluebook WITHIN authz — never a business domain) authoring authz
records via EXISTING commands + `with` literals :
- `RoleAssignment.Assign` (auth_identity_id=<agent>, role_name=<role>) per agent
- `Policy.Permit` (id, principal=<role>, action="Tools::*", resource="*", condition="-", expires_at="-") per agent
- `Policy.Forbid` (id, principal=<role>, action="Authorization::*" / "Governance::*", …) per agent
No Agent commands, no new field, no new runtime capability. Type-shaped :
`pr-agent`, `workflow-subagent` (role == auth_id == name) ; operator + drivers
stay System. Order-independent + idempotent (re-asserts each boot).

## LATENT (Q3 two-step)
Author + verify ONLY. Do NOT flip launcher env stamps — no real agent dispatches
as governed yet. The env cutover (export `HECKS_PRINCIPAL_KIND=agent` +
`HECKS_SESSION_AUTH_ID=<id>` at each agent's spawn point) is a SEPARATE,
reversible, verified step.

## Invariant (never violate)
`Principal::System => Ok(())` stays the first arm of `authorize_check`. Re-run
the lockout on the rebuilt binary : System (no auth env) ADMITTED ; agent ghost
(`HECKS_PRINCIPAL_KIND=agent HECKS_SESSION_AUTH_ID=ghost`) DENIED (exit 2). Plus
the four-case : System admit ; ghost deny ; pr-agent on `Tools::*` admit ;
pr-agent on `Authorization::*` deny.

## Verification
- Boot a corpus with the roster ; assert RoleAssignment + Policy records exist,
  `role_for_auth("pr-agent") == "pr-agent"`, `evaluate_policy` admits `Tools::*`
  and denies `Authorization::*` for pr-agent. Model on `boot_completion_test.rs`.
- `explain` dry-runs per (identity × representative action).
- Lockout re-check + four-case stamped dispatch (above).
- **Parity** : agent.bluebook + authorization.bluebook shape changes keep
  Ruby/Rust dump goldens byte-equal ; behaviors updated (not deleted to hide).
- Pre-push : 152 `.behaviors` + `cargo test --release` + integrity ; ff-only push.

## Open decisions for the fresh head
1. **Role layer** : keep it (RoleAssignment in authz — RECOMMENDED, preserves
   RBAC) vs drop roles and key permits by `auth_id` directly (evaluate_policy
   already matches `p == auth_id`, so `acl_readmodel.rs` could be DELETED —
   simpler, but removes role-grouping the authz vision wants).
2. **Roster home** : top-level policies inside `authorization.bluebook` vs a
   dedicated roster bluebook in the authz context.
3. Whether Agent records are still authored for provenance (separate from authz)
   — likely yes, but NOT by the roster.

## Key files
- `aggregates/framework/agent/bluebook/agent.bluebook` (strip auth) + `.behaviors`
- `aggregates/framework/authorization/authorization.bluebook` (add RoleAssignment
  + the roster policies) + `.behaviors`
- `rust/src/runtime/acl_readmodel.rs` (repoint hydrate to RoleAssignment)
- `rust/src/runtime/mod.rs` (evaluate_policy — reference, likely unchanged ;
  re-hydrate trigger)
- Reference (unchanged) : `rust/src/run_boot/complete.rs` (keystone boot fire)

---

## REVIEW ADDENDUM (2026-07-02, Miette — verified against live code)

**Verdict : right track.** Every current-state claim above checks out against the
code (agent.bluebook auth fields ; `hydrate()` walks `rt.all("Agent")` ; stamp is
env-only, never reads Agent ; System first arm gate-side ; entry-only gating ;
keystone proven by `boot_completion_test.rs` ; policy `with` literals supported by
`policy_engine.rs` ; Permit/Forbid upsert by id). The scrapped over-rotation was
wrong by the Pizzas grammar exactly as stated : `.world` holds adapter VALUES never
domain records ; Drivers are clocks, BootCompleted is an event — event-reactive
policies are the existing, tested shape (`StartStudioOnComplete`).

**Goal context (Chris, 2026-07-02) : client apps CONNECT TO THE STOREHOUSE to use
bluebooks, gated by auth/authz at the door.** Do NOT extend Pizzas — match it. The
client app is a CALLER at the door, and the door is the only way in : commands,
queries, and `state` reads all pass `authorize_entry` (read paths gated 2026-06-29).
PEP at the door, PDP in the authz context — one gate covers every client app.
The Agent-decouple is what makes this possible : keyed off Agent, every client user
would need to be birthed as an Agent ; post-refactor the principal universe is
AuthIdentity (client user, API key, agent alike). Full client chain, no domain
touched : OIDC/JWT sub == auth_identity_id → authenticate gate (active
AuthIdentity, fails closed) → RoleAssignment → role → Policy permits scoped to the
app's namespace → admitted. Both gates are declaration-gated — a client-serving
root declares them explicitly ; Miette's root stays workable during LATENT.

**Open decisions — settled by the client-app goal :**
1. **KEEP RoleAssignment.** Dropping roles keys permits per-sub — unworkable the
   moment a client app has two users. Roles are what make the gate serve client
   apps. But note : with `role == auth_id == name` the role layer is a NO-OP for
   the initial roster (`evaluate_policy` already matches `p == auth_id`) — so let
   the roster exercise it : at least one role shared by two distinct auth ids.
2. **Dedicated roster bluebook** in the authz context. authorization.bluebook is
   the PDP mechanism (rule shape) ; the roster is deployment standing-state. Boot
   keeps its own policies in its own bluebook — same separation.
3. **Agent survives as pure provenance** (name/description/kind/status), authored
   by whoever births agents, never by the roster. `dispatched_by` keys on name —
   verified unaffected.

**Traps + consumers for the fresh head :**
- **Re-hydrate trap (real).** `dispatch()` re-hydrates the read-model keyed off the
  ENTRY dispatch's `aggregate_type`. The roster's `Assign`s arrive as CASCADES off
  BootCompleted (entry aggregate = BootRun) — repointing the key to RoleAssignment
  still misses them. Hydrate AFTER `complete_over` settles, or the boot assertion
  (`role_for_auth("pr-agent")`) fails and you'll chase it.
- **Role aggregate's fate is unaddressed.** role.bluebook stays behind with an
  unenforced permissions list and a dangling mod.rs re-hydrate key. Decide : retire
  Role, or make RoleAssignment.role_name reference Role.name. Don't dangle it.
- **Consumer sweep (grep run 2026-07-02) :** storehouse.bluebook:195 (AclReadModel
  doc) ; agent.bluebook's i483 design-decision narrative (decision #4 DOCUMENTS the
  auth link — rewrite the story, don't just delete attrs) ; acl_readmodel.rs doc
  comments incl. the `actor_` prefix rationale whose example is LinkAuthIdentity ;
  inbox/i489.md (uses Agent.role_name as its example) ; **dispatch_audit.bluebook
  carries `role_name`** — the one FUNCTIONAL consumer : post-strip, audit must
  source role from the RoleAssignment read-model, not Agent.
- **Reads are gated now** (FINDING #1 closed 2026-06-29). `Tools::*` permits leave
  every bluebook QUERY deny-by-default at cutover — calibrate with `explain` before
  flipping env. Client apps will need query permits for their read surface.
- **Upsert quirk applies to RoleAssignment** (FINDING #2, by-design) : Unassign on
  an absent auth_id inserts-then-retires a ghost. Fail-closed, harmless — known.
- **Naming :** prefer `Retire` over `Unassign` — Policy and Agent both say Retire.

**Next arc the client-app goal exposes (post-LATENT, separate) :** per-REQUEST
principal stamping. Env stamping (`HECKS_SESSION_AUTH_ID`) is per-PROCESS — right
for agent spawn points, wrong for one warm door serving many client users. The
client-app door needs a request-scoped principal (JWT sub → stamp per dispatch).
Same `stamp_principal_*` seam ; different source. Do not solve it in Phase 4.

**Concrete door findings for that arc (verified 2026-07-02, the bin-buddy-shaped
path — `storehouse serve` + generated web UI) :**
- `rust/src/server/` stamps NO principal anywhere (grep `stamp_principal|
  authorize_entry|principal` → zero hits). `routes.rs::dispatch` → `rt.dispatch`
  → `authorize_entry` DOES run, but an unstamped caller classifies as System →
  every web request is admitted by origin. This is exactly the auth bin-buddy
  shipped WITHOUT ; the web door is the stamping site.
- The server's query route (`routes.rs:93` → `resolve_query` direct) never got the
  2026-06-29 read-gating the cold-CLI + warm-MCP doors got. Same fix, third door.
- Roster coupling : establishment policies fire off BootCompleted via the BOOT
  RUNNER ; a shipped client binary boots via `serve`'s `boot_with_hecksagons`, NOT
  run_boot. Either fire the completion/genesis step under serve too, or author the
  client's authz records once into its durable store — re-assert-per-boot is a
  Miette-deploy convenience, not a requirement. Don't assume the roster self-seeds
  under `serve`.
