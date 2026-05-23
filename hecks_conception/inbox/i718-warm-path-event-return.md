# i718 — warm-path event-return

The warm socket reply omits the cascade event log. Events fire correctly (they reach
the daemon's stdout) but the RESULT envelope returned to the caller contains only the
command output — the event list is empty. Every warm dispatch therefore looks like it
"has no events" even when policies fired and state mutated.

## The gap

`run_serve` in the Rust daemon writes events to its own stdout (or a side channel)
after each dispatch, but the JSON blob it sends back over the socket does not include
the `events` array. The MCP layer reads that blob, finds `events: []`, and reports
"dispatch did not start" (see i719 for that rendering lie).

## Fix direction

Return / stream events in the RESULT envelope. Options :

1. **Inline** — append `"events": [...]` to the response JSON before closing the
   socket write. Simplest ; works for synchronous commands.
2. **Stream** — send one JSON line per event as they fire, then a final `{"done":true}`
   sentinel. Lets the caller render events as they arrive ; better for long-running
   commands.

Either way, the contract is : every warm dispatch response that reaches the MCP layer
must include the event log so `dispatch_render` can surface it.

## Payoff

Bus dispatches via warm path will show their events in the assistant turn, same as
cold dispatches. Warm path becomes fully transparent instead of appearing silent.
