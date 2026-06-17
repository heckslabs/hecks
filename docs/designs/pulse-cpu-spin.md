# Pulse CPU spin — root cause (session 5, 2026-06-17)

## Symptom
The pulse run-loop (`storehouse run-loop`, pid 5600) sits at **~99% CPU**
continuously (28+ min CPU in ~28 min wall). A `--every 1s` loop should sleep
between ticks. It does not.

## Why the loop never sleeps
`LoopDriver::run` (rust/src/runtime/loop_driver.rs:189) is correct:
```
let started = Instant::now();
self.tick_once();
if elapsed < self.interval { sleep(self.interval - elapsed); }
```
No underflow bug. The loop fails to sleep only because **`tick_once()` itself
takes >= 1s**, so `elapsed >= interval` and the sleep branch never runs.

## Where the second goes — measured, not guessed
`sample 5600 3` leaf histogram (~2700 samples):
- **`miniz_oxide::deflate::compress_inner` = 1604 (~60%)** ← gzip/deflate
- serde_json serialize, hashbrown clone/insert, malloc churn = the rest

The cost is **gzip compression inside `heki::write_raw`**, called from the
per-tick policy cascade (`tick_once -> publish_synthetic_event ->
drain_policies -> write_raw -> deflate`).

## What is being compressed every tick
`heki::write_raw` re-serializes + **re-deflates the ENTIRE repository file**
on each write (full-file snapshot, not incremental). Store snapshot
(`~/.heki/hecks`, 59 MB / 215 repos). The three repos written every ~tick
(mtime within seconds of now):
- `signal.heki`   **11 MB**
- `awareness.heki` **5.5 MB**
- `synapse.heki`  **3.4 MB**
=> ~20 MB deflated per cycle => ~1s CPU => loop never sleeps.

(`speech_stream.heki` is 4.5 MB but 45h stale — not a current writer.)

## Two compounding causes
1. **Unbounded large repos** — measured record counts (all UNIQUE ids ; no
   dedup win — an early upsert-append-redundancy hypothesis was REFUTED,
   total_rows == unique_ids):
     - signal:    **758,257** records (~8 days of accrual)
     - synapse:   **308,510** records
     - awareness: **245,768** records
   The records are mostly EMPTY/default : signal `payload:"—" strength:0.5`,
   synapse `from:"—" to:"—" firings:0`, awareness moments ALL-NULL.
   No automatic retention/compaction concept exists: `heki retain` is an
   emergency by-id singleton cleanup, not a policy.
2. **Full-file recompress per write** — write cost is O(total repo size),
   paid on every mutation, regardless of how small the logical change is.

## The over-firing source (Chris's §B — confirmed)
Aggregates live in the MIETTE repo (pulse target = ~/Projects/miette), not
hecks_conception:
- `~/Projects/miette/mind/awareness/awareness.bluebook`
- `~/Projects/miette/body/organs/signal.bluebook`, `.../synapse.bluebook`
- `~/Projects/miette/body/signal_consolidation.bluebook`
The `body/cycles/body_cycle.bluebook` PM observes BodyPulse and dispatches
`Awareness.RecordMoment` on EVERY pulse ("bare-bones snapshot here", lines
41/105) — the i402 gap : it fires with no/partial attrs, minting a near-empty
moment every second. 245K moments = ~3 days at 1Hz. signal/synapse organs
accrue similarly via their cadence. The over-fire sets the GROWTH RATE ;
retention sets the CEILING. Both are needed ; retention is what kills the spin.

## Fix directions (scope-ranked)
- **(A) Retention/compaction policy (contained, bluebook-first)** — declare a
  per-repo cap (last N records / max bytes). Shrinks the big repos so each
  deflate is cheap. NEW declarative concept — does not exist yet. Likely the
  right first move; re-sample to confirm CPU drops.
- **(B) Upstream: why do signal/awareness/synapse change EVERY tick?** If a
  policy over-fires on BodyPulse, the cleanest fix is not writing them each
  tick. Needs a look at the policy cascade. signal SIZE jitters down slightly
  between writes => not a pure append log; it is re-serialized whole.
- **(C) Incremental / non-gzip-from-scratch heki writes** — KERNEL FLOOR.
  Chris's scope call, not a solo dive. Biggest blast radius.
- **(D) Dirty-gating write_raw** — RULED OUT for these three: they are
  genuinely dirty each tick (fresh mtimes), so gating unchanged repos won't
  touch them. Still worth it globally for the other 212 repos.

