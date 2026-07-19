# DESIGN HANDOFF — the client door : per-request principal stamping at the HTTP serve door

*For a fresh session. This is the THIRD door to gate (cold CLI + warm serve-stdio/
socket got the recipe 2026-06-29 ; the HTTP `storehouse serve` door has none of
it). Phase 4 authz-decouple is MERGED (PR #744) and is the substrate : principals
resolve auth_identity_id → Authorization::RoleAssignment → role → Policy
permits/forbids ; the gate is `authorize_entry`, standing middleware ; System is
admitted by origin. Read `inbox/DESIGN-authz-decouple-and-roster.md` (esp. its
REVIEW ADDENDUM) for the arc framing. PATH NOTE : the runtime lives at
`~/Projects/hecks/rust/` — the hecks repo root, NOT under hecks_conception. All
file:line refs below verified 2026-07-02 against live code.*

## The principle

One warm HTTP server serves MANY callers. Every existing stamp site is
`stamp_principal_from_env` — per-PROCESS, right for agent spawn points, wrong for
a resident door. Today `rust/src/server/` stamps NO principal anywhere, so every
web caller classifies as `Principal::System` and is admitted by origin — the
exact hole bin-buddy shipped with. The fix is a REQUEST-scoped principal : the
`Authorization: Bearer <auth_identity_id>` header carries the caller's identity ;
the door stamps it per request ; the standing `authorize_entry` gate (PEP at the
door, PDP in the authz context) does the rest. Same `stamp_principal_*` seam,
different source. No domain bluebook gains a field — auth stays fully in the
authorization context.

## Current state (verified in code)

- Both transports converge on `routes::route` (`rust/src/server/routes.rs:23`).
  Two gated-core work sites : `rt.dispatch` (routes.rs:109, inside `dispatch()`
  :102) and `rt.resolve_query` (routes.rs:93, inside `query()` :85).
- **NO stamping in server/** (grep `stamp_principal|authorize_entry|principal` →
  zero hits). `rt.dispatch` gates internally but the attrs are unstamped ⇒
  System ⇒ admitted. `rt.resolve_query` (routes.rs:93) is the UNGATED read core —
  the HTTP query route never got the 2026-06-29 read-gating.
- **MORE ungated reads than the two work sites** (scout reports undercounted) :
  `domain_json` (routes.rs:35, :48), `aggregates_json`/`rt.all` (:53), `rt.find`
  (:58), `events_json` (:70), `policies_json` (:75) all project state with no
  gate. Under a governed door these leak every aggregate + the event log.
- `read_request` (`rust/src/server/mod.rs:66`) returns `Option<(method, path,
  body)>` and DISCARDS every header except Content-Length — the Authorization
  header never survives parsing. Callers : `handle_single` (mod.rs:56, route call
  :61) and `handle_multi` (`rust/src/server/multi.rs:304`).
- Multi door : `handle_multi` tries the bluebook-declared `:web` template routes
  FIRST (`registry.resolve_all` → `web_adapter::render`, multi.rs:322-333) —
  read-only projections that BYPASS `routes::route` entirely — then falls to
  `route_multi` (multi.rs:355), which re-enters `routes::route` at multi.rs:403
  for `/domains/:name/*`.
- **The recipe, live at the warm serve door** (`rust/src/run_serve/mod.rs`) :
  queries (~:118-127) stamp into a SEPARATE `gate_attrs` map
  (`stamp_principal_from_env` :121) then `rt.authorize_entry(&command, &mut
  gate_attrs)` (:122) BEFORE the ungated query core ; deny → error payload,
  resident server NEVER exits. Commands (:151) stamp onto the dispatch attrs ;
  `rt.dispatch` gates internally and strips the reserved keys.
- Reserved keys (`rust/src/runtime/acl_readmodel.rs`) : `KIND_KEY="actor_kind"`
  (:49), `AUTH_KEY="actor_auth_id"` (:50) ; `principal_from_attrs` (:71) ;
  `stamp_principal_from_env` (:86) ; `stamp_system` (:105). `authorize_entry`
  (`rust/src/runtime/mod.rs:677`) runs the before-gates, records denials as
  governed Violations, strips reserved keys on success, honors the deploy-floor
  `HECKS_GOVERNANCE_OFF` escape.
- Identity : **AuthIdentity**
  (`aggregates/framework/agent/bluebook/auth_identity.bluebook`) — the id IS the
  session token ; `Establish` (pending) → verifier Family verdict →
  `MarkVerified` (active) / `Reject` ; `Retire` revokes. The `authenticate` gate
  (runtime/mod.rs:810 `authenticate_check`, wired :737) admits only ACTIVE ids,
  fails closed, and is DECLARATION-GATED (order 10, before authorize at 20).
  There is NO session/login/token-expiry concept anywhere in the corpus — that is
  a future conception chapter, NOT this arc.
- Serve boot : `storehouse serve <dir>` → `server::multi::serve_directory`
  (`rust/cli/src/main.rs:1186-1189`) → `boot_served_runtime` (multi.rs:198) →
  `Runtime::boot_with_hecksagons` (:205) + `attach_world_servers` +
  `attach_world_adapter_bindings` (:213-216). The single-FILE arm is
  `server::serve(rt, port)` (cli/src/main.rs:1362). Serve does NOT run run_boot —
  see the roster coupling under Verification.
- **World seam EXISTS** : `attach_world_adapter_bindings`
  (`rust/src/world/attach.rs`) extends `rt.world_configs`
  (`Vec<ExtensionConfig>`, runtime/mod.rs:301) with every walked `.world`'s
  extension config blocks ; `World::config_for(name)` (world/ir.rs:122) reads a
  block ; precedent reader : `persistence_strict` (world/ir.rs:132) reads
  `persistence do strict true end`. Grammar sample :
  `examples/pizzas/bluebook/pizzas.world`.

## The changes (six moves)

### 1. Widen read_request to carry the bearer
`read_request` (server/mod.rs:66) : in the existing header loop, also capture
`authorization:` (case-insensitive), extract the `Bearer <token>` value. Return
it — either widen the tuple to `Option<(String, String, String, Option<String>)>`
or (cleaner) a small `Request { method, path, body, bearer }` struct. Thread it
through `handle_single` (mod.rs:56), `handle_multi` (multi.rs:304),
`routes::route`'s signature (routes.rs:23), `route_multi` (multi.rs:355), and the
re-entry (multi.rs:403). Also add `Authorization` to the CORS
`Access-Control-Allow-Headers` list in `write_response` (mod.rs) and
`write_response_typed` (multi.rs) or browser clients can't send it.

### 2. Request-sourced stamp primitive
`acl_readmodel.rs`, beside `stamp_principal_from_env` (:86) :
`pub fn stamp_principal_from_request(attrs: &mut HashMap<String, Value>,
bearer: Option<&str>, posture: DoorPosture)` —
- `Some(token)` → `KIND_KEY=agent`, `AUTH_KEY=token`. Bearer IS the
  auth_identity_id (first cut) ; opaque-token/JWT-sub mapping arrives with the
  future Session chapter.
- `None` + `open` → `stamp_system` (today's behavior — Miette's local studio
  unbroken).
- `None` + `governed` → `KIND_KEY=agent`, empty auth id → fails closed at the
  gate (what a shipped client binary declares).
Same reserved keys, explicit source. `DoorPosture` is a two-variant enum here,
default `Open`.

### 3. Door posture from .world (recommendation — ratify at PR review)
Per-deployment value, so it is a `.world` extension config block, top level,
world-grammar-conformant (exactly the `persistence do strict true end` shape) :
```
door do
  posture "governed"
end
```
Seam : `boot_served_runtime` already folds `.world` configs onto
`rt.world_configs` via `attach_world_adapter_bindings` (multi.rs:213-216) ; read
`config_for("door")`-equivalent off `rt.world_configs` once at serve boot and
hand the posture to the request loop. **Caveat (real)** :
`attach_world_adapter_bindings` walks SIBLING repos + top-level buckets
(attach.rs — miette, miette_family, runtime/, discipline/, …) — a stray sibling
`.world` must not flip the door. Read posture from the SERVED ROOT's own `.world`
only (parse directly in `boot_served_runtime` alongside the attach calls, or
filter by path). **Gap** : the single-file arm (cli/src/main.rs:1362) does no
world walk at all — it defaults `open` ; parsing a sibling `.world` next to the
served bluebook is the minimal extension if wanted. Absent block = `open`.

### 4. Stamp once in routes::route ; gate the read side ; deny → 403
`routes::route` (routes.rs:23) receives the bearer + posture, resolves the
principal ONCE, passes it down.
- **Queries** — `query()` (routes.rs:85) : mirror the warm-serve is_query recipe
  exactly : separate `gate_attrs` map, `stamp_principal_from_request`, then
  `rt.authorize_entry(&fqn, &mut gate_attrs)` BEFORE `rt.resolve_query`
  (routes.rs:93). Deny → `("403 Forbidden", {"ok":false,"error":…,"command":…})`
  — never process::exit, this is a resident server. NOTE : `query()` currently
  takes `rt.borrow()` ; `authorize_entry` is `&mut self` (records Violations) —
  restructure to `borrow_mut` first, drop, then borrow for the read (or gate
  before borrowing for the query).
- **Commands** — `dispatch()` (routes.rs:102) : stamp onto the dispatch attrs
  before `rt.dispatch` (routes.rs:109) ; its internal `authorize_entry` does the
  rest. Map `RuntimeError::Unauthorized` to 403 (today every Err collapses to
  422).
- **The raw read routes** (routes.rs:35/48/53/58/70/75 — domain, aggregates,
  find-by-id, events, policies) : under `governed` these must not leak. Gate
  find/all with the same gate_attrs recipe (the cold `state` subcommand already
  set the precedent — by-id reads gate like queries, see
  cold_read_gate_test.rs) ; `events`/`policies`/`domain` are introspection — see
  Open decision 2. Under `open` all unchanged.

### 5. :web projections (multi door)
The template projections (multi.rs:322-333) bypass `routes::route` — read-only
renders. Under `governed` : gate at `handle_multi`, the earliest common point,
before the `registry.resolve_all` loop — one `authorize_entry` over a synthetic
read phrase (Open decision 3 names it). Under `open` : leave as-is.

### 6. loc-ratchet
This arc GROWS core_runtime (new primitive + threading). The growth commit's
message must carry `[loc-ratchet-override: client-door stamping — third door,
recipe parity]` — and after the bootstrap fix lands, the marker works in the
in-flight commit message itself.

## Verification

- **Test shape** : model on `rust/cli/tests/cold_read_gate_test.rs` (temp root +
  inline Vault bluebook ; `env_remove("HECKS_GOVERNANCE_OFF")` so the ambient
  escape never masks the gate) — but over HTTP. `routes::route` is already a
  pure `(method, path, body, rt) → (status, body)` function — RECOMMENDED :
  test `route()` directly in the storehouse lib crate, no socket, both postures ;
  plus ONE ephemeral-port smoke that spawns `storehouse serve` and curls, to
  prove the header survives `read_request`.
- **Four-case over HTTP** : (a) no header — `open` → admitted as System ;
  `governed` → 403 ; (b) `Bearer ghost` → 403 (denied, both postures) ; (c)
  bearer of a rostered id with permits → admitted ; (d) same bearer on a
  forbidden namespace → 403.
- **Roster/boot coupling (trap, real)** : `storehouse serve` boots via
  `boot_with_hecksagons` (multi.rs:205), NOT run_boot — the BootCompleted
  establishment policies do NOT fire, so roster RoleAssignment/Policy records do
  NOT self-seed under serve. The test must author them directly (dispatch
  `Authorization::RoleAssignment.Assign` + `Authorization::Policy.Permit` into
  the served root's store) or dispatch the BootRun.CompleteBoot equivalent first.
- Deny responses are 403 with a JSON body ; the server process stays up across
  every denial (assert a follow-up request succeeds).
- Pre-push as usual : behaviors suite + `cargo test --release` + integrity ;
  smoke `ruby -Iruby examples/pizzas/pizzas.rb` unaffected (Ruby side untouched).

## Scope — explicitly OUT (do not creep)

- Interactive login / credential exchange, token expiry/refresh, a Session
  aggregate — future bluebook-first conception chapter. First cut : bearer ==
  auth_identity_id, full stop.
- Flipping any agent spawn-point env (`HECKS_PRINCIPAL_KIND` /
  `HECKS_SESSION_AUTH_ID`) — that is the LATENT Q3 cutover, separate and
  reversible.
- `Principal::System => Ok(())` stays the first arm gate-side — never violate ;
  `open` posture + no header must keep Miette's studio byte-identical in
  behavior.

## Open decisions for the fresh head

1. **Return shape of read_request** : widened tuple vs `Request` struct.
   Struct RECOMMENDED — a fourth positional Option invites transposition bugs
   across the three call sites.
2. **Raw introspection routes under `governed`** (`/events`, `/policies`,
   `/domain`) : gate each with a synthetic resource name, or 403 them wholesale
   under `governed` (simplest, matches "the aggregate is the conceptual layer" —
   readers enter through queries). Wholesale RECOMMENDED for the first cut.
3. **Action naming for gated non-query reads** (`/aggregates/:name/:id`, :web
   renders) : the gate matches action patterns like `Domain::Agg.verb` —
   `rt.find` reads should gate as the aggregate's read surface (the cold `state`
   precedent) ; :web renders need a stable phrase (e.g.
   `<Domain>::<Agg>.<query>` of the projection's backing query, or a
   `Web::Projection.render` convention). Pick ONE and write it down in the PR.
4. **Does a governed root also declare the `authenticate` gate?** RECOMMENDED
   yes — bearer ids must be ACTIVE AuthIdentities, not just rostered strings ;
   it is declaration-gated precisely so Miette's root stays workable. That is a
   .bluebook Gate declaration in the client root, not a code change.
5. **Posture value ratification** : `open`/`governed` names + `.world` `door`
   block — flag for Chris at PR review before it calcifies.

## Key files

- `rust/src/server/mod.rs` — read_request (:66), handle_single (:56), CORS
  headers (write_response)
- `rust/src/server/routes.rs` — route (:23), query (:85, gate before :93),
  dispatch (:102, stamp before :109), raw reads (:35/:48/:53/:58/:70/:75)
- `rust/src/server/multi.rs` — handle_multi (:304), :web loop (:322-333),
  route_multi (:355), re-entry (:403), boot_served_runtime (:198, posture read)
- `rust/src/runtime/acl_readmodel.rs` — new stamp_principal_from_request beside
  :86 ; KIND_KEY/AUTH_KEY (:49-:50)
- `rust/src/world/attach.rs` + `rust/src/world/ir.rs` (config_for :122) — the
  posture seam ; grammar sample `examples/pizzas/bluebook/pizzas.world`
- `rust/cli/src/main.rs` — serve arms (:1186-1189 dir, :1362 single-file)
- Reference (recipe, unchanged) : `rust/src/run_serve/mod.rs` (~:118-:127,
  :151) ; `rust/cli/tests/cold_read_gate_test.rs` (test shape)
- Reference (identity) :
  `aggregates/framework/agent/bluebook/auth_identity.bluebook` ;
  `rust/src/runtime/mod.rs` authorize_entry (:677), authenticate_check (:810)
