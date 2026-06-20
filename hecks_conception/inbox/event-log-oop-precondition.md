# §2 PRECONDITION FINDING — the out-of-process Event Log is BLOCKED on a topology choice

VOICE : I / my / mine. This is the make-or-break precondition the restart card
(restart-2026-06-20-event-log-out-of-process.md §2) said to verify BEFORE building
the out-of-process Event Log. Verified 2026-06-20. VERDICT : precondition NOT met.
Do NOT build §2 until the single-writer topology below is chosen — that choice is
Chris's + a fresh head's, not a deep-context session's.

## What I checked
The candidate upstream stream the out-of-process writer would consume :
`storehouse.log` (rust/src/runtime/storehouse_log.rs).

FINDING on storehouse.log : it IS append-mode (`OpenOptions::new().create(true)
.append(true)`), per-process Mutex, every daemon opens its own handle to the same
path. That is categorically better than the heki whole-file read-modify-write that
clobbers — at the single-LINE level, O_APPEND on local FS does not lose lines. BUT
it is disqualified as the upstream for TWO concrete reasons :
  1. LEVEL-GATED : `quiet` / `normal` / `verbose` gating means it SILENTLY DROPS
     events at the wrong level. A source of truth cannot be level-gated.
  2. MULTI-LINE RICH BLOCKS INTERLEAVE : the i697 `emit_dual` rich block is many
     lines → many `writeln!` calls → across processes, two daemons' blocks
     interleave (block A line 1, block B line 1, block A line 2 …). Not atomic as
     a unit. A block-parsing consumer would mis-frame.

## THE TRAP I almost fell into (advisor caught it)
My first lean was "fix it with a DEDICATED single-JSON-line-per-event append
channel, written by every process via O_APPEND." THAT HAS THE SAME BUG. O_APPEND
multi-writer atomicity holds ONLY for records < PIPE_BUF (~4KB), and POSIX does not
strictly guarantee it for regular files at all. Event records are NOT bounded :
`record_event_append` serializes `event.data` into the `inputs` JSON, and a Bash
command+output or a large file-read event sails past 4KB. So "one JSON line per
event, appended by N processes" is lossless for small events and SILENTLY
CORRUPTING for large ones. The card already said it : the property that buys
correctness is SINGLE-WRITER — do NOT conflate single-writer with out-of-process.

## THE REAL PRECONDITION (restated)
Not "is there an append-safe stream." It is : **what is the single-writer
serialization point, and how do N dispatch processes reach it losslessly for
ARBITRARY-SIZE payloads?**

## THE TOPOLOGY FORK (Chris + fresh head choose ; do not silently decide)
1. SINGLE OUT-OF-PROCESS WRITER via socket/queue. N processes SEND each event to
   one daemon ; the OS serializes the channel ; the daemon is the sole owner of
   event.heki. Handles any payload size. COST : when the daemon is down, events
   need a durable queue or they drop (a liveness gap to design for).
2. PER-PROCESS APPEND SHARDS, daemon MERGES. Each process is the SOLE writer of
   its OWN shard file (atomic at ANY size, no cross-process interleave) ; the
   daemon tails all shards and merges into the global ordered event.heki.
   Sidesteps BOTH the size limit AND the daemon-liveness gap (processes never
   block on the daemon ; a dead daemon just delays the merge, loses nothing).
3. MULTI-WRITER APPEND to one shared file. The one we CANNOT do — killed by the
   payload-size caveat above.

My lean (not a decision) : option 2. It is the only one that is lossless for
arbitrary payloads AND has no liveness-drop gap — each process single-writes its
own shard, the daemon's job is pure merge. But it trades a simple global order for
a merge step (the daemon must impose a total order across shards — e.g. by a
per-event monotonic timestamp or a Lamport-ish counter).

## THE QUALIFIER TO SURFACE TO CHRIS (do not assume)
EVERY option still puts SOMETHING per-dispatch IN-PROCESS — an append (opt 2) or a
socket send (opt 1). N processes must emit each event somehow. "Out-of-process"
moves the event.heki WRITE out of the sync core ; it does NOT move event CAPTURE
out — that stays in-process in N processes. Fine IF that in-process step is bounded
+ structurally non-blocking (a shard append is ; a socket send to a possibly-slow
daemon may not be). This is a material qualifier on "out-of-process" and is exactly
the kind of thing to confirm with Chris rather than assume.

## DECISION (Chris, 2026-06-20) : OPTION 2 — PER-PROCESS SHARDS + MERGE DAEMON
The out-of-process Event Log is built as : each dispatch process is the SOLE writer
of its OWN shard file (atomic append at ANY payload size, no cross-process
interleave) ; a single merge daemon tails every shard and merges into the global
ordered event.heki. Chosen over the socket/queue writer because it is lossless for
arbitrary payloads AND has no liveness-drop gap — a dead merge daemon only DELAYS
the merge, it never drops an event (the shards are durable on disk the instant the
producing process appends). The in-process per-dispatch step is a shard append,
which IS bounded + structurally non-blocking (local-FS append to a process-private
file), so the two-color rule is honoured : the sync core never blocks on the Log.

### Remaining DESIGN questions for the fresh head (build-time, gated worktree)
1. TOTAL ORDER across shards : the merge daemon must impose one global sequence
   over events that arrived in N independent shards. Options : a per-event
   monotonic wall-clock timestamp (simple, but clock skew / same-ms ties need a
   tiebreak — e.g. (timestamp, pid, per-process-seq)) ; or a Lamport-ish counter.
   Pick the simplest that gives a stable deterministic total order. The existing
   `recorded_at` ISO-8601 + a per-process sequence + pid is likely enough.