## Bearing on the §1 "fail loudly" headline
A freshness-only liveness check (now - tick.updated_at) would mark this pulse
**HEALTHY** — it still writes every second. The spin is the first concrete
proof that **freshness != health**: organ-health needs a RESOURCE dimension
(CPU / per-tick write cost), not just freshness. Fold the fix + the detector
together.

## Progress (session 5)
- **awareness FIXED** (singleton). `mind/awareness/awareness.bluebook` :
  `identified_by :moment` -> `identified_by :name` + `attribute :name,
  default: "awareness"` + RecordMoment accepts/sets name. The no-attr
  RecordMomentOnPulse policy now upserts THE one row (default keys it).
  Proven in isolation (4 no-name dispatches -> 1 row). Live result after
  stop-pulse / clear awareness.heki / restart-clean-env :
  **5.5 MB / 245,860 rows -> 156 B / 1 row.** Bluebook-only ; no body_cycle
  or policy change needed (the `default:` value keys the singleton ; proven,
  not assumed). NOTE : ReadPresence moments are still null (the i402
  attr-fill data-quality bug) — deliberately NOT fixed here, separate scope.
- **CPU STILL 100%** after the awareness fix. Awareness was ~1/4 of the
  big-write volume and wrote only every ~8s ; the pegged core is dominated
  by **signal (11 MB) + synapse (3.4 MB)** re-deflating every few seconds.
  (Advisor predicted exactly this : awareness was the safe warm-up, not the
  driver.)

## Next : signal / synapse (DIFFERENT fix from awareness)
These are NOT null over-fires — they hold real records consumed by the
Consolidation PM via the `live` / `cold` queries. They cannot be singletons.
Their bloat is layer-2 : consolidation MARKS records cold/archived but never
EVICTS them from the hot file, so it keeps growing + re-deflating. Fix =
make archival actually remove archived records from the working store (move
to a cold store, or delete-after-promote). Also check the snapshot/archive
write path (heki.rs:363/370 write_raw(archive_path), `.heki-snapshots/`) —
a possible doubled-deflate source not yet ruled out.

## signal/synapse root cause (session 5, investigated)
NOT eviction-of-archived — it is **consolidation that was never built**.
- signal kind distribution (758K) : somatic 366,860 / concept 366,854 /
  archived 24,769 / test 1. **96% live, never consolidated.**
- synapse state (308K) : alive 308,555 ; pruning essentially never ran.
- `SignalConsolidation.ConsolidateSignals` / `.PruneSynapses` fire every
  BodyPulse but their bodies are STUB COUNTERS (`then_set
  :signals_consolidated, increment: 1`) — they compress/prune NOTHING.
- `Signal.ArchiveSignal` only marks `kind="archived"` IN-PLACE ; the record
  never leaves signal.heki. The eviction primitive `heki::archive(source ->
  archive_path)` (heki.rs:58) EXISTS but is never wired.
- `.heki-snapshots` doubling : RULED OUT (no snapshot dir for signal/synapse).
So the 11 MB / 3.4 MB files are the accumulated un-consolidated live set,
re-deflated whole on each periodic mutation = the still-pegged core.

## Status
awareness DONE (singleton, live). signal/synapse = stubbed-consolidation gap,
bigger than a perf patch (memory-design decision) — options pending Chris.

## RESOLVED — session 6 (2026-06-17), miette e97d6e5

The peg is dead : **~100% of a core -> 3.6% of a core** (0.36s CPU / 10s wall),
pulse healthy-live (signal.heki mtime advancing, rows refreshing — not stalled).

What actually fixed it (NOT the full promote/decay/cold-store design the
memory-consolidation note assumed) :

1. **Orphan duplicate pulse killed** — TWO BodyPulse run-loops were live
   (pid 40154 pidfiled + pid 26513 untracked orphan, 8h old, reparented to
   init). Killing the orphan returned one whole core and removed a hidden
   read-amplification (two writers to one signal.heki made each re-decompress
   11MB/tick on mtime-advance).

