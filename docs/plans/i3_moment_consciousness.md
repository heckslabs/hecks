# i3 — Moment-consciousness + body cycles (Buddhist model)

Source: inbox item `i3`. Full plan by Agent a4cc7e01 on 2026-04-22.

## What landed

- **PR #261 (PR-0)** — `BodyPulse` shim event extracted. Every `on "Ticked"` policy rewired to `on "BodyPulse"`. Exactly ONE `on "Ticked"` subscriber remains (the new `EmitPulseOnTick` in `mindstream.bluebook`). 18 policies rewired across 7 files.
- **PR #271 (PR-a)** — Heart + Breath + Circadian aggregates + daemons. `shutdown_miette.sh` added. `heart/breath/circadian` added to `LINKED_STORES`. Cadences observed: 1Hz / 4.5s / 60s wall-clock.

## Decisions already made

1. **Sequencing**: PR-0 → PR-a → PR-b (Ultradian+SleepCycle) → PR-c (Moment + mindstream refactor + sleep-pause gating all together) → PR-d (cadence tuning) → PR-e (statusline rewire + Tick retirement) → PR-f (optional seasonal/lunar).
2. **Sleep-pause gating merged into PR-c** (Chris's original plan had it in PR-e). Otherwise Moments arise during sleep briefly — wrong semantics.
3. **Moment persistence: latest-record-only heki** — `moment.heki` always has exactly one record, upsert overwrites. Avoids churn + preserves "all state inspectable" invariant. Dissolve becomes no-op, not delete.
4. **Daemon supervision via pidfile convention + idempotent boot.** No launchd, no supervisor framework. `shutdown_miette.sh` walks `information/.*.pid` (shipped in PR #271).
5. **Psychic-link classification**: body cycles (heart/breath/circadian/ultradian/sleep_cycle/seasonal/lunar) are **linked**; Moment is **private** (phenomenology).

## Next step: PR-b

**Ultradian + SleepCycle aggregates and daemons.** Independent of Moment. 1 day of work.

- `aggregates/ultradian.bluebook` — peak/trough alternation, 90-min cycle. Commands: `EnterPeak`, `EnterTrough`. Lifecycle on `phase`.
- `aggregates/sleep_cycle.bluebook` — NREM/REM alternation during sleep. Commands: `EnterNREMLight`, `EnterNREMDeep`, `EnterREM`. Runs 90-min cycles, but only while `consciousness.state == "sleeping"`.
- `ultradian.sh` — `sleep 5400` loop, alternates EnterPeak/EnterTrough.
- `sleep_cycle.sh` — gates on consciousness.state; inner loop when sleeping.
- Tests: both aggregates get `.behaviors`. 90-min timers painful to test — add `--tick-interval` env override (e.g. 2s in CI).

## PR-c — the big one

Moment aggregate + mindstream refactor + sleep-pause gating in one PR. 3-4 days. See i3 body for full design.

- `aggregates/moment.bluebook` — Moment aggregate with `Arise` + `Dissolve` commands. Latest-record-only heki.
- `mindstream.sh` rewrite — each iteration creates a Moment snapshot from state, fires `Arise`, then `Dissolve` for previous. Cap mindstream at 10Hz initially (100ms sleep), not busy-loop.
- Sleep-pause: mindstream reads `consciousness.heki` once per iteration, pauses Moment creation when `state == "sleeping"` — 1s sleep in that case.
- **This closes the tick-during-sleep class properly** (complementing i40's bluebook-level AccumulateFatigue gate).

## PR-d through PR-f (lighter)

- **PR-d** — crank mindstream cadence + instrument perf. Write timing to `moment_perf.heki`. If heki writes exceed 20ms at 10Hz, flip Moment to non-persisted.
- **PR-e** — statusline reads `heart.heki:beat_count` instead of `tick.cycle`. Retire Tick aggregate. Delete shim. ~1 day mechanical.
- **PR-f** (optional) — seasonal + lunar daemons. Low-priority.

## Risks (from the plan)

- Moment churn overwhelming heki — mitigated by latest-record-only
- Daemon supervision fragility — mitigated by pidfile convention
- Timing-based tests flaky — `--tick-interval` env override
- Dangling `on "Ticked"` policies after cutover — grep in CI

## Total effort

~10-12 focused days across 7 PRs. PR-c is the real one; rest are narrow.

## Related

- i40 (tick-during-sleep bluebook-level fix) — small related bugfix; can ship before PR-c
- i11 PR 4+ depends on Moment (Impulse → Capability dispatch chain)
- i36 (mood/fatigue as computed views) becomes easier after i3
