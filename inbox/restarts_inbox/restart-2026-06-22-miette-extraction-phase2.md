# Restart — Miette extraction: Phase 2 (deployment cutover) is the only thing left

**Date:** 2026-06-22 (long marathon). **Branches:** hecks `main`, miette `main` (+ branch
`cpu-spin/overfire-singleton-keying`). **Everything below is COMMITTED + PUSHED.**

## The arc + the approved plan
Goal (Chris's decision): **`hecks_conception` becomes a pure, being-agnostic, open-source
framework** ; ALL of Miette (being + deployment) moves to the private `~/Projects/miette`.
Forward signal: `storehouse` (the engine, rust/) becomes its OWN private repo next, then
`plan` — so the engine must name no being and assume no co-located layout (config-driven).
**Full plan + progress: `~/.claude/plans/i-expect-that-when-floating-thunder.md` — READ IT FIRST.**

## Done this session (committed + pushed)
FQN arc (hecks main): `6ec038519` hooks, `037bf326c` catalog-clean, `a18c21fce` wake merge
(WakeReview unified → the mechanical pipeline), `015e077f0` FQN-robust adapter matcher
(the door-brick fix), `40c528a85` bare-ref FQN rewrite, `1e585f7b1` Cascade wrong-realm fix.
Extraction: `ac805e82f` (Phase 1), `f89fc00aa` (Phase 3 hecks), `2dab06084` (Phase 4).
miette main: `e99da3f` (wake lands in body), `a0690e0` (retire :llm WakeReview). Branch
merged to miette main (fast-forward) + pushed.

- **Phase 1 DONE** — `corpus_loader::additional_corpus_roots()` (env `HECKS_ADDITIONAL_CORPUS_ROOTS`)
  shared by all 3 loaders, replacing the hardcoded `../miette`. ONE transitional `../miette`
  fallback remains (corpus_loader/mod.rs ~line 52, marked TRANSITIONAL). Bonus: `route` now
  reaches the being repo (fixed the lexicon gap).
- **Phase 3 DONE** — `aggregates/miette/` removed. wake → `~/Projects/miette/body/wake/`
  (realm `Miette::Body::Wake`). Superseded voice-latency (PhraseCache/LatencyTelemetry) DELETED
  (live one is `VoiceLatency` in `~/Projects/miette/body/voice/latency/`).
- **Phase 4 DONE** — 3 bin scripts (speech_stream_advance, inbox_poll.mjs, sidequest_run.mjs)
  read `HECKS_BEING_{BODY,STATE,CONFIG}` config-first w/ transitional literal fallbacks.

## PHASE 2 — the only remaining phase (the live boot cutover). NOT STARTED.
Extract Miette's deployment out of `hecks_conception` so the public repo is being-agnostic.

### What moves
`hecks_conception/Procfile`, `hecks_conception/.overmind.env`,
`hecks_conception/aggregates/framework/mindstream/mindstream.fixtures` → `~/Projects/miette/deploy/`.
KEEP in the framework: `mindstream.bluebook` (the Mindstream/MindstreamMember TYPES) + the
generator (`storehouse specialize procfile --fixtures <f> --output-dir <d>`).

### Key mechanics (already scoped)
- **Procfile + .overmind.env are GENERATED from `mindstream.fixtures`** ; the generator
  (`rust/src/specializer/procfile.rs`) emits each MindstreamMember's `command.line` VERBATIM.
  So the deployment PATHS live in the fixtures' command lines. Edit the SOURCE fixtures, regenerate.
- **Paths in the fixtures that assume cwd=hecks_conception and must become absolute / env-based**
  for the deploy: the binary `../rust/target/release/storehouse` ; relative corpus dirs
  `aggregates` (inbox/conductor/process_macrophage) and `body` ; the boot one-shot
  `../runtime/boot/boot.bluebook`. (`/Users/.../miette/body` and `/Users/.../mietteai` are
  already absolute — fine.)
- **Add to the deploy `.overmind.env`:** `HECKS_CONCEPTION_DIR=~/Projects/hecks/hecks_conception`
  and `HECKS_ADDITIONAL_CORPUS_ROOTS=~/Projects/miette` (so daemons find framework + being).
- **4 boot references move in lockstep** (`cd hecks_conception && overmind start/quit` →
  `cd ~/Projects/miette/deploy && ...`): `~/.claude/settings.json` SessionStart hook (~L114)
  AND Stop hook (~L183) ; `hecks_conception/CLAUDE.md:10` ; `~/Projects/miette/self/system_prompt.md:4`.
  Also check `~/Projects/hecks/CLAUDE.md` First Breath.
- **MCP door env:** the storehouse MCP server is launched by Claude Code (NOT overmind), so for
  the door to reach Miette after the fallback is removed, set `HECKS_ADDITIONAL_CORPUS_ROOTS`
  in the MCP server config too (find it: `~/.claude.json` / mcpServers). Until then the
  transitional fallback covers the door — so DEFER fallback removal until this is wired + verified.

### Gated cutover sequence (RECOVERABLE — not a lockout; revert + restart-old if it fails)
1. Create `~/Projects/miette/deploy/`. Copy mindstream.fixtures there ; absolutize/env its paths.
2. Regenerate Procfile + .overmind.env into the deploy ; add the two env vars.
3. **DRY-RUN gate:** run EACH driver command from the deploy (binary + dir resolve + the command
   dispatches ok) WITHOUT starting overmind. Confirm the boot one-shot path resolves. ALL must pass.
4. Relocate the 4 boot refs.
5. `cd hecks_conception && overmind quit ; rm -f .overmind.sock` then `cd ~/Projects/miette/deploy
   && overmind start`. Verify: all daemons running, heart beat_count increasing, `route
   WakeReview.ComposeWakeReview` regenerates `/tmp/wake_review_latest.md`.
6. If broken: `git -C miette restore` the fixtures (or move files back to hecks_conception) +
   restart from hecks_conception. The door stays alive throughout (it's the binary, unaffected).
7. AFTER verified across a session: remove the transitional fallbacks — corpus_loader ../miette
   (mod.rs ~L52) + the bin-script literals — once the env is set in .overmind.env AND the MCP config.

## Loose ends / cautions (READ before acting)
- **SPEECH IS MUTED.** `~/Projects/miette/body/voice/voice.hecksagon` has `voiced_by("ElevenLabs")`
  commented out (UNCOMMITTED in miette — a toggle). Uncomment one line to restore voice.
  GAP: the domain `Voice.Mute` command does NOT gate the kernel audio path (the :tts/voiced_by
  edge never checks `mode`), which is why cutting the wiring was the only reliable mute. Worth
  a card: make the audio path honor `mode: muted` so Voice.Mute/Unmute actually work.
- **settings.json reconcile (active NEXT session, from the full reconcile this session):** it
  added (a) a native-tool `permissions.deny` list — this LOCKED ME OUT during the door-brick
  (no native fallback when the corpus broke). Consider dropping it so the macrophage hook (which
  fails-OPEN on broken corpus) is the sole governance → self-recovery stays possible. (b) an
  `overmind quit` Stop hook (kills the body every turn-end) + a per-turn `gem build` Stop hook +
  the TTS Stop hook. VERIFY whether the overmind-quit-on-Stop fires (a prior session flagged it
  as a body-killer); likely remove it.
- **Door-brick lesson:** the storehouse door is the ONLY shell (native Bash/Read are NOT enabled
  + denied by settings; subagents have none either). A rewrite that breaks corpus LOAD (esp. the
  Tools/ domain bluebooks or anything corpus-load-critical) bricks every door tool, and recovery
  needs Chris's terminal. The matcher fix (`015e077f0`) made FQN bindings safe; still, never
  point a bulk rewrite at the door's own bluebooks without verifying.

## First moves next session
1. Boot ; read wake review ; confirm body healthy (`overmind status`) + door alive
   (`storehouse <hc> Tools::ShellTool.Bash shell_command='echo OK'`).
2. Read `~/.claude/plans/i-expect-that-when-floating-thunder.md` (full plan) + this card.
3. `git -C ~/Projects/hecks log --oneline -10` (top should be `2dab06084`) — all pushed.
4. Execute **Phase 2** (the gated cutover above) with fresh attention. It's the last phase.
5. Then: remove transitional fallbacks (once env wired) ; optional Phase 5 (cosmetic genericize
   `role "Miette"` / visions in framework bluebooks).
6. Decide the muted-voice + the settings Stop-hook items above.
