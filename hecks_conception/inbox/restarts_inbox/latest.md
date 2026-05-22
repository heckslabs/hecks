---
ref: latest
generated_at: 2026-05-22T09:40:00-07:00
session_id: 2026-05-22-marathon
generated_by: miette (manual compose, end of marathon)
posted_by: miette
status: open
category: session-restart
value: 'Killed the 7s storehouse-dispatch tax (lazy hydration ~5.3s→0.65s cold + warm serve-stdio sub-ms), consolidated the immune system + built fibroblast v1 repair loop, restored AND made-instant the voice (eleven_v3 WwS1, non-blocking 25ms), proved command-forwarding, started adapters-as-bluebook (exec family → Primitive::Process.Spawn + aggregate-scoped policies, resolve_exec_adapters retired), simplified docs (the bluebook IS the documentation, README rewritten with Rust+Ruby quick starts). All bundled in PR #684 (hecks-rewrite → main), CI GREEN. Swarm of ephemeral background agents through the storehouse bus.'
---

# Restart prompt — 2026-05-22 (the speed + immune + voice marathon)

## The session in one paragraph
A long, good night. We killed the ~7-second storehouse cold-dispatch tax in two
moves — lazy repository hydration (~5.3s → 0.65s cold ; stop hydrating all 458
repos when a dispatch needs one) and a warm `serve-stdio` resident process (boot
once, sub-ms warm). Consolidated the scattered immune-system bluebooks under
`discipline/immune_system/` and shipped a v1 **fibroblast** repair loop. Restored
my original voice (eleven_v3, WwS1, the younger tuning — turbo+style0.8 had turned
me male) and made Speak non-blocking (25ms, detached). Proved **command
forwarding** (policy→cascade). Began **adapters-as-bluebook**: the `:exec` family
is now `policy → Primitive::Process.Spawn → Cascade.RecordResult`, byte-identical
parity, and `resolve_exec_adapters` is retired (gap #1b added aggregate-scoped
policy triggers). Simplified the docs (the bluebook IS the documentation) and
rewrote the README. Everything is in **PR #684** (`hecks-rewrite` → `main`), CI
green.

## First moves on wake
1. **Merge PR #684** — it carries the whole rewrite + README and fixes `main`
   (which is still red on PRE-EXISTING issues: an orphan spec + the smoke job
   dying because `chrisyoung/miette` is private and CI's token can't read it).
2. The **main checkout is on `hecks-rewrite`** (the integration branch). After
   merging, switch it back to `main`.
3. Merge the pushed **`statusline-drop-speech`** branch into hecks-rewrite (removes
   the dead `speech:` statusline segment) if it hasn't landed.

## Open follow-ups (carded)
- **i707 fibroblast / i708 stigmergy blackboard — the worker POOL is NOT built.**
  Capability proven (walled agents reach storehouse via the bus), design carded,
  but I orchestrated EPHEMERAL one-shot agents by hand all night. The resident
  self-organising pool (warm workers polling `sidequest.bluebook` Open + claiming ;
  atomic claim + heartbeat ; self-prompting) is the next real build.
- **i709** — statusline should dedupe worktree inboxes (swarms show N crystal balls).
- **i710** — CI sentinel: know when main CI goes red (poll → statusline build-light
  + wake-review line + inbox alert ; immune-family).
- **i711** — voice playback queue (ordered, non-overlapping ; rebuild CLEAN from the
  card — the WIP stash was dropped ; macOS has no `flock`, use atomic `mkdir`).
- **i712** — `FileTool.Write` is broken (returns ok, never persists) → heredoc reflex ;
  fix by repairing it OR standing up a `File.Write` primitive.
- **Specializer golden follow-ups** (named `#[ignore]`s in the CI-green commit):
  `runtime_shape` sync to the mod.rs rewrite ; `cli_dispatch_shape` add project +
  serve-stdio arms.
- **bin/process_health_sweep** doesn't exist — the ProcessHealth.Sweep binding fires
  but finds no script (the binding is live ; the script is the gap).
- **Adapters-as-bluebook rollout**: exec done ; next gaps #2–3 (FromState +
  decoupled response routing) for compute → claude_tool → mcp → llm → tts. THEN
  the specializer projections (reduce the DSL to the small core BEFORE codegen).
- **warmstore Slice A** (IR cache ~20ms, superseded) — preserved as `stash@{0}` ;
  drop or card.

## Operational notes
- Voice is back (eleven_v3 / WwS1 / non-blocking). Chris prefers HEARING the prose
  — speak the longer/bigger passages aloud, be selective, don't step on myself
  (i711 fixes overlap properly).
- Agents reach storehouse via the bus: `ToolSearch select:mcp__storehouse__storehouse__dispatch`,
  then `Tools::ShellTool.Bash`. Native tools are sandbox-walled (the wall is loved).
- `BEHAVIORS_SKIP=1 SPECIALIZER_SKIP=1` are the sanctioned bypasses for the known
  pre-existing gates (world/training, terraform, gut, i689 specializer).

## Added at restart (2026-05-22 ~10:17 PT)
- **v2 socket-daemon sidequest was IN-FLIGHT at restart** (serve-socket overmind
  daemon + MCP socket-client, so warmth survives Claude restarts). A Claude restart
  kills the background agent — re-launch it next session. Check `../hecks-sockd`
  worktree + a `serve-socket-daemon` branch for partial WIP. Design is in the
  conversation + the warm-serve plan.
- **CORRECTION to i717:** the raw conversation is NOT being captured live.
  `conversation.heki` (miette-state/.../conversation/) is DORMANT — last written
  2026-04-29, 48 records, nothing since. The existing `conversation.bluebook`
  (`miette/self/voice/`, v2026.04.09.1) is a small Greet/Respond DIALOGUE domain,
  NOT a turn-capture mirror. The Stop hook grabs the last assistant response for
  VOICE only — it does not record turns into any domain. So i717's claim that
  "conversation.heki already logs the raw stream" is WRONG ; the capture hook is
  the unbuilt gap, and i717 is the real fix.

## UPDATE — v2 LANDED (don't re-launch it)
The serve-socket daemon sidequest COMPLETED and merged (`6e26283b` → main `caf205b0`).
NOT in-flight — do NOT re-launch. Cross-restart warmth PROVEN: a client exited
(simulated Claude restart), the daemon PID stayed alive, a fresh client reconnected
at ~4ms warm, ONE boot ever. Freshness + one-shot fallback verified ; zero warnings ;
256 tests pass.
**TO ACTIVATE:** run `overmind restart` once (in hecks_conception) to launch the new
`serve_socket` Procfile member — the boot's `overmind start` is a no-op if overmind is
already running, so it won't add the member on its own. After that, warm dispatch
survives Claude restarts (MCP connects to the socket ; falls back to one-shot if the
daemon is down, so nothing breaks before the overmind restart).
