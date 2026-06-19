# RESTART 2026-06-19 — the HECKS_INFO scrub, then the clean pickups

VOICE : I speak as myself — I / my / mine. This is a handoff from a very long
session to my next self. Read it, then start with the SCRUB (§1). The hard
architecture is already done and committed ; what remains is finishing the
sweep and a few clean fresh-head builds.

## The through-line (what just happened)

HECKS_INFO is GONE. It was an env-var master-switch that redirected where heki
state lands — the single source of reader/writer store splits. The world
(`dir :default` / realm) is now the ONE store authority. The KEY insight (Chris's):
**the store is keyed by the conception DIRECTORY**, so isolation is automatic — a
test runs from a /tmp conception and `dir :default` co-locates its store at
`<dir>/.heki`, never touching the live ~/.heki. No env, no redirect, no literal paths.

Spec for this work already existed : `hecks_conception/docs/designs/realm-heki-world-wiring.md`.

## DONE + COMMITTED this session (do NOT redo) — branch feat/heki-rollout-pizzas-form

- `aa768aeb1` compiled standalone Rust tts adapter (adapters/tts/tts-handler) — live, proven.
- `3d9cf81d3` antibody : adapter handlers categorically exempt (bin/antibody-check declared_handler?).
- `6f29fda5f` TTS kernel dispatcher pulled OUT of the runtime (tts_dispatcher.rs deleted ; runtime knows no TTS).
- `829e67b83` **remove HECKS_INFO** — 3 resolvers de-branched (heki::resolve_info_dir,
  main::find_world_heki_dir, run_status::resolve_fs_root) ; daemon propagation gone
  (run_boot/daemons.rs) ; `run::infer_data_dir` → None (MEMORY) when no world ;
  `heki::resolve_default_dir` keyed-by-directory (under ~/Projects → ~/.heki/<chain> ;
  elsewhere → co-located <dir>/.heki) ; pulse_organs_smoke + body_cycles_smoke migrated
  to `dir :default` + passing. Zero-warning build, rust tests green, pre-commit smokes green.
- process_health : the missing `hecks_conception/bin/process_health_sweep` leaf written +
  committed (daemon spawn-error spam fixed).
- (miette repo `d2a5f5b`) live voice deployment switched to the compiled binary ; dead .rb removed.
- `6b8bff027` **SendMessage delivered** — inter-agent messaging via the storehouse
  blackboard (i708) : framework/agent_inbox/agent_inbox.bluebook (AgentMessage : Send /
  MarkRead / Reply / Unread / Answered + a `mid` identity-echo) + adapters/agent/
  {messaging.family, agent.adapter, send-message(.rs) compiled bin}. The bin sends to an
  agent, BLOCK-polls `state` for the reply, prints it. Proven : send -> agent reads mid ->
  Reply -> bin returns the reply on stdout.

## §1 — THE SCRUB (START HERE)

HECKS_INFO is functionally dead (the runtime reads it NOWHERE), but ~30 references
remain. `grep -rn HECKS_INFO . | grep -v target | grep -v .git | grep -v inbox/`.
Two categories — do the FUNCTIONAL ones first, they are not cosmetic :

### 1a. FUNCTIONAL risk — leaf scripts that expected the RUNTIME to set HECKS_INFO
The runtime no longer sets/propagates it, so these fall back to a possibly-wrong dir.
VERIFY each still finds its store (or migrate to the world) :
- `hecks_conception/bin/fibroblast_sweep.sh:38` — `INFO=\"${HECKS_INFO:-$ROOT/information}\"`
- `hecks_conception/shutdown_miette.sh:21` — same fallback pattern
- `hecks_conception/aggregates/discipline/immune_system/repair_cell/fibroblast/fibroblast.hecksagon:31`
  + `aggregates/framework/mindstream/mindstream.fixtures:75` — comments claiming \"$HECKS_INFO always set by the runtime\" (now FALSE).

### 1b. Dead exports in smokes (tests PASS already ; export is inert) — migrate to `dir :default`
Use the EXACT pattern from pulse_organs_smoke.sh / body_cycles_smoke.sh (committed) :
write a `*.world` with `dir :default` in the tmpdir conception, drop the HECKS_INFO
export, read from the co-located `<aggregates>/.heki/<agg>/<agg>.heki`. Run each after :
- `hecks_conception/tests/dream_content_smoke.sh` (210, 260, 262, 267)
- `hecks_conception/tests/interpret_dream_smoke.sh` (69)
- `hecks_conception/tests/statusline_regression_smoke.sh` (76-83)
- `hecks_conception/tests/status_golden.sh` (58, 77)
- `hecks_conception/tests/pulse_fanout_smoke.sh` (97)
- `hecks_conception/tests/consolidate_smoke.sh` (73)

### 1c. Ruby research harnesses (dream-study, outside the smoke loop)
- `core/research/dream-study/test-gate/invariants/lib/dispatch_helper.rb` (13, 47, 122 — mints HECKS_INFO tmpdir)
- `core/research/dream-study/test-gate/invariants/spec_helper.rb:5`, `regression/spec_helper.rb:68`
- `core/transitional/dream/dream_extract_gaps.rb` (29, 44 — default to miette-state ; should resolve via world)

### 1d. Cosmetic doc-comments + docs (truly harmless) — just delete the mention
- `rust/src/story_runtime/mod.rs:93`, `run_boot/classify.rs:57,72`, `main.rs:3203,5805`, `storehouse_router.rs:12`
- `runtime/boot/boot.hecksagon:52` (comment), `hecks_conception/information/README.md:53,56,60`
- `hecks_conception/docs/designs/realm-heki-world-wiring.md` — mark the design IMPLEMENTED (829e67b83).
- LEAVE inbox/archive + inbox/i657/i438/i518 (historical record).

## §2 — process_health persistence (separate blocker, NOT HECKS_INFO)
I changed `aggregates/framework/process_health/process_health.hecksagon` :memory → :heki
(UNCOMMITTED). It is INERT : a MarkAlive dispatch returns ok:true but persists to NO
heki file — the per-aggregate persistence-APPLY (i728 apply_memory_persistence) is not
live for this aggregate. So the sweep→heki→heal flow still doesn't function. Decide :
revert the :heki change (it's inert) or chase why ProcessSentinel won't persist while
nerve/pulse do. The sweep LEAF works ; the persistence does not.

### §2-UPDATE (2026-06-19, later same session) — FIBROBLAST IS NOT i728-BLOCKED
While scrubbing 1a I found fibroblast was the SAME shape (`adapter :memory`, an
out-of-process sweep script reading a heki FILE memory never writes). I flipped it
`:memory → :heki` and it PERSISTS cleanly — ReceiveSignal writes
`~/.heki/hecks/fibroblast/fibroblast.heki`, open_healings reads it back. So `:memory`
was the regression, NOT an apply gap. This means **process_health (§2) should be
RE-TESTED the same way** — the i728 "apply not live" claim may be stale (i728 fixed
since the note?) or process_health has a DIFFERENT bug than a missing apply (e.g. its
.mjs reads a differently-named/located heki, or its commands route by an identity the
dispatch doesn't carry — see the routing finding below).

**The storm + the real fix (DONE this session, fibroblast):** after the flip, running
the sweep end-to-end caused a SPAWN STORM. Root cause was NOT kernel — it was three
things, all fixed at bluebook+shell altitude :
  1. `open_healings` has NO where-clause — it returns EVERY record, not just open ones
     (the name is aspirational). The sweep now filters `closed_at` empty in jq. (Rename
     the query or give it a real where-clause someday — filed-worthy, not urgent.)
  2. `storehouse query` renders ONE record as a bare object, many as an array, none as
     `[]` (deliberate — see behaviors_runner.rs:551 query_records). The sweep now
     normalizes `.state` object→array in jq the same way.
  3. **Routing : the lifecycle commands (SelectStrategy/Heal/Decline/RecordOutcome) do
     NOT declare `signal_id`** ; the aggregate is `identified_by :signal_id`. The sweep
     was dispatching them with `signal_id={value: …}`, which is NOT a routing key, so
     each minted a fresh EMPTY-identity record → open_healings returned ever-more rows
     → the loop amplified. FIX : dispatch by the universal `id=$SIG_ID` (scalar) —
     verified in a tmpdir ladder that `id=` updates the right record in place, no dupes.
  Verified end-to-end in a /tmp conception (NOT live, NO Sweep cascade) : RUN 1 declines
  the open healing, RUN 2 finds nothing (closed_at filter), count stays 1. Idempotent.

**fibroblast deliverables (working tree, uncommitted, NOT yet committed) :**
  - `aggregates/.../fibroblast/fibroblast.hecksagon` : `:memory → :heki` + scrubbed the
    stale `$HECKS_INFO always set by the runtime` comment.
  - `bin/fibroblast_sweep.sh` : reads via `Fibroblast::Fibroblast.open_healings` query
    (jq normalizes state + filters closed_at + drops sweep row), dispatches by `id=`,
    HECKS_INFO/$INFO/FIBRO_HEKI all gone. `bash -n` clean.

**NEVER dispatch `Fibroblast::Fibroblast.Sweep` against the LIVE conception** — it
cascades Sweep→Process.Spawn→script. Test the full cascade in a tmpdir ONLY. The live
store currently holds ONE inert closed/declined junk record (empty signal_id) left from
the storm before the fix — harmless (closed, filtered by the sweep), unreachable by
domain command (empty id), will be drowned out by real healings once committed.

## §3 — SendMessage (DELIVERED + committed 6b8bff027) — only follow-ups remain
The inbox domain + messaging.family + agent.adapter + the compiled send-message bin are
DONE and proven (send -> agent reads mid -> Reply -> bin returns the reply). What's left :
- WIRE the Tools surface : framework/tools/hecksagons/agent_tool.hecksagon's AgentToolAdapter
  still dispatches the CANNED 'agent resumed' ; point Tools::AgentTool.SendMessage at the
  real agent.adapter (messaging family) so it's callable as a tool, not just standalone.
- AGENT-SIDE polling : a spawned agent must loop on Unread(its_id) -> MarkRead -> Reply.
  I proved it by hand-replying ; real agents need the poll loop (sidequest-style).
- BUGS found : Answered(id)'s where-on-IDENTITY doesn't match (the bin uses `state <id>`
  instead) ; Unread returns a SINGLE record, not an array of all unread for the agent.

## §4 — the fs-adapter IO proof (filed, not built)
The run_script_test simplification removed the only spot proving :fs does real IO.
Per Chris : that proof belongs on the persistence FAMILY as a pure-bluebook .behaviors
contract test (dispatch save → dispatch find → assert round-trip through a real adapter,
isolated by its own :default world in a tmpdir). The ONE place a test legitimately
touches disk. Everything else is pure in-memory bluebook.

## Gotchas
- The keyed-by-dir rule lives in `heki::resolve_default_dir` : `default_chain` only
  handles ~/Projects paths (strip_prefix ~/Projects) ; everything else → co-located <dir>/.heki.
- A bare bluebook with no world now runs in MEMORY (run::infer_data_dir → None). Tests
  that just need to RUN want no world ; tests that PERSIST need a `dir :default` world.
- Pre-commit runs every hecks_conception/tests/*.sh ; run the ones you touch before committing.
- Stage specifically. Still uncommitted in the tree (NOT part of any clean commit) : the
  pre-existing parity/ruby files + process_health.hecksagon's inert :memory->:heki change (§2).
  SendMessage and the HECKS_INFO rip are committed.
