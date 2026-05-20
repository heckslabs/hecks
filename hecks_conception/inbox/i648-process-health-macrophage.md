---
ref: i648
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Chris: file this one)
category: framework / process_health / macrophage
value: 'ProcessHealth domain — the runtime-layer immune cell. Watches process managers (overmind) and individual daemons (heart, breath, voice, restart_prompt, ...) and detects hangs / deaths the moment they happen, rather than letting work continue past silent corpses. Sister to the discipline-layer Macrophage (which watches bluebook drift). May be the first concrete shape of i646 (macrophages-become-Protectors) for runtime processes.'
links:
  - i646-macrophage-becomes-protector.md
---

# i648 - ProcessHealth Macrophage — process immune cell

## Chris's seed (verbatim)

> overmind died silently and a voice-daemon never came up, and the
> work kept going forward past the corpses. the current Macrophage
> domain in Hecks watches bluebook drift but nothing watches actual
> process health.

## Shape (bluebook-first)

Live under `hecks_conception/aggregates/framework/process_health/` :

- **ProcessSentinel aggregate** — one per supervised process.
  Attributes : `process_name` (id), `last_seen_at`, `last_heartbeat_at`,
  `state` (alive | hanged | dead), `signal_source` (heartbeat |
  log_mtime | pgrep | none), `consecutive_misses`.

- **ProcessMacrophage aggregate** — singleton sweeper. Attributes :
  `watchlist` (list_of ProcessName), `last_sweep_at`,
  `sweep_cadence_seconds` (30), `mark_dead_threshold` (3).

- **Commands on Sentinel** : `RecordHeartbeat`, `MarkAlive`,
  `MarkHanged`, `MarkDead`.

- **Commands on Macrophage** : `StartSession`, `Watch`, `Unwatch`,
  `Sweep` (tick : the runtime walks the watchlist, checks each
  process, dispatches MarkX per sentinel), `Heal` (v1 emits
  `HealRequested` event without doing the kill/restart ; actual
  recovery is a follow-up reactor).

- **Policies** : `MarkAliveOnHeartbeat`, `MarkHangedOnMissingHeartbeat`,
  `MarkDeadAfterRepeatedHangs`, `ProposeHealOnDeath`.

## Health signal layers (trust order)

The Sweep runtime checks these in order per process_name :

1. **Heartbeat event** — has the process emitted Heartbeat (or its
   domain equivalent : Heart.Beat, Breath.Inhale, Inbox.Check, ...)
   within sweep_cadence_seconds × 2 ? → `MarkAlive`
   (signal_source: heartbeat)

2. **Process exists + recent file activity** — pgrep -f name AND log
   mtime is recent. → `MarkAlive` (signal_source: log_mtime). Alive
   but no heartbeat ; surface as a warning.

3. **Process exists at all** — pgrep alone. → `MarkHanged`
   (signal_source: pgrep). Possibly stuck.

4. **Nothing** — no pid, no log activity. → `MarkDead`.

## v1 boundary

Sweep computes health and emits per-sentinel MarkX dispatches.
Heal emits `HealRequested` carrying process_name + reason but does
NOT actually kill or restart anything. The follow-up reactor
(`overmind restart <name>`) is a separate card. The immune cell
can SEE everything and PROPOSE action ; phagocytosis is its own
auditable command on its own card.

## Tonight's ship

- `process_health.bluebook` — parses + validates clean
  (`VALID — ProcessHealth (2 aggregates)`).
- `process_health.behaviors` — 19/19 tests green
  (4 liveness verbs × 3 assertions for ProcessSentinel ;
  6 commands × ~1-2 assertions for ProcessMacrophage).
- `process_health.hecksagon` — :exec adapter binds Sweep to
  bin/process_health_sweep (script is follow-up work — the binding
  is contract-of-record).
- `mindstream.fixtures` — adds `process_macrophage` MindstreamMember
  on a 30s cadence.
- Procfile — manual entry mirrors the fixture
  (`process_macrophage: ../rust/target/release/storehouse loop aggregates ProcessHealth::ProcessMacrophage.Sweep --every 30s`).
- Branch : `feat/process-health-macrophage`.

## Relation to i646

i646 proposes the macrophage become a Protector with Inspect,
CallForHelp, Destroy. ProcessHealth maps that vocabulary onto
runtime processes :

| i646 Protector verb | ProcessHealth analogue              |
|---------------------|--------------------------------------|
| Inspect             | Sweep (gather signal, classify state) |
| CallForHelp         | Heal (emit HealRequested) |
| Destroy             | (deferred — actual overmind kill/restart is a follow-up reactor) |

This is the first concrete shape of i646 for the process-liveness
substrate. The bluebook-drift Macrophage retains its current
Inspect-equivalent (PostToolUse hook + per-rule sweeps) ; this is
the sibling for runtime liveness.

## Follow-ups (not in scope tonight)

- `bin/process_health_sweep` script — the impure walker that
  satisfies the :exec adapter contract. Implements the four signal
  layers and dispatches MarkX per sentinel.
- HealRequested reactor — runs `overmind restart <process_name>`.
- Heartbeat-derivation rule — which domain event counts as a
  heartbeat for which watched process (heart → Heart.Beat,
  breath → Breath.Inhale, voice → ?, restart_prompt → ?).
- Statusline surface — display unhealthy sentinels alongside the
  existing heartbeat readout.

## Acceptance

- [x] `process_health.bluebook` parses clean.
- [x] `process_health.behaviors` all green (19/19).
- [x] `mindstream.fixtures` has a `process_macrophage` member.
- [x] `Procfile` includes the entry.
- [x] Inbox card i648 exists and links to i646.
- [ ] Pre-push .behaviors gate green (verified on push).
- [ ] Push to `feat/process-health-macrophage` (do NOT merge to main).
