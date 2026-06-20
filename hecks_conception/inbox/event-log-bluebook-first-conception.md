# CONCEPTION — the bluebook-first Event Log (shrink the kernel residue)

VOICE : I / my / mine. Chris asked "how much of this could be bluebook?" and said
"yes" to the refactor. This is the CONCEPTION (bluebook-first : conceive before
code). The slice-1/2/3a Rust is PROVEN (30/30 live) but imperative ; this captures
what becomes DECLARATION and what is the irreducible kernel floor. The runtime
PROJECTION is deep (a new persistence Backend variant + command→primitive routing
+ drive-fires-merge) — a focused arc, NOT a session-end bolt-on, and NOT half-
declared as inert binds (that is the written-but-not-functioning anti-pattern).

## The honest line : floor vs. shadow
IRREDUCIBLE KERNEL FLOOR (correctly Rust ; belongs in the primitive_registry,
the antibody-exempt "index of imperative kernel-floor leaves" where Process.Spawn
lives) :
  - shard byte-IO : O_APPEND write, seek-to-offset, read-to-last-newline
    (event_shard.rs). A bluebook cannot express "seek to byte N." Like heki.rs.
  - merge fold : read shards, sort, dedup, write global (event_merge.rs core).
  - the OS timer loop (run_drive's sleep/poll) — the Driver realization.
  - the tick→fire arithmetic (drive_scheduler : ceil(N/P), is_due). ~10 lines.

SHADOWS A BLUEBOOK (built imperatively, should be declared) :
  - ShardRecord (13 fields) DUPLICATES EventSourcing::Event. The shard write
    should serialize the Event aggregate, not a parallel struct.
  - run_merge (hand-written daemon) should be a `driving on interval` Driver
    firing a Merge command — fired by the `storehouse drive` already built.
  - record_event_append's direct shard call should be Event.Append routed to
    the AppendLog persistence adapter.
  - drive_scheduler's last_fired HashMap is the `Driver` aggregate's
    last_fired_at (the chapter retired 2026-06-20). State that could be modeled.

## THE DECOMPOSITION (what to declare, where)

### 1. AppendLog — a persistence adapter (the shard write path)
NEW `appendlog.adapter` (family "persistence", sibling of heki/memory.adapter) :
  Hecks.adapter "AppendLog" do
    family "persistence"
  end
BIND, in a NEW event_sourcing.hecksagon :
  EventSourcing::Event.persisted_by("AppendLog")
SEMANTICS : unlike Heki (whole-file upsert), AppendLog's save = APPEND one
immutable record to THIS process's shard ; find/all = read the consolidated Log.
This is a GENUINELY different backend shape — append-not-upsert. record_event_append
reverts to dispatching the bluebook `EventSourcing::Event.Append` ; the AppendLog
adapter turns that save into a shard append. The byte-IO is the adapter's kernel
leaf (a primitive).
PROJECTION DEPTH : a NEW `Backend::AppendLog` variant in LazyRepository
(persistence_resolution.rs match arm "AppendLog" => ...), with append save +
log-read find. Non-trivial : the persistence family's reply/save contract is
upsert-shaped ; AppendLog bends it to append. This is the deep part.

### 2. Event.Merge / Log consolidation — a command + a primitive + a Driver
BOUNDARY DECISION (the real conception question) : the merge (fold per-process
shards → global Log) is the AppendLog adapter's CONSOLIDATION half. Two honest
modelings :
  (a) Adapter-internal : merge is the AppendLog adapter's scheduled compaction,
      declared as a `driving on interval` in event_sourcing.hecksagon firing a
      maintenance command. Keeps merge OUT of the Event domain (Append stays the
      only domain writer — honoring the bluebook's "no mutating command").
  (b) Domain command : a `Log.Consolidate` (new tiny aggregate) or Snapshot-style
      command. More explicit, but adds a maintenance aggregate.
LEAN : (a). The Log is append-only at the DOMAIN level ; consolidation is an
ADAPTER operational concern, fired by a Driver, executed by the merge primitive.
The driver :
  Hecks.hecksagon "EventSourcing" do
    EventSourcing::Event.persisted_by("AppendLog")
    adapter "LogConsolidation" do
      driving on interval "5s" do |clock|
        dispatch "EventSourcing::Event.Consolidate"   # routes to the merge primitive
      end
    end
  end
The merge logic = a registered PRIMITIVE (primitive_registry, like Process.Spawn).
The Consolidate command routes to it. `storehouse drive` (built this session)
fires the driver — so run_merge (the hand-written daemon) is DELETED.
PROJECTION DEPTH : command→primitive routing (how Consolidate invokes the merge
primitive) + drive firing it. The primitive itself is event_merge.rs (already
written + tested).

### 3. ShardRecord → derive from Event
The shard line should be the Event aggregate's serialization, not a hand-kept
13-field struct. PROJECTION : the AppendLog adapter serializes the Event being
saved (its attributes ARE the shard fields). Removes the duplication.

### 4. The Drivers → Procfile projection (i262)
Both the merge driver (above) and any drive daemon become `driving on interval`
declarations. The Procfile merge/drive members are the PROJECTION of those
(the i262 hand-derived-Procfile gap). Until i262's projector lands, the Procfile
stays hand-derived from the declarations.

## KERNEL RESIDUE AFTER THE REFACTOR
From ~690 lines of bespoke Rust (shard+merge+drive+rewire) down to :
  - 2 primitives (shard byte-IO ; merge fold) in the primitive_registry — the
    sanctioned kernel-leaf index, antibody-exempt BY DESIGN.
  - the Backend::AppendLog save/find shim (append + log-read).
  - run_drive's timer loop + ~10 lines of tick math (drive_scheduler).
Everything else — the Event shape, the persistence binding, the consolidation
command, the driver wiring — becomes DECLARATION.

## PROJECTION PLAN (the focused arc ; fresh head, gated worktree)
1. Register shard-IO + merge as primitives (primitive_registry). Re-point
   event_shard / event_merge callers at the registry. COMPLETE + FUNCTIONING.
2. Backend::AppendLog : new LazyRepository backend (append save, log-read find).
   Add the "AppendLog" => arm. Bind Event.persisted_by("AppendLog"). Revert
   record_event_append to dispatch Event.Append. Verify 30/30 still holds.
3. Event.Consolidate command + driver + drive-fires-it. DELETE run_merge.
4. ShardRecord -> Event serialization. Remove the duplication.
5. Gate flip + Procfile driver members + restart (the go-live, slice 3b).
EACH step must be COMPLETE + FUNCTIONING before commit — never a declared-but-
ignored bind (written-but-not-functioning). Steps 2-3 are the deep runtime work
parity cannot verify ; that is why this is conceived first, projected with care.

## CURRENT STATE (safe)
The proven imperative version (slices 1-3a) is on main, GATED OFF
(HECKS_EVENT_SOURCING unset) — nothing live writes shards yet. This conception
is the bluebook-first rewrite of that proven design. No regression risk : the
refactor REPLACES the gated-off imperative path, which is currently inert.
