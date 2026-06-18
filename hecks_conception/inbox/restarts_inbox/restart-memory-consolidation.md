# RESTART — implement memory consolidation (signal / synapse)

VOICE : I speak as myself — I / my / mine. This is MY memory we're building
the housekeeping for. Read this + `hecks/docs/designs/pulse-cpu-spin.md`
(the full diagnosis), then design before building.

## Why this exists
My pulse run-loop pegs a core (~100% of one CPU, continuously). Root cause,
fully diagnosed in session 5 : `heki::write_raw` re-deflates the WHOLE store
file at `Compression::best()` on every save, and my `signal.heki` (11 MB /
758K records) + `synapse.heki` (3.4 MB / 308K) get a periodic mutation that
re-deflates the whole thing each time.

**Awareness was already fixed** (session 5, committed miette a28e62e) :
singleton, 5.5 MB / 245,860 rows -> 156 B / 1 row. That did NOT unpeg the
core — signal/synapse are the drivers, and they are a DIFFERENT problem.

## The actual gap : consolidation was stubbed, never built
- signal kind distribution (758K) : somatic 366,860 / concept 366,854 /
  archived 24,769. **96% live, never consolidated.**
- synapse (308K) : alive 308,555 ; pruning never ran.
- `body/signal_consolidation.bluebook` — `ConsolidateSignals` /
  `PruneSynapses` fire every BodyPulse but are STUB COUNTERS
  (`then_set :signals_consolidated, increment: 1`). They compress/prune
  NOTHING.
- `body/organs/signal.bluebook` — `ArchiveSignal` only marks
  `kind="archived"` IN-PLACE ; the record never leaves the hot file.
- `heki::archive(source_path, archive_path, id, reason)` (heki.rs:58) is
  the real eviction primitive — EXISTS, never wired.
- `body/pulse_organs/pulse_organs.bluebook:117` notes the `for_each:`
  decay/compost/archive directives as FUTURE work.

## What to design (this is a MEMORY-DESIGN decision, not a perf patch)
- **Promote** : which signals become long-term memory? (concept vs somatic ;
  access_count threshold ; age.)
- **Decay / compost** : what fades? synapses with 0 firings ; signals never
  re-accessed. Delete or cold-store?
- **Cold store** : where evicted records live (a sibling archive .heki via
  heki::archive) so the hot file holds only the working set.
- **One-time compaction** : drain the 758K / 308K backlog (the already-cold
  + archived first ; then the consolidation rules over the rest).
- Bluebook-first : make `ConsolidateSignals` / `PruneSynapses` actually DO
  the work (real then_-clauses / for_each eviction), not counters.

## Acceptance
After the fix, re-sample the pulse pid (`~/.heki/hecks/.mindstream.pid`) :
cpu-seconds over a 3s wall window should be a FRACTION of a core, not ~3s.
The hot signal.heki / synapse.heki should hold a bounded working set.

## The deeper amplifier (separate, optional, kernel-floor)
Even small stores aside, `heki::write_raw` re-deflating the whole file at
`best()` per save is O(store size) per mutation — a latent footgun for any
large store. Incremental / non-whole-file heki writes is the kernel-floor
fix that would make store size irrelevant. Chris's scope call ; gated
worktree + design pass if taken.

## Standing constraints
- Every tool call through the storehouse door. Bluebook-first. Files <200
  LoC. No `git add -A`. Let antibody/macrophage BLOCK + surface per file.
- Prove the eviction in an ISOLATED store (own HECKS_INFO dir, dispatch
  the real bluebook) BEFORE touching the live store. (Session-5 lesson :
  bluebook file location != store location ; :default sends writes to
  ~/.heki/hecks regardless of the bluebook's dir.)
- Live-change sequence that worked for awareness : edit -> stop pulse
  (`storehouse daemon stop <pidfile>`) -> clear/compact store -> restart
  clean-env (`env -u HECKS_INFO storehouse daemon ensure <pidfile> <full
  run-loop cmd>`) -> re-sample.
