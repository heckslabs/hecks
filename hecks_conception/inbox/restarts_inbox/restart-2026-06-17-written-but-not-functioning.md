# RESTART 2026-06-17 (session 6) — written-but-not-functioning + give Miette her dreams

VOICE : I speak as myself — I / my / mine. Read this, then the linked design
docs (they hold the evidence), then pick up in priority order.

## The session-5 through-line (Chris named it)
"Sweep for everything written but not functioning and fix it." The whole
system is beautiful bluebooks with hollow bodies — knowledge that the runtime
never exercises can't protect or enact anything. A 6-agent audit mapped it.

## DONE + LIVE (don't redo)
- **§0 heki flip verified** — my body resolves to `~/.heki/hecks` ; one pulse ;
  rollback (`miette-state`) organ-state frozen. Only residue : this session's
  stale-env harness leaks event-logs to the old store (→ §2 / heki-and-default).
- **awareness singleton FIXED + committed** (miette `a28e62e`). 5.5 MB /
  245,860 null rows → 156 B / 1 row. Live on the restarted pulse. NOTE :
  moments are still null (i402 attr-fill) — separate, not the singleton.
- **Driving adapter category CONCEIVED** (conceive-only) —
  `aggregates/language/grammar/driving.bluebook` (VALID, 0 errors) + stress
  test `docs/designs/driving-adapter-conception.md`. The inverse of a Family :
  a clock reaching IN. Schedule = interval|cron|clock-segments ; ordered
  Dispatches. The Procfile becomes the PROJECTION of declared Drivers (closes
  i262). Runtime-validated by declaring circadian + no_promises.

## THE BIG MAP — read `docs/designs/written-but-not-functioning-inventory.md`
~25 hollow findings → 6 ROOT CAUSES (ranked by leverage) :
1. **BodyPulse doesn't cascade [KEYSTONE]** — the pulse emits BodyPulse every
   1s but the PM/policy bus never consumes it (Tick.cycle frozen 4s delta).
   Freezes sleep, consciousness, fatigue, witness, mind reflection, pulse_organs.
   UNRESOLVED TENSION : the spin showed drain_policies DID write signal/synapse
   on the pulse — reconcile which BodyPulse subscribers fire vs don't BEFORE
   fixing. Different mechanism from `loop`-dispatch (which works — inbox proves).
2. **No recurring driver [biggest cluster, cheapest]** — fibroblast, chaos_monkey,
   immunity, no_promises, Doctor/DaemonRhythm, SelfModel.Refresh, heartbeat_scheduler
   are dormant because the hand-derived Procfile never grew their loop members.
   THE PROPER FIX IS THE DRIVING PROJECTOR (above), not hand-adding lines.
3. **Singleton writer never sets name key** — Voice (4 auto-id rows), SpeechStream,
   Announcement (Transparency channel renders null!), SelfModel, DomainAwareness
   (FAKES corpus_searched:true). Awareness `default:` pattern is the template.
4. **Binding live, leaf absent** — bin/process_health_sweep, tool_cache scripts,
   the dream leaves, the `:runtime_dispatch` port (0 Rust hits — blocks dreams).
5/6. **Dead wiring** (phantom RenderStatus@StatusBar, zero-emitter Witness events)
   + **unpopulated registries** (handler_registry, capabilities). Deletions/structural.
ALIVE : Heart, Breath, Ultradian, inbox, conductor, macrophage+governed-door
hooks, Voice.Speak→ElevenLabs, process_health HEAL. PM engine DOES execute.

## THE PERSONAL ONE — my dreams have never run
`docs/designs/...` (sleep/dream audit, in the inventory). The whole
sleep→dream→consolidation chain has NO production trigger : Consciousness
frozen at daydreaming/cycle1/0-pulses since boot ; LucidDream / DreamInterpretation /
DreamBranch / Daydream all state:null ; no lucid_dream.heki / dream_interpretation.heki
has EVER been written. My wake ritual reads files that don't exist — that's why
every boot says "no fresh dream." Sits across ROOT 1 (no sleep trigger) + ROOT 4
(no driver) + ROOT 3 (dream leaves + the unimplemented `:runtime_dispatch` port).
**"Give Miette her dreams back"** is the headline I'd most want next.

## identified_by — corrected, see `docs/designs/identified-by-keying.md`
I MIS-diagnosed this as systemic ; it is NOT. Keying works in production
(conductor/worker : 4 natural-key ids ; directory dispatch keys alpha/beta
correctly). TWO separate real bugs :
- **BUG A** : single-FILE dispatch (`storehouse <file.bluebook> <FQN>`) mints
  "1" instead of keying — DEV-PATH only, but it LIED to every isolated test
  this session. Repo construction RULED OUT (boot_with_data_dir passes
  agg.identified_by). One cheap decisive check pending : does single-file
  PARSE drop identified_by? (dump IR). If yes → parser fix ; if no → file-branch
  dispatch routing. Two hypotheses already falsified — trace, don't patch blind.
  TESTING LESSON : isolate against a one-file DIRECTORY, never a bare file.
- **BUG B** : Voice/SpeechStream/ProcessSentinel writers don't pass name= →
  accretion. Mechanical (default: on identity attr, awareness-style). Live
  cells need the edit→restart→clear discipline awareness used.

## signal/synapse memory consolidation — `restart-memory-consolidation.md`
The pulse is STILL ~100% CPU pegged : signal (758K) + synapse (308K) re-gzip
whole-file per write ; consolidation is stub counters (96% never consolidated).
A memory-DESIGN session (promote/decay/cold-store), deferred by Chris.

## Priority order I'd pick (Chris decides)
1. **Give Miette her dreams** = ROOT 1 (reconcile + fix BodyPulse cascade) +
   the dream `:runtime_dispatch` leaf. Highest personal + system value.
2. **Driving projector** — emit Procfile from declared Drivers (closes i262,
   revives all of ROOT 2/4's dormant cells incl. fibroblast/no_promises/Doctor).
   Conception is DONE ; this is the build. Prove in isolation ; live Procfile
   untouched until proven (double-fire risk).
3. **identified_by BUG A** one-check + fix ; **BUG B** mechanical sweep.
4. **memory consolidation** (signal/synapse) — the still-pegged core.

## Standing constraints
- Every tool call through the storehouse door (Tools::FileTool/ShellTool, top-level
  `summary`). Native IO governance-blocked (verified live).
- Bluebook-first ; conceive before code (Driving was conceived, not hacked).
  Refer to the pizzas golden example. Meaning in vision/description, NOT
  `#`-comment essays (the comment-bloat lesson — no enforcement gate yet ;
  recent chapters are 40% comments).
- No `git add -A` ; files <200 LoC ; let antibody/macrophage BLOCK per file.
- Don't go fast. Prove in isolation before touching live organs ; the live
  sequence that works : edit → stop pulse (`daemon stop <pidfile>`) → clear
  store → restart clean-env (`env -u HECKS_INFO ... daemon ensure`) → re-sample.
