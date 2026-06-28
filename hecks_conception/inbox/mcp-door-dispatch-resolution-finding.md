# Finding — MCP `storehouse__dispatch` door: result-selection + creation-command gaps (2026-06-28)

Chased from a cosmetic symptom ("`MergeQueue.Retire` showed 0 events in the MCP
render, but behaviors prove it emits") to two real runtime/door bugs. The
domain is CORRECT throughout — these are dispatch-door / runtime issues, all in
EXEMPT runtime territory (`rust/src/server/`, `rust/src/runtime/`), not bluebook
fixes.

## Evidence (storehouse.log, hecks realm)

One `Retire demo-main` dispatch at 08:14:55 was processed by TWO consumers,
same `invocation_id`, same ts :

```
source:"process-manager" … kind:"done" outcome:"error" result:"UnknownCommand('Conductor::MergeQueue.Retire…')"  event_count:2
source:"operator"        … kind:"event" verb:"MergeQueue.…Retired" … kind:"done" outcome:"ok"                    event_count:3
```

The `operator` runtime (fresh parse) DID emit + transition state. A long-lived
`process-manager`/driver daemon (overmind `storehouse loop`/`clock`, booted the
night before the `Retire` edit) re-processed the bus traffic against its STALE
in-memory bluebook parse → `UnknownCommand`. The MCP door surfaced the stale
consumer's empty/error result as "0 events."

## Bug 1 — door surfaces a non-authoritative consumer's result

When multiple consumers handle one dispatch, the MCP door can render a stale
parallel consumer's failure instead of the authoritative `operator` result. The
dispatch SUCCEEDED (state changed, event logged) yet the door reported failure.
The door should surface the authoritative operator dispatch's outcome.

## Bug 2 — door cannot route CREATION commands

`Conductor::MergeQueue.Open` (the minting command — no `reference_to`) returns
`aggregate="" query="Open"` / "dispatch did not start", and NEVER reaches the
runtime (no log entry). Reproduced with `branch=` and with `id=`+`branch=` — the
discriminator is the absence of `reference_to`, not the args. The door resolves
a command by finding an EXISTING instance then dispatching; a creation command
has no instance to find, so it falls back to query interpretation. CLI dispatch
of the same `Open` works fine — so it is the door's command/query classifier,
not the runtime. Creation-via-door is a real hole.

## Contributing condition — stale long-lived daemon parses

Overmind driver daemons hold a bluebook parse fixed at boot. A command added
mid-session is `UnknownCommand` to them until they reboot. Class fix : daemons
hot-reload on bluebook change, OR the door ignores stale consumers' verdicts.
Operational refresh today : `overmind restart` re-parses every loop/clock.

## Also reaped

pid 76438 — `storehouse … ShellTool.Bash … find … -name '*.bluebook'` pinned at
99.8% CPU for 511 min (orphaned zombie, find spinning a core). SIGTERM'd.
Distinct from the `cpu-spin/overfire-singleton-keying` branch already in flight.

## Repro

- `Conductor::MergeQueue.Open {branch: "x"}` via MCP door → `query="Open"`, no dispatch.
- Same via CLI (`storehouse hecks_conception Conductor::MergeQueue.Open branch=x`) → ok, emits MergeQueueOpened.
