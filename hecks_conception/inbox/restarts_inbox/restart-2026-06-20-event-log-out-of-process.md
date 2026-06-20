# RESTART 2026-06-20 — the Event Log goes out-of-process (async projection)

VOICE : I / my / mine. Handoff from a very long session to my next self. Read this,
then START with §1 (the live Log is lossy right now — decide the stopgap first), then
build the out-of-process Log (§2). The hard architecture is decided ; what remains is
building it and a few blesses.

## The decision (Chris, just now)
The Event Log persistence is **OUT-OF-PROCESS (an async projection)**, NOT in-process.
Chris chose this explicitly over both keeping the proven in-process adapter AND over
append-based-heki. He **discards the in-process wiring**. The in-process work is the
reference/fallback, not the answer.

Why (the through-line) : the two-color rule. Per-aggregate persistence earned the ONE
in-process exception because find/save is bounded + structurally non-blocking. The
Event Log is none of that — it is IO on EVERY dispatch to a shared, ever-growing file
hit by every process at once. That is a shared async edge, and async edges live
out-of-process. Keeping it in-process also means a SECOND blocking-IO backend to
maintain ("double the blocking code").

## §1 — START HERE : the LIVE Event Log is LOSSY right now
On `main` (7c2297db0) the EventSourcing `Event` aggregate has NO `.hecksagon` binding
(only event_sourcing.bluebook + .behaviors exist there), so it persists via DEFAULT
heki — whole-file read-modify-write — which CLOBBERS under concurrent writers. The
daemons are restarted onto the new binary and event-sourcing is LIVE, so the live Log
is silently dropping events (proven shape : 30 concurrent -> 13/30 ; live : Inbox/Process
records vanished between two reads). DECIDE before building :
  (a) STOPGAP : merge the proven in-process adapter (worktree, below) to stop the
      bleed NOW, then replace it with out-of-process. Chris said "discard in-process
      wiring" — but that was about the END-STATE, not necessarily the interim. Flag it.
  (b) GATE : turn event-sourcing OFF (it is currently unconditional/default — Chris's
      earlier call) until out-of-process lands. Stops writing a lossy Log.
  (c) ACCEPT lossy meanwhile (only if out-of-process lands same session).
My lean : (a) or (b) — do not leave a lossy governance Log running for days.

## §2 — BUILD : the out-of-process Log (the real work)
Shape : a SINGLE out-of-process writer (one owner of event.heki) that CONSUMES the
durable event stream and APPENDS with a plain monotonic counter. Single writer => the
sequence is trivial (no pid-nonce, no file-position-on-read — those gymnastics in the
in-process version exist ONLY because there was no single writer). The Event Log
becomes a PROJECTION of the stream, off the sync core. Reuse the existing
out-of-process machinery (adapter-host, OutboundEvent pattern, the tts/stripe handler
shape ; read adapters/tts/ + examples/adapter_host_demo/).

**THE MAKE-OR-BREAK PRECONDITION (advisor, verify FIRST) :** an out-of-process writer
consumes SOME upstream stream. If that stream is written by N processes via a LOSSY
mechanism, async just RELOCATES the clobber one level up + adds a daemon + eventual
consistency. So BEFORE building : confirm the stream it will consume
(storehouse.log ? a dedicated event channel ?) is itself append-safe, lossless, ordered,
and resumable-from-offset. If storehouse.log is whole-file-rewrite, it has the SAME bug
— fix that first or pick a genuinely append-only channel. This is the crux ; do not skip.

Known caveat : single-write O_APPEND atomicity is reliable for SMALL local-FS appends,
not guaranteed for large payloads / network FS. The property that actually buys
correctness is SINGLE-WRITER (in-process lock OR out-of-process owner) — do not conflate
"single-writer" with "out-of-process."

## Branch / worktree state
- `main` @ **7c2297db0** : event-sourcing wired (29aacf70c Log-as-truth + transitions ;
  d5dcd5f75 universal-door cascade sourcing), process_macrophage storm fix (d6673dce6),
  append-log design note (7c2297db0). The live binary is built from here.
- `feat/event-sourcing-log-append` @ **3b0a602ef** : ahead of main by ONE commit — the
  SendMessage receiver as a `:daemon` Driver + Pizzas cron Driver + the SendMessage
  follow-up fixes (Answered query `where(mid:)`, send-message bin rewired, agent_poll.sh
  reworked into the daemon loop, InboxPoller singleton + AllUnread query). Behaviors
  758/758, hecksagon parity 193/193. NOT pushed. PUSH after blessing §3 conventions.
- worktree `agent-acbbcf51b04ad8584` @ **c3c5e086c** (branch worktree-agent-acbbcf51b04ad8584)
  : the PROVEN IN-PROCESS append-log adapter (30/30). Reference/fallback. **CHERRY-PICK
  REGARDLESS** : its second-bug fix — `apply_per_domain_world_dirs` (rust/src/world/attach.rs)
  was re-rooting EVERY category-matched aggregate back to heki AFTER binding resolution,
  silently reverting Memory/Sql/AppendLog binds ; it now guards to only re-root
  backend_kind==Heki. That fix is independent of in/out-of-process and is real.

## §3 — Two conventions on the feat branch to BLESS before pushing to main
1. **cron, not interval.** `driving.bluebook` conceives an `interval` schedule kind, but
   it is NOT wired : the Ruby hecksagon DSL only has cron/http_post/file_watch and the
   runtime fires only `kind=="cron"` handlers. So `driving on interval` breaks hecksagon
   parity. Pizzas + agent_inbox use `driving on cron`. Real gap : either wire `interval`
   in both targets + the runtime, or retire it from the grammar.
2. **`:daemon`-adapter-naming-a-`bin/*.sh`** is net-new : nothing in the corpus had a
   `:shell`/`:daemon` adapter reference a bin script before. It is how agent_poll.sh
   became is-dispatched-recognized (declared, no marker). Parity-safe but invented.

## Antibody learning (I had this WRONG ; correct it everywhere)
`bin/antibody-check` -> `storehouse is-dispatched` exempts a script ONLY when a hexagon
`:daemon`/`:shell` adapter names it via `command:`/`args:`. NOT via a bluebook
`Primitive::Process.Spawn` policy, NOT via the `driving on` grammar. `bin/process_health_sweep`
survives via its `[antibody-exempt]` MARKER, not via being a declared handler — so
"mirror process_health -> no marker" was self-contradictory. The agent caught + corrected
this ; do not repeat the conflation.

## Shipped this session (all on main unless noted)
- Event sourcing wired into dispatch — Log as source of truth, transitions captured (29aacf70c)
- Universal-door sourcing — cascade reactions recorded too (d5dcd5f75)
- process_macrophage spawn-storm fix — single-instance mkdir lock ; restarted, storm-free (d6673dce6)
- append-log design note (7c2297db0)
- [branch] SendMessage receiver :daemon Driver + Pizzas cron Driver + SendMessage fixes (3b0a602ef)
- [worktree] proven in-process append-log adapter + world-dir-clobber fix (c3c5e086c)

## No agents still running. process_macrophage is live + storm-free.