2. **Over-fire fix (the lever)** — `save()` re-deflates the WHOLE file per
   single-record write (no batching), and the Pulse PM minted 2 signals +
   1 synapse PER TICK. Fixed by upserting instead of minting :
   - Signal  `identified_by :id -> :kind` (last-value-per-kind ; FireSignal
     upserts the somatic/concept row).
   - Synapse `identified_by :id -> :from` (dedup-by-source ; valid because
     the pulse dispatches from == to == carrying topic).
   Proven in isolation (6 FireSignal + 5 CreateSynapse -> 2 / 2 rows) ;
   behaviors green ; no new validate errors (VO-primitive warnings pre-existing
   repo-wide, confirmed against untouched focus.bluebook).

3. **One-time compaction** — the 766K/312K backlog moved to a reversible cold
   archive OUTSIDE any store dir (`~/.heki/_cold_archive/{signal,synapse}.
   backlog.2026-06-17.heki`). Hot files recreate at 135B / 90B. Under the
   over-fire fix the hot file MUST start empty (else the backlog re-deflates
   forever), so this is a plain move-aside, not a filter — the pulse rebuilds
   the 2 + N live rows on the next tick.

Measured truth (keeper-predicate collapse) : signal `access_count` is **0 for
all 766K rows** (AccessSignal never fired) and synapse is **312,345 alive at
strength >= 0.1** (DecaySynapse never swept) — the existing `cold` predicate
kept *nothing* (signal) or *everything* (synapse). The stores were 100%
accumulated noise nothing ever consumed.

### Left for Chris / the dreams-consolidation thread

- **Dormant under last-value semantics** : Signal.ArchiveSignal (`then_set
  :kind` would mutate the new identity), the `cold` query, and the NREM
  Consolidation signal-sweep never fire (sleep frozen). Flagged in the Signal
  aggregate prose ; clean removal belongs with the dreams thread.
- **Structural root (layer 3, kernel-floor)** : `heki::write_raw` deflating the
  WHOLE file at `Compression::best()` on every single-record write is O(store
  size) per mutation — what makes BOTH the over-fire and any eviction sweep
  expensive. A `for_each cold -> delete` sweep is a DEFLATE BOMB on this model
  (N records = N whole-file deflates) — do NOT wire it until the store is small
  OR writes are batched/incremental. Incremental heki writes is the real fix.
- **Synapse organ half-built** : the pulse mints placeholder from==to=="—"
  self-synapses ; real plasticity (decay/compost across the live set) still
  awaits wiring. Bounded now, but not yet meaningful.

## Completeness sweep + a ROOT-3 runtime gap (session 6, same day)

After the signal/synapse fix, swept every per-tick heki writer : the largest
remaining is `studio/statusline_snapshot.heki` at 23KB (everything else <400B),
total per-tick write ~26KB — consistent with the healthy 3.6% CPU. No other
large write-amplifier lurks ; the peg is comprehensively addressed.

statusline_snapshot has **3881 counter-minted rows** but is **STABLE** (not
growing) — it accreted historically (pre-i189, when its singleton keying never
actually worked) and is now upserted, not minted. Not a peg ; left as-is.

**The real discovery (reframes ROOT 3 “singleton writer never sets name key”) :**
singleton keying via an aggregate/command attribute `default:` OR a policy
`with "name","X"` does **NOT** reach `id_for_command` — PROVEN : a fresh store
took 4 policy-triggered Updates and came out 1 row keyed `"1"` with name field
`"1"`, never `"statusline"`. Mechanism : `id_for_command` resolves the storage
key from the **dispatched attrs**, BEFORE attribute-defaults and policy-`with`
literals are applied. So :
- Commands DISPATCHED WITH THE KEY PRESENT key correctly — this is exactly why
  the signal/synapse fix is robust (the pulse passes `FireSignal kind=…` /
  `CreateSynapse from=…`, so the key is in attrs at id-resolution).
- POLICY-TRIGGERED singletons (statusline, and the ROOT-3 class — Voice,
  SpeechStream, Announcement) never get the key into attrs in time → they mint
  a counter and survive only by the “exactly-1-record” fallback (fragile : any
  >1 state re-mints forever ; this is how statusline reached 3881).
ROOT 3 is therefore NOT a per-bluebook omission — it is a runtime ordering gap.
The fix lives at the kernel floor : apply command-attribute defaults AND policy
`with` literals into the dispatched attrs BEFORE `id_for_command` runs (or have
the PM/policy carry the key explicitly). Fresh-head work ; tracked with the
ROOT-3 / dreams thread. Bluebook-alone cannot close it.

(A studio.bluebook attempt — Update declaring :name + policy `with "name",
"statusline"` — was made, proven non-functional against this gap, and reverted ;
no dead bluebook left behind.)