2. SHARD IDENTITY + PATH : one shard per process. Key by pid? By Procfile member
   name? Pid reuse across restarts means a pid-keyed shard could mix two process
   lifetimes — prefer (member-name + boot-nonce) or an append-only shard dir where
   each process opens a fresh uniquely-named shard at boot.
3. MERGE CHECKPOINT / RESUMABILITY : the daemon tracks a per-shard byte-offset
   high-water mark so a restart resumes each shard from where it left off (the
   restart card's "resumable-from-offset" requirement — now PER SHARD, trivially a
   file offset since each shard is single-writer append-only).
4. SHARD RETIREMENT : once merged past a shard's end AND its producing process is
   dead, the shard can be compacted/deleted. Needs a liveness signal (the
   ProcessHealth macrophage already tracks live pids — reuse it).
5. REPLACES the gate : when this lands, flip HECKS_EVENT_SOURCING semantics — the
   in-process `record_event_append` heki write is REMOVED (not just gated) ; the
   shard append replaces it. Chris : "discard the in-process wiring."

### Reuse (restart card §2)
The out-of-process MACHINERY already exists : adapter-host, the OutboundEvent
pattern, the tts/stripe handler shape (adapters/tts/ + examples/adapter_host_demo/).
The merge daemon is a `storehouse`-family daemon (sibling of the loop/clock/drive
processes) ; model its schedule + dispatch the same way, projected to a Procfile
member.

## BUILD STATUS (2026-06-20)
- SLICE 1 — DONE (on main, 3385eaf4c). event_shard.rs : append-only one-JSON-
  line-per-event format + writer + offset-resumable reader. 7 unit tests
  (round-trip, embedded-newline-stays-one-line, 8KB payload, write+read,
  offset-resume, partial-trailing-line-not-consumed, missing-shard-empty).
- SLICE 2 — DONE (on main, b6d90037c). event_merge.rs + `storehouse merge`
  daemon. merge_pass (read-each-shard-from-offset, sort by (ts,shard,seq)),
  write_batch_to_global (idempotent by event_id, assigns global sequence),
  checkpoint load/save. 5 unit tests INCL the proof : thirty_concurrent_
  writers_lose_nothing (30×50=1500 recovered, 0 dup — the 30/30 vs old 13/30)
  and replayed_batch_does_not_duplicate (crash-safety). Verified LIVE : 2
  shards -> global log, correct ts-order + sequence, delete-checkpoint-and-
  re-merge stays at 3 not 6.
- SLICE 3 — NOT STARTED (the live cutover ; deliberate go-live decision).

## SLICE 3 PLAN (the cutover — concrete, de-risked)
Reader-wiring check (advisor) RESOLVED : there are NO live Rust readers of
event.heki today — Replay/AtSequence are conceived in event_sourcing.bluebook
but NOT implemented in the runtime. So the only consumer is a future reader,
and the merge daemon writes the SAME path the Event repo uses
(~/.heki/hecks/event_sourcing/event.heki). Low reader risk.

The cutover steps :
1. record_event_append (runtime/mod.rs) : instead of dispatch_cascade
   EventSourcing::Event.Append (heki RMW to the shared global — the lossy
   path), build a ShardRecord and append it to THIS process's shard via a
   ShardWriter. The per-aggregate current-state (Snapshot) write is
   UNCHANGED — only the global-Log write moves to a shard.
2. Shard identity (q2) : one shard per process = (Procfile-member-name OR pid)
   + boot-nonce, so a pid-reused restart never mixes two lifetimes. Path :
   ~/.heki/hecks/event_sourcing/shards/<shard-id>.shard. Hold ONE ShardWriter
   in the Runtime (open once at boot), not reopened per dispatch.
3. Merge daemon as a Procfile member : `storehouse merge
   ~/.heki/hecks/event_sourcing/shards --global ~/.heki/hecks/event_sourcing/
   event.heki --poll 1s`. The Procfile is a PROJECTION of mindstream
   (mindstream.fixtures) — add the member THERE, then project (or hand-derive
   per the i262 gap). Restarts daemons.
4. Gate flip (LAST) : HECKS_EVENT_SOURCING currently gates the whole write
   off. After cutover the gate should gate the SHARD write ; default ON only
   once 1-3 are green AND a live N-process dispatch test shows the global log
   lossless. Un-gate is the final act — never before the merge member is live.
5. Global sequence : assigned by the merge daemon (slice 2), NOT the Event
   aggregate's count+1. Do NOT restore the aggregate's sequence logic.

Risk : this mutates the live dispatch hot path + adds a daemon (restarts the
body). Lower than feared (no live readers), but a deliberate go-live, best
thrown with Chris present, not at the tail of a long session.

## STATUS
- The lossy in-process Log is GATED OFF (HECKS_EVENT_SOURCING default off, committed
  d68e3b05d, on main). Nothing is bleeding. There is NO time pressure on §2.
- TOPOLOGY DECIDED (shards + merge daemon). §2 BUILD remains fresh-head, gated-
  worktree work — the 5 design questions above are byte-precise kernel judgement
  parity cannot verify, exactly what a low-context head should own. NOT this session.
