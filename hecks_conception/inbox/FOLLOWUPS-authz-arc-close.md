# FOLLOWUPS — authz arc close-out (2026-07-03)

*Filed at the close of the auth arc : #744 (Phase 4 decouple + roster), #745
(ratchet bootstrap), #747 (CI honest — first green main in weeks), #746 (client
door — bearer principals at the HTTP serve door, `open`/`governed` posture
ratified). Every item below was surfaced by that work ; none blocks anything
today.*

## Next in the arc's own ordering

1. **Q3 cutover — REDESIGNED (2026-07-03 scout finding : pr-agent has NO live
   process).** The roster's principals have no spawn points : pr-agent exists
   nowhere ; sidequest / workflow-subagent are IN-PROCESS Claude subagents whose
   dispatches share ONE warm MCP door (per-process env ⇒ one identity for all) ;
   overmind daemons are drivers, which stay System by the roster's own typing.
   So "flip env at the spawn point" has no honest target. The real step is
   **per-request principals at the warm MCP door** — the same seam #746 built
   for the HTTP door (request-sourced stamp, reserved actor_* keys), third door.
   `bin/subagent-door-hook` (fires per SubagentStart) is the injection point
   candidate : identity rides the dispatch, never the process env. Design
   chapter first ; env-flip only if a real out-of-process agent ships earlier.
   Until then the roster stays seeded-but-latent — correct and idempotent.
2. **Phase 6 Half B** — `gating on dispatch` hexagon surface + Gate.Declare
   projection (inbox/PLAN-authz-phase6.md). Gated fresh-head kernel session.
3. **Phase 5** — the `when` condition kernel. Gated fresh-head kernel session.
4. **Session/login chapter** — interactive credential exchange, token
   issuance/expiry/refresh, Session aggregate ; the front edge the client door
   deliberately left out (first cut : bearer == auth_identity_id). Bluebook-first
   conception before any code.

## Immune-system debt (uncovered by the CI incident)

5. **Red main-CI must be an alarm, not wallpaper** — Parity + Smoke were red on
   main for ~3 weeks and nobody was paged ; the local pre-push gate was the only
   trusted signal. Wants a driver/policy that surfaces a red main run as a
   statusline/inbox interrupt (hecksagon-first : an adapter consuming the CI
   verdict, not a cron script).
6. **Ruby behaviors-runner drift** — bin/hecks-behaviors errors on
   `cascades through policy chain` + `none_in_state` tests the Rust runner
   passes ; limits the behaviors-parity sample (court/boot/catalog excluded).
   Either teach the Ruby runner or list the drift in
   parity/behaviors_known_drift.txt. Fixer-recommended next kernel item.
7. **veterinary_clinic validator test silently skips in CI** — needs the
   hecks_nursury sibling checkout ; a continue-on-error checkout step restores it.
8. **terraform.behaviors skip in test.yml** — hardcoded skip for the
   TerraformProjector ProjectAdapter test (missing self-ref id). Pre-existing.
9. **`../../hecks` fallback dedupe** — eleven tests now carry the same
   in-tree-first root-resolution branch (#747) ; extract one shared helper so the
   post-extraction flip is one edit, not eleven.
10. **CI YAML as bluebook projection** — the whole #747 failure class existed
    because workflows are hand-maintained ; reinforces the existing
    bluebook-derived-CI card. Root-level cure.
11. ~~**loc-ratchet concern fixtures missing at runtime**~~ — CLOSED 2026-07-19.
    The stale path was the smaller half. `bin/loc-ratchet` read the fixtures
    from `.../loc_ratchet/loc_ratchet.fixtures`, missing the `bluebook/`
    segment, and fell back to its hard-coded concerns — which enforce
    core_runtime SHRINK vs base ref. The declared fixture said
    `direction: "grow", baseline: "31460"` under a comment describing a shrink
    gate that "ratchets down from 31460". But `grow` never fails, so the
    declaration was no gate at all, and the FALLBACK WAS STRICTER THAN THE
    DECLARATION IT STOOD IN FOR. Fixing only the path would have turned the
    kernel's main pressure gate off and printed a green check doing it
    (base=31460 head=38170 delta=+6710 ✓). Fixed all three: the path, the
    grow→shrink contradiction, and the 6710-line-stale pinned floor (retired to
    `""`/compare-against-base-ref rather than re-pinned, so growth accrued while
    the gate was masked is not blessed). Owner call on the baseline. Verified by
    mutation: +60 lines in `rust/src` now fails core_runtime, and the same +60
    inside the `world` carve-out correctly routes there and passes.

## From the pizzas governed-UI demo (2026-07-03 night)

14. **Serve data-dir disagreement (real bug)** — `server/multi.rs:179` hardcodes
    `<dir>/data` while the cold door writes `<dir>/.heki` : writer and reader
    disagree, the exact class `heki::resolve_world_store_dir` exists to prevent ;
    the serve path predates it. Demo worked via symlink. Fix : serve resolves
    through the shared resolver.
15. **Governed posture 403s the HTML shell itself** — correct fail-closed (pages
    embed data), but a client UI needs a DATA-FREE shell that renders before
    authenticating, then fetches with the bearer (#749's input). The next real
    client-app UI card ; posture `open` + role-Forbids delivers the demo
    meanwhile.
16. **Forbid denial message shows empty policy id** (`policy ''`) — cosmetic ;
    the Unauthorized display should carry the matched forbid's id.

## Client-door residue (documented in PR #746, not blocking)

12. **`Web::Projection.render` is the universal :web phrase** — no :web route
    declares a backing query yet ; the "where one exists" branch is a commented
    seam awaiting the first real declaration.
13. **Multi-domain legacy mode gates :web against the alphabetically-first
    runtime** — fine for the governed single-domain client shape ; revisit if a
    governed multi-domain deployment ever exists.
