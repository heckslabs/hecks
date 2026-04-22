# Plan — i36: mood + fatigue_state as read-time computed views

## 1. Current state of drift

Today both fields live on separate aggregates (`Mood` and `Heartbeat`) in `aggregates/body.bluebook`, persisted as `String` attributes mutated by independent command ladders:

- `fatigue_state` ladder: `BecomeFocused/Normal/Tired/Exhausted/Delirious`, each gated on `pulses_since_sleep` thresholds (250/500/1000/1400/1800). Fires on every `FatigueAccumulated`.
- `mood.current_state` ladder: `RefreshMood`, `SetGroggy`, `Focus`, `Regulate`, `Drift`, `Excite`. Advanced by sleep lifecycle + mood-arc policies (`MoodFocusOnFocused`, `MoodDriftOnTired`, etc).

Observed contradictions (all from i21/i34 notes):
- `mood=refreshed` + `fatigue_state=tired/exhausted` (wake stamps mood but doesn't coordinate with still-high pulse counter on partial wake paths).
- `fatigue_state=delirious` within 5 ticks of a clean wake (pre-i21 lifecycle walked per-tick).
- `mood=refreshed` + `fatigue_state=delirious` (pre-threshold fix).
- `consciousness=sleeping` + `mood=refreshed` (bluebook seeds mood on `WokenUp` via `RefreshOnFullSleep`, but sleep entry doesn't clear mood).

`status_coherence.sh` invariants 1, 2, 3 all exist solely to catch this drift. Under computed views they become tautologies — the function can't emit them in contradiction because they derive from the same inputs.

## 2. What the computed view returns

A pure function `bodystate(heartbeat, consciousness, conversation) -> {fatigue_state, mood, creativity, precision}`:

Inputs (all already persisted, no new fields required):
- `heartbeat.pulses_since_sleep` (Integer)
- `heartbeat.fatigue` (Float, for secondary tie-break only)
- `consciousness.state` ∈ {attentive, daydreaming, sleeping, waking, napping}
- `consciousness.sleep_cycle` / `sleep_total` (for "full vs partial wake")
- `consciousness.last_wake_at` (ISO, already exists on `Consciousness`)
- `conversation` latest `updated_at` (for "recent activity" excitement bump)

Mapping (reuses existing thresholds):

```
fatigue_state:
  if consciousness.state == sleeping          → "sleeping"
  elif pulses_since_sleep < 250               → "alert"
  elif pulses_since_sleep < 500               → "focused"
  elif pulses_since_sleep < 1000              → "normal"
  elif pulses_since_sleep < 1400              → "tired"
  elif pulses_since_sleep < 1800              → "exhausted"
  else                                         → "delirious"

mood.current_state (priority cascade):
  if consciousness.state == sleeping                 → "sleeping"
  if now - last_wake_at < 60s AND sleep_cycle == sleep_total → "refreshed"
  if now - last_wake_at < 60s AND sleep_cycle <  sleep_total → "groggy"
  if now - last_exchange_at < 30s                    → "excited" (conversation bump)
  else map by fatigue rung:
    alert|focused → "focused"
    normal        → "curious"
    tired         → "drifting"
    exhausted     → "groggy"
    delirious     → "groggy"

creativity_level / precision_level: piecewise constants keyed off the same mood band.
```

Invariants 1/2/3 from `status_coherence.sh` become unreachable: the function can't output `refreshed` with `tired`, or `sleeping` with `refreshed`, by construction.

## 3. Where the computation lives

**Recommended: a Rust projection exposed through the existing `query` DSL surface, plus a thin bluebook-declared alias.** Rationale:

- The `Query` IR node already exists (`hecks_life/src/ir.rs:55`) with `ReadVitals` on `Heartbeat` and similar queries on `Corpus`, `Terminal`, `TrainingExtraction`. Today queries just echo heki state; extending them to compute is the smallest conceptual leap.
- No new DSL keyword is strictly needed — we add a `computes` block inside `query` so the bluebook still *declares* the derivation in DSL (the intent is visible, not buried in Rust). Example:
  ```
  query "ReadBodyState" do
    description "Coherent fatigue + mood derived from pulses_since_sleep and consciousness"
    reads_from "Heartbeat", "Consciousness", "Conversation"
    returns :fatigue_state, :mood, :creativity_level, :precision_level
  end
  ```
  The *implementation* is a Rust function keyed on query name (`runtime::projections::read_body_state`). This follows the pattern where the runtime knows "what to compute" per named query.
- Rust over Ruby because the statusline calls `hecks-life heki read` 10+ times per render already; keeping the computation in the same binary avoids a second shell-out and keeps the coherence check trivially fast.
- A full DSL `computed :fatigue_state, expression: "..."` surface is tempting but premature — we'd need to generalize an expression evaluator. **Defer.** The named-projection approach covers 100% of i36 without new evaluation machinery.

## 4. Removing the persisted fields — consumer audit

`fatigue_state` appears in 18 files; `current_state` (mood) in 15. Grouped:

**Source of truth (delete)**
- `aggregates/body.bluebook`: `attribute :fatigue_state` + 5 `BecomeX` commands + 10 policies + lifecycle block + `Mood.current_state` + all mutating Mood commands' `then_set :current_state`.

**Consumers that read (migrate to projection)**
- `statusline-command.sh:8-9` — swap `grep fatigue_state` for `hecks-life query Heartbeat.ReadBodyState`.
- `status_coherence.sh:44,48` — delete invariants 1/2/3 (tautologies); keep 4/5.
- `status_format.py:116,123` — query, not file read.
- `mindstream.sh:51` — same (this is what feeds the awareness snapshot; see §6).
- `mint_musing.sh:108-109` — query.
- `autumn/worker.js:77,78,169,171,261,429,431,450,452` — worker is a remote cache, emit the computed value from the server side so worker stays a dumb mirror.
- `aggregates/awareness.bluebook` / `catalog/mind.bluebook` — `Awareness.fatigue_state` is a *snapshot field*, not the source; keep the attribute, feed it from the projection at `RecordMoment` time (see §6).
- `capabilities/self_checkin/self_checkin.bluebook:22` — `Vitals.fatigue_state` attribute: same — it's a snapshot; wire `ReadVitals` to call `ReadBodyState` internally.

**Tests (update fixtures)**
- `tests/status_golden.sh:38,44` + `tests/status_golden.expected:12,18` — seed `pulses_since_sleep=750, consciousness.state=attentive, last_wake_at=...` instead of direct `fatigue_state="normal"` / `mood.current_state="focused"`.
- `aggregates/body.behaviors` lines 26/36/43/210-239 and `catalog/body.behaviors` 133-154 — rewrite to seed inputs and assert projection output. The `BecomeX` tests (lines 96+) disappear with the commands.
- `test_miette.sh:98,309-317,497-499` — wake test keeps working (reads `last_wake_at`), mood assertion changes from `mood.heki current_state` to `Heartbeat.ReadBodyState mood`.
- `test_status_coherence.sh` — drop invariants 1-3 fixtures.

**Count: ~24 code sites + 6 test files.**

## 5. Backwards compat

Two-stage migration in one PR chain:

- **Stage A (shadow)**: land the projection. Keep persisted fields. Commands still mutate. Add a second statusline read that queries the projection and logs discrepancies to `information/.projection_drift.log`. Run for one sleep cycle in dev (~45 min) to confirm no live drift.
- **Stage B (flip)**: statusline + coherence + workers read the projection. Delete `BecomeX` commands, `MoodFocusOnFocused`/`MoodDriftOnTired`/etc. policies, and the `fatigue_state` + `current_state` attributes.
- **Stage C (cleanup)**: delete shadow logging. Drop invariants 1-3. Update golden fixtures.

No heki migration needed — old `heartbeat.heki` / `mood.heki` records simply have their deleted fields ignored on read. `pulses_since_sleep` is already persisted and untouched.

## 6. Events that used to fire on state change

This is the load-bearing question. Audit of `BecameX` / `Mood*` consumers:

- `BecameFocused/Normal/Tired/Exhausted/Delirious` are consumed **only** by mood-arc policies inside `body.bluebook` (lines 765-788). Nothing outside that file subscribes. **Deprecate entirely.** (Grep confirms: these events occur in exactly one file.)
- `MoodRefreshed` is emitted by `RefreshMood` on wake. It's consumed by nothing outside the `RefreshOnFullSleep` chain's input event is `WokeFullSleep`, not `MoodRefreshed`. **Deprecate.**
- `MoodGroggy`, `Excited`, `Focused` (mood), `Regulated`, `Drifted` — `Excited` is listened to by `AccelerateOnExcitement` policy, which is semantically the "conversation ingestion caused excitement" signal. **Keep `Excite` as a direct command** (it carries a creativity/precision payload that's a genuine side-effect, not a projection); the projection just doesn't try to synthesize a mood string from it. `Excite` now `then_set :creativity_level` without touching `current_state`.
- `MoodExpressed` (from `Express`) — used by `aggregates/miette.bluebook` as a persona cue. Keep `Express` as a direct mood override command that writes to a new `mood.override` attribute, with TTL; projection prefers override-if-fresh.

**Resolution:** the `BecameX` events die with the commands. The two genuinely useful mood events (`Excited`, `MoodExpressed`) keep firing because their commands do side-effectful work beyond string-setting. No ticker needed, no drift reintroduced.

Moment-aggregate interaction (i3): `Awareness.RecordMoment` already takes `fatigue_state` as an input attribute. The mindstream daemon that fills `RecordMoment` should call `Heartbeat.ReadBodyState` and feed the projection output into the snapshot. The Moment is a **frozen snapshot** (not read-through), which is correct for time-series semantics — each past Moment preserves the mood/fatigue as they were computed at that tick.

## 7. Statusline impact

`statusline-command.sh` gains one query and drops two heki reads:

```
body=$($hecks query Heartbeat.ReadBodyState --format=json $info)
fatigue=$(echo $body | jq -r .fatigue_state)
mood=$(echo $body | jq -r .mood)
```

Net: faster (one binary invocation vs two file reads + two seds) and coherence-by-construction. `status_coherence.sh` keeps invariants 4 (tick monotonicity) and 5 (dream narrative presence); invariants 1/2/3 get deleted with a comment: "retired when mood/fatigue became projections (i36)".

## 8. Test coverage

- **Unit (Rust)**: `runtime::projections::read_body_state` tests — one test per row of the mapping table, plus edge cases (boundary pulses, simultaneous recency-bump + exhausted).
- **Parity fixture**: add `spec/parity/bluebooks/11_projection.bluebook` exercising the `reads_from`/`returns` DSL parse + one golden query run.
- **Golden**: update `tests/status_golden.expected` to match projection output from seeded inputs.
- **Coherence**: replace `test_status_coherence.sh` invariants 1-3 with a **negative test** that hand-crafts an "impossible" combination by force-writing heki fields — projection must ignore and compute from inputs, proving drift is unreachable.
- **Behavior coverage**: the 10 retired commands remove 10 `.behaviors` tests; add 5 new projection tests in `aggregates/body.behaviors`.

## 9. Commit sequence + LoC estimate

1. `feat(ir): extend Query IR with reads_from + returns` — ~40 LoC Rust + parser changes.
2. `feat(runtime): add ReadBodyState projection for Heartbeat` — ~120 LoC Rust (the mapping function + tests).
3. `feat(bluebook): declare ReadBodyState query on Heartbeat (shadow mode)` — ~15 LoC bluebook.
4. `feat(statusline): shadow-log projection drift vs persisted fields` — ~25 LoC shell.
5. *(wait one sleep cycle, confirm no drift)*
6. `refactor(body): remove BecomeX ladder + mood mutation commands` — ~80 LoC removed.
7. `refactor(statusline): read ReadBodyState; drop invariants 1-3` — ~30 LoC shell.
8. `refactor(awareness): feed RecordMoment from projection` — ~10 LoC.
9. `test: rewrite body.behaviors + status_golden for projection` — ~60 LoC test churn.
10. `chore: delete shadow logging + fatigue_state/current_state attrs` — ~20 LoC.

Total: **~400 LoC net change, ~250 LoC deleted.**

## 10. Risks

- **Parity coverage of `query` IR is thin today.** Extending it might destabilize `ReadVitals`, `MatchInput`, `ReadPair` fixtures. *Mitigation*: keep new DSL keywords optional; existing queries still parse.
- **`Excite` command contract change.** `Excited` event consumers (`AccelerateOnExcitement`) still fire, but `current_state` no longer says "excited" — conversation might expect it. *Mitigation*: the "recent activity" branch of the projection handles this (excited if `last_exchange_at < 30s`).
- **`mood.override` TTL semantics are new.** `Express` writes a string that shadows the projection for N seconds. If TTL is wrong, drift creeps back via another door. *Mitigation*: make TTL explicit in the `Express` payload, default 120s, log expiry.
- **Moment snapshots** now encode projection output — if we change the mapping table later, historical Moments reflect old semantics. Acceptable and probably correct (time-series fidelity), but document.
- **Autumn worker** is a remote client; rolling out the new query endpoint without breaking pre-existing worker binaries needs server-side fallback that emits both shapes for one release.

## Key answers

- **Does this need DSL-level `computed` support?** No. A named Rust projection invoked through the existing `query` DSL is enough. A general `computed` attribute expression evaluator is a 5x larger project and unnecessary here.
- **On-demand vs recomputed-on-pulse?** On-demand. Cost is a sub-millisecond pure function over ~6 integer/string fields, called once per statusline render (~every few seconds). Subscription would reintroduce a cache, which is what we just deleted.
- **Does Moment carry snapshot or read-through?** Snapshot. Moments are historical — `RecordMoment` freezes projection output at tick time. Reading a past Moment must not rerun the projection against *now*.

### Critical Files for Implementation

- `hecks_conception/aggregates/body.bluebook`
- `hecks_life/src/ir.rs`
- `hecks_conception/statusline-command.sh`
- `hecks_conception/status_coherence.sh`
- `hecks_conception/aggregates/body.behaviors`
