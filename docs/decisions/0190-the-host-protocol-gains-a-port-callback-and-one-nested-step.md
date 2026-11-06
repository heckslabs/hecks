# The host protocol gains a port callback and one nested step

**Status:** Proposed. Amends ADR 0189 (callbacks, and its rule that the host answers a callback before
it sends anything else). Slice 6 of `docs/plans/kernel-thin-client.md`, decision A. Nothing here is
built. Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

ADR 0189 gave the host protocol one callback kind, `ask: "fact"`, and said the host "answers a callback
before it sends anything else". That text forbids a nested dispatch.

Some Ruby adapters need one. A port operation is called by the interpreter, and `Runtime::Asking` binds
the asking registry on the thread for the length of the ask so an adapter that answers by dispatching
reaches the same boot (**R**, `lib/hecks/runtime/asking.rb`, ADR 0125). Four readers use it (**R**, named
in the plan): `bulk/row_sweeper.rb`, `quality_control/adapters/run_reader.rb`, `push_due_reader.rb` and
`hecks/adapters/git_rehearsal/due.rb`. The kernel does no I/O (ADR 0012), so once Ruby is a client every
Ruby adapter call during a policy or a port operation can only be a callback. The protocol has no kind
for it, and a nested dispatch inside one would hang: the kernel waits for the answer while the adapter
waits for the kernel (**I**: not run, derived from the 0189 text and from the kernel holding the session
for the length of a step).

## Decision

1. **A callback kind `ask: "port"`.** While a dispatch runs, the kernel may write
   `{"callback": {"id": 2, "ask": "port", "domain": "...", "aggregate": "...", "operation": "...",
   "args": {...}, "verb": "..."}}`. The host answers `{"id": 2, "answer": <value>}`, or
   `{"id": 2, "refused": "<message>"}` when the adapter refuses; the refusal is the port's refusal
   (the `refuses` the domain declared) and the command is refused with it, as ADR 0186 words it. A
   `hello` lists the kinds it can answer (`"asks": ["fact", "port"]`); a client that sends none is taken
   to answer `fact` only, so every existing caller works unchanged. The answer is journaled with the
   step, as ADR 0189 requires of every callback answer.
2. **Nested dispatch has two cases.**
   - **A read-only adapter returns data.** The answer carries what was read, and the kernel dispatches
     any follow-up itself, from the policy or port declaration. Most readers are this case.
   - **A dispatching adapter gets one nested step.** While a callback is open the host may send exactly
     one step in the same session before it sends the callback's answer. The kernel runs it, answers it
     with its own events line, and then reads the callback answer. That amends ADR 0189's "answers a
     callback before it sends anything else" to "…except one nested step". `row_sweeper` is the case
     that needs it.
   - **Depth is one.** A nested step that raises a callback of its own, or a second step while one is
     nested, is refused by name (`nested dispatch is one step deep`). A step sent with no callback open is
     an ordinary step and is not nested.
3. **Until the kernel and the client build this, the client refuses by name.** `Asking.with(registry)` is
   bound by the client around each Ruby adapter call (**I**: the client does not exist yet); a dispatch
   from inside it raises `nested dispatch from a port callback is not built` instead of hanging. The
   refusal is removed by the slice that builds this ADR, not before.
4. **The kernel must be re-entrant on the session for the one nested step.** The plan states the kernel
   holds a `Session` mutably during `handle` (**I**: taken from the plan; `serve.rs` was read for its
   functions and tests, not for this borrow). If so, this is a real change to `rust/src/kernel/serve.rs`,
   not a protocol detail, and it is where the build starts.

### Which parts are declared and which are code

Bluebook first.

- **Bluebook.** A port operation a domain asks for is already declared: `asks`, `answers`, `refuses` (see
  `tickets.ports.hecksagon`). That is the whole domain-side statement. This record adds none. The
  message kinds above (a port callback, its answer, its refusal) join the connection vocabulary ADR 0189
  said should be a declared bluebook; they are written there when that bluebook lands, so the Ruby client,
  the kernel loop and other clients are projected from one place.
- **Hecksagon.** Which adapter answers a port is wiring and is unchanged. Whether an adapter dispatches is
  not declared today; if the one-step rule needs it said, that is a hecksagon word, to be settled in the
  build, not added here.
- **Adapter code.** The kernel loop (`rust/src/kernel/serve.rs`), the Ruby client
  (`lib/hecks/rust_build/kernel_client.rb`) and the Ruby adapters behind the ports are imperative code
  outside the bluebook world. The reason is the one ADR 0189 gives: the kernel owns no I/O, so something
  that does has to answer.

## Consequences

- The four readers and the git and deploy adapters can answer from Ruby unchanged, through
  `Asking.with(registry)`.
- Each port callback is a pipe round trip plus JSON each way. A policy chain that asks per step can lose
  the speed margin; the gate in the plan prices a verb with one port callback and a nested dispatch as
  its own workloads.
- A dispatch that used a port callback is not replayable from its journal alone; the journaled answer is
  what makes it so (ADR 0189).
- Adapters that only read need no nested step at all, which keeps the one-step rule to the few that
  dispatch.
- Not built: all of it. This record fixes the shape so slice 6 starts from an accepted text.

## Rejected alternatives

- **A second connection to the same store (ADR 0189 "not built").** Cleaner, but needs state shared
  between two connections, which the in-memory store does not have.
- **Forbid nested dispatch outright and change every adapter.** Forces `row_sweeper` and its kind to
  return data for a follow-up they decide on at run time, which moves their logic into the kernel.
- **Unbounded nesting.** Reaches deadlock and unbounded stack through the pipe for no case found.
