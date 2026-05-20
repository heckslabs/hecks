---
ref: i648
status: v2-shipped
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Chris: file this one)
category: framework / process_health / macrophage
value: 'ProcessHealth domain — the runtime-layer immune cell. Watches process managers (overmind) and individual daemons (heart, breath, voice, restart_prompt, ...) and detects hangs / deaths the moment they happen, rather than letting work continue past silent corpses. Sister to the discipline-layer Macrophage (which watches bluebook drift). First concrete shape of i646 (macrophages-become-Protectors) for runtime processes. v2 (2026-05-20) gives Heal teeth — the :exec adapter binds Heal to bin/process_health_heal.mjs which actually runs `overmind restart <process_name>` (or `overmind start -D` when the supervisor itself is dead).'
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
  process, dispatches MarkX per sentinel), `Heal` (records the
  dispatch + emits `HealRequested` ; the :exec adapter binding
  runs `bin/process_health_heal.mjs` which actually invokes
  `overmind restart <process_name>` — see "v2" section below).

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

## v2 (2026-05-20) : Heal has teeth

Sweep computes health and emits per-sentinel MarkX dispatches.
Heal now :

- stamps `last_heal_attempted_at` on the macrophage and bumps
  `heals_requested` (bluebook side, pure) ;
- emits `HealRequested` (event) ;
- and (via the `:exec` adapter binding in `process_health.hecksagon`)
  fires `bin/process_health_heal.mjs`, which :
  1. resolves the `overmind` binary (loud failure if absent — the
     `:exec` cascade carries the failure to `Cascade.RecordResult`) ;
  2. checks for `.overmind.sock` + `overmind ps`. If the supervisor
     is dead → `overmind start -D` from `hecks_conception/` ;
  3. reads `process_sentinel.heki` for `state=dead` records and
     runs `overmind restart <process_name>` per dead sentinel ;
  4. dispatches `ProcessSentinel.MarkAlive` on each restarted
     sentinel so the `ProposeHealOnDeath` policy doesn't re-fire
     on the next sweep (a state=dead → Heal → MarkDead → Heal loop
     would otherwise restart in a tight cycle).

The bluebook stays pure ; the script is the impure executor. The
cascade carries stdout/exit_code into `Cascade.RecordResult`,
joinable against the originating Heal invocation by id.

## v1 boundary (historical, retired by v2)

The original v1 ship was proposal-only : Heal emitted `HealRequested`
without actually killing or restarting anything. v2 (this card)
closes that gap — the immune cell now both sees AND acts. The
proposal/action separation is still honest : the bluebook emits
the request ; the impure layer (the `:exec` script) is what acts,
and its outcome is auditable through `Cascade.RecordResult`.

## v1 ship (2026-05-20 morning)

- `process_health.bluebook` — parses + validates clean
  (`VALID — ProcessHealth (2 aggregates)`).
- `process_health.behaviors` — 19/19 tests green.
- `process_health.hecksagon` — :exec adapter binds Sweep to
  bin/process_health_sweep (script remains follow-up work — the
  binding is contract-of-record).
- `mindstream.fixtures` — adds `process_macrophage` MindstreamMember
  on a 30s cadence.
- Procfile — manual entry mirrors the fixture
  (`process_macrophage: ../rust/target/release/storehouse loop aggregates ProcessHealth::ProcessMacrophage.Sweep --every 30s`).
- Branch : `feat/process-health-macrophage`.

## v2 ship (2026-05-20 evening — Heal has teeth)

- `process_health.bluebook` v2026.05.20.2 :
  - new attribute `last_heal_attempted_at` on ProcessMacrophage ;
  - `Heal` command extended : stamps the new timestamp via
    `then_set`, surface description rewritten to declare the
    bind to the :exec script.
- `process_health.behaviors` — 20/20 (new test
  `Heal stamps last_heal_attempted_at`).
- `process_health.hecksagon` — second :exec adapter binds
  `ProcessMacrophage.Heal` to `node bin/process_health_heal.mjs`
  with `result_into: Cascade.RecordResult`.
- `bin/process_health_heal.mjs` — Node script. Mirrors
  `bin/inbox_poll.mjs` pattern.  Resolves `overmind` on PATH (loud
  failure if missing) ; detects supervisor liveness via
  `.overmind.sock` + `overmind ps` ; runs `overmind start -D` from
  `hecks_conception/` if the supervisor is dead ; otherwise walks
  `process_sentinel.heki` for state=dead records and runs
  `overmind restart <process_name>` per ; dispatches `MarkAlive`
  after a successful restart so `ProposeHealOnDeath` doesn't loop.
- Branch : `feat/process-health-heal-v2`.

## Relation to i646

i646 proposes the macrophage become a Protector with Inspect,
CallForHelp, Destroy. ProcessHealth maps that vocabulary onto
runtime processes :

| i646 Protector verb | ProcessHealth analogue              |
|---------------------|--------------------------------------|
| Inspect             | Sweep (gather signal, classify state) |
| CallForHelp         | Heal (emit HealRequested + :exec adapter runs overmind restart) |
| Destroy             | (still deferred — kill semantics distinct from restart ; future card) |

This is the first concrete shape of i646 for the process-liveness
substrate. The bluebook-drift Macrophage retains its current
Inspect-equivalent (PostToolUse hook + per-rule sweeps) ; this is
the sibling for runtime liveness.

## Follow-ups (not in scope tonight)

- `bin/process_health_sweep` script — the impure walker that
  satisfies the Sweep :exec adapter contract. Implements the four
  signal layers and dispatches MarkX per sentinel. (v2 ships the
  Heal script ; the Sweep script remains follow-up work.)
- Heartbeat-derivation rule — which domain event counts as a
  heartbeat for which watched process (heart → Heart.Beat,
  breath → Breath.Inhale, voice → ?, restart_prompt → ?).
- Statusline surface — display unhealthy sentinels alongside the
  existing heartbeat readout.
- `Destroy` verb (i646 mapping) — distinct from restart : actual
  process kill semantics for situations where restart isn't safe.

## Acceptance

v1 (closed) :

- [x] `process_health.bluebook` parses clean.
- [x] `process_health.behaviors` all green (19/19).
- [x] `mindstream.fixtures` has a `process_macrophage` member.
- [x] `Procfile` includes the entry.
- [x] Inbox card i648 exists and links to i646.
- [x] Push to `feat/process-health-macrophage` (do NOT merge to main).

v2 (this card, 2026-05-20 evening) :

- [x] `process_health.bluebook` parses clean (v2026.05.20.2).
- [x] `process_health.behaviors` all green (20/20).
- [x] `process_health.hecksagon` declares both Sweep + Heal
      :exec adapters.
- [x] `bin/process_health_heal.mjs` exists, satisfies the contract,
      and follows the inbox_poll.mjs pattern.
- [ ] Pre-push .behaviors gate green (worktree pushes defer the
      heavy gate per the hook's worktree branch — CI is
      authoritative).
- [ ] Push to `feat/process-health-heal-v2` (do NOT merge to main).
