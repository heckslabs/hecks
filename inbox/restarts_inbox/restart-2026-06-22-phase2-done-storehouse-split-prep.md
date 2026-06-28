# Restart — Phase 2 DONE. Next: storehouse-split forward-prep (the transitional fallbacks)

**Date:** 2026-06-22. **Branches:** hecks `main` (pushed, top `ff1c8d8ad`), miette
`cpu-spin/overfire-singleton-keying` (pushed, top `8b242b5`). All COMMITTED + PUSHED.

## Phase 2 is complete (the Miette deployment extraction)
The framework boots being-agnostic; Miette's deployment lives in `~/Projects/miette/deploy`.
- Live cutover verified: body boots from `~/Projects/miette/deploy`, 13 daemons, heart 1Hz,
  wake cascade regenerating. hecks `793c58484` (boot ref), miette `8b242b5` (deploy/ +
  tools/native-tools + system_prompt fixtures + self/settings.json backup).
- Public tree cleaned: hecks `ff1c8d8ad` removed Procfile/.overmind.env/mindstream.fixtures
  + deleted the procfile_emitter golden (subject moved out; NOT a skipped test). specializer
  suite 35 passed; pre-push cargo+integrity+behaviors all green.
- settings.json: SessionStart boots from deploy; the per-turn `overmind quit` body-killer Stop
  hook + the per-turn `gem build` Stop hook REMOVED; TTS voice hook kept. `~/Projects/miette/
  tools/native-tools` toggles the native-tool deny-list (block default; `allow` for door-brick).

## What's LEFT — the storehouse-split forward-prep (deferred BY DESIGN, per the plan)
The public framework still has TWO transitional `../miette` fallbacks. Both already have an
ENV OVERRIDE as first precedence — they are intentional scaffolding (the plan's forward-compat
section: "layout-coupling fixes land with the storehouse split"), NOT undealt leaks. Removing
them is the storehouse-split arc, done as ONE gated unit:

1. **corpus_loader/mod.rs:53** — `repo.join("../miette")` sibling-walk fallback. Override:
   `HECKS_ADDITIONAL_CORPUS_ROOTS` (Phase 1). Covers the DOOR's reach to Miette today.
2. **run_boot/daemons.rs:206,216** — `repo.join("../miette/body")` body-discovery fallback.
   Override: `HECKS_BODY_DIR` (first precedence in resolve_body_dir). Currently works because
   `~/Projects/hecks` and `~/Projects/miette` are siblings.

### Gated sequence (door-brick risk on rebuild — R1)
- **Wire the env FIRST** (load-bearing prerequisite, no rebuild):
  - deploy `.overmind.env`: add `HECKS_CONCEPTION_DIR`, `HECKS_ADDITIONAL_CORPUS_ROOTS=
    /Users/christopheryoung/Projects/miette`, `HECKS_BODY_DIR=/Users/christopheryoung/Projects/
    miette/body`. TENSION: `.overmind.env` is a GENERATED artifact (from mindstream.fixtures);
    hand-adding violates do-not-hand-edit. Proper fix: teach `specializer/procfile.rs` to emit
    a deployment-env block (CARD). Interim: marked instance-config section + this card.
  - The **MCP server config** (`~/.claude.json` mcpServers / wherever the storehouse MCP server
    is launched): set `HECKS_ADDITIONAL_CORPUS_ROOTS` so the DOOR reaches Miette WITHOUT the
    fallback. THIS is the gate — verify the door resolves a Miette command with env + no
    fallback before deleting corpus_loader:53.
- **Then remove both fallbacks** (kernel edit → `cargo build --release` → R1: verify on a
  scratch dispatch BEFORE relying on it; the door IS the binary). A run_boot change only
  affects boot (not the dispatch path), so door-brick risk is lower, but a COMPILE error leaves
  no new binary. Verify: scratch dispatch (door alive) + boot from deploy (body found via env).

## Smaller residuals (cosmetic / low-priority)
- **procfile.rs:178-191** emitted-header hardcodes `aggregates/framework/mindstream/mindstream
  .fixtures` — now mis-points (fixtures live in deploy). Genericize the emitted header; needs a
  rebuild + regen of Miette's deploy Procfile. (Ride it with the rebuild above.)
- **Stale de-being comments** referencing the MOVED `aggregates/miette/body/wake/wake.bluebook`:
  `run.rs:191`, `run_wake/mod.rs:7` (+ its [antibody-exempt] reason). Both hand-written (not
  golden targets). De-being the comment ("the being's wake bluebook (WakeReview)"), no behavior
  change. Watch the antibody on touching .rs.

## Decisions still open (flagged, untouched)
- **Muted voice:** `~/Projects/miette/body/voice/voice.hecksagon` `voiced_by("ElevenLabs")`
  commented out (UNCOMMITTED in miette — a deliberate toggle). DEEPER GAP worth a card: the
  domain `Voice.Mute` command does NOT gate the kernel audio path — cutting the wiring was the
  only reliable mute. Make the audio path honor `mode: muted`.
- **miette branch hygiene:** the deploy commit landed on `cpu-spin/overfire-singleton-keying`,
  not `main` (the tree had pre-existing uncommitted dream/consciousness/voice changes, so I did
  NOT switch branches). Needs a merge to main — Chris's call on topology.

## First moves next session
1. Boot; confirm body healthy + door alive; read wake review.
2. If opening the storehouse-split arc: wire env (deploy .overmind.env + MCP config) → verify
   door-via-env → remove both fallbacks → gated rebuild → verify. File the generator-emits-
   deploy-env card.
3. Else: resolve the muted-voice audio-gate card + miette branch merge.
