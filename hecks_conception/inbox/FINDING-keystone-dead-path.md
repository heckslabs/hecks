# FINDING — the boot-establishment keystone is wired to a dead entrance (2026-07-03)

*Surfaced during the Q3 cutover prep : after rebuilding the binary from current
main and firing a real boot, the roster did NOT seed — zero RoleAssignment /
Policy records in the world store.*

## The bug (verified live, twice)

- `complete::complete_boot` — the corpus-loaded completion step that routes
  `BootCompleted` through the policy engine so establishment policies fire — is
  called ONLY from `rust/src/run_boot/mod.rs:153`, the LEGACY native boot runner
  (`storehouse boot`, now a deprecation shim).
- The DEPLOYED boot path is `storehouse run runtime/boot/bluebook/boot.bluebook`
  (Procfile `boot:` line, projected from deploy/mindstream.fixtures) — the
  generic `run` command (cli/main.rs:402). It never calls `complete_boot`.
- On that path, `BootCompleted` emits inside the SINGLE-DOMAIN boot runtime :
  `StartStudioOnComplete` (same bluebook) fires ; the authz roster policies (in
  the corpus, per Phase 4) are never registered there and can never fire.
- boot.hecksagon has no adapter re-dispatching the event into the corpus.

So : `feat(boot): route BootCompleted through the policy engine` (5edfdce7d) is
true on a path nobody boots. Establishment-by-policy has silently never worked
in production. Confirmed by two live boots at 17:06Z + 17:07Z — boot pipeline
green, `dispatch BootRun.CompleteBoot` logged, world store untouched
(authorization/ still holds only Jun-29's probe policy.heki).

## Test gap that hid it

`rust/tests/authz_roster_test.rs` drives `complete_over` directly with inline
domains and `data_dir=None` — it proves the ENGINE (merge, fire, read-model)
and nothing about (a) the deployed boot path reaching `complete_boot`, or
(b) persistence of establishment writes. The keystone's own
`boot_completion_test.rs` has the same shape. A path-level test must boot the
way the Procfile boots and assert records land in a real store dir.

## Fix options (design decision — wants a deliberate head)

A. **Completion as a CLI verb + mindstream member (recommended).** Expose
   `storehouse establish <root>` (thin wrapper : load_combined_domain + merge
   boot + dispatch CompleteBoot — `complete_over` already IS this, pub(crate)
   → pub). Add an `establish` member to deploy/mindstream.fixtures running
   after boot. Grammar-conformant (Procfile is the projection of declared
   members), small kernel surface, testable end-to-end, no generic-`run` magic.
   Caveat : ordering — member must run after the boot member completes.

B. **Hecksagon adapter on BootCompleted** re-entering the corpus through the
   door. Purest hexagon story (cross-domain edge = adapter through storehouse),
   but needs loop-avoidance design : the corpus completion runtime must not
   reload the boot hecksagon's own adapter and re-fire (complete.rs already
   dodges corpus hecksagons for exactly this class of reason).

C. **Teach generic `run` to invoke the completion** when the domain emits
   BootCompleted. Rejected on smell : `run` is generic ; boot-shaped special
   cases in it are the imperative reflex.

D. **Move BootRun into the corpus** so one runtime is both pipeline and corpus.
   Big restructure ; boot deliberately stays a fast single-domain walk
   (complete.rs documents this). Not for this fix.

## Blocked on this

- Roster seeding at real boot → the Q3 pr-agent cutover's live verification
  (`role_for_auth("pr-agent")` on the world store).
- Any future establishment policy (deny-by-default governance, governed-door
  redirects) — the whole establish-as-policy program rides this path.

## Also noted

- complete.rs's `data_dir` comment ("safe today since nothing establishes") is
  stale the moment this is fixed — verify `resolve_world_store_dir` yields the
  real store on the live path, and update the comment.
- Rebuilt-binary lockout invariant re-verified before all this : System exit 0,
  ghost exit 2 (read + command). The gate itself is fine ; only genesis is dead.
