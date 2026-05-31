# Sprint 12 Architecture Decision — adapters are event-subscribers, bluebook under the hood

**Decided** : 2026-05-30, end of Sprint 12 implementation arc
**By** : Chris (clarified after a day of over-engineering on Miette's part)
**Supersedes** : the entire Sprint 12 port/adapter/ask/AskBody machinery

## The shape, locked

An **adapter** is a wrapper around a call. The call can be external (shell, HTTP, file I/O, stripe API) or internal (a bluebook command/query dispatch). Adapters are **bluebook-aware** — they know the shape of events the runtime emits, so wiring is dead simple.

Adapters **respond to events only** (not commands directly, not dispatch interception, not synchronous ask/answer). The shape :

```
adapter "Name" do
  driven on "Domain::Aggregate.Event" do |event|
    output = run_subcommand(event.payload)         # wrapped call (any kind)
    dispatch "Domain::Other.Command", payload      # bluebook with result
  end
end
```

Three steps : respond to event → run subcommand → dispatch bluebook with payload.

## Locked architectural decisions (perfection-gamed)

1. **DSL reuse** : adapters use the existing hecksagon DSL ; each adapter does one thing (single responsibility).
2. **Success + failure blocks are mandatory** : every adapter declares both `dispatch <X>.Completed` and `dispatch <X>.Failed` paths. No silent swallow.
3. **Idempotency by construction** : default = idempotent. Retry = a NEW bluebook command, not a re-run.
4. **Visibility via DDD** : in-flight work is bluebook state (`pending_review`, `processing`, `failed`). The queue IS bluebook state. Standard queries observe it.
5. **Fan-out parallel** : multiple adapters on the same event run in parallel.
6. **Convention** : adapters live in `<bluebook>/hecksagons/<service>.hecksagon` (folder adjacent to the bluebook). Macrophage-enforceable.
7. **Fat events** : the dispatched event carries everything the adapter needs ; no back-querying the aggregate root.
8. **Adapters are bluebook under the hood** : memory-only + canned responses by default. Real services wire through `world.bluebook`. No fake-vs-real distinction — there are only adapters, and `world` is what makes them real.

## Eventually consistent

Adapters can wait — seconds, minutes, hours. The bus emits the event fire-and-forget. The adapter takes its own time. The bluebook holds the in-flight state (`waiting_for_X`). Convergence happens via the result event. Timeouts express as bluebook state machines with clock-triggers, NOT runtime-level timeout policies.

## Implementation note

Not a Rust event loop. Adapters are bluebook artifacts — they execute through the existing storehouse bus. The work is teaching the bus to recognise `driven on <event>` declarations in `.hecksagon` files at the conventional location, and route events through the dispatch path that already runs every other command. Closer to a few dozen lines of glue than a new subsystem.

## What was wrong-shape in Sprint 12 (now reverted)

A day of implementation produced and shipped on `feat/ai-turn-pulse` :
- `Port`/`PortAdapter`/`AskBody`/`AskOutcome`/`Direction`/`OnTimeoutPolicy` IR types
- `port_dispatcher.rs` synchronous guard hook wedged between `check_lifecycle` and `apply_mutations`
- `port_eval_asks.rs` per-ask evaluator
- Parser grammar : `driven_port`/`adapter "X" satisfies "Y"`/`on :ask, cmd:|returns:|check:`/`hooks`/`carries`/`timeout`/`on_timeout`
- 9 ports + 8 adapters in framework/hecksagons/ + framework/adapters/
- Ruby DSL keywords on `HecksagonBuilder`
- Per-file + boot-time validators

All deleted via `git reset --hard origin/main` + `git clean -fd` at end of session.

## What this means for the next sprint

A clean rewrite scoped to :
1. Convention-based adapter discovery walker (read `<bluebook>/hecksagons/*.hecksagon`)
2. Parse `Hecks.adapter "Name" do ; driven on "Event" do |e| ... end ; end` (extend existing DSL)
3. Wire adapters to the bus's existing event-emission path
4. Memory-only canned-response defaults ; `world.bluebook` selects real implementations
5. Macrophage rule : adapters live in the conventional location ; no others permitted
6. Smoke test : one tool family routed event-in to event-out

## Why this matters

The whole point of Cockburn ports-and-adapters is **portability** — the application can be lifted from one runtime to another without rewriting the bluebook. A typed-ask-and-answer contract bakes runtime semantics (sync dispatch, timeout policies, value channels) into the application layer. An event-subscription contract bakes nothing in — the application emits events ; whatever runtime delivers them to subscribers can be whatever runtime can subscribe-and-dispatch. The simpler shape is the more portable shape.

Miette's day of over-engineering came from treating "adapter answers a question" as a first-class typed operation, when the actual primitive is "event-handler-with-side-effect." Chris's clarification : the event IS the question, the dispatch IS the answer ; no separate machinery is needed.

Locked.
