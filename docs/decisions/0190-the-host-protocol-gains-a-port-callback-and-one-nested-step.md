# The host protocol gains a read-only port callback

**Status:** Proposed. Amends ADR 0189 (callbacks). Slice 6 of `docs/plans/kernel-thin-client.md`,
decision A. Nothing here is built. Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

ADR 0189 gave the host protocol one callback kind, `ask: "fact"`. The kernel does no I/O (ADR 0012), so
once Ruby is a client every Ruby adapter call during a policy or a port operation can only be a callback,
and the protocol has no kind for it.

Four readers answer a port today (**R**, named in the plan): `bulk/row_sweeper.rb`,
`quality_control/adapters/run_reader.rb`, `push_due_reader.rb` and `hecks/adapters/git_rehearsal/due.rb`.
`Runtime::Asking` binds the asking registry on the thread for the length of the ask (**R**,
`lib/hecks/runtime/asking.rb`, ADR 0125), so an adapter that dispatches reaches the same boot. A nested
dispatch from a callback would make the kernel wait for the answer while the adapter waits for the kernel
(**I**: not run; it is derived from the ADR 0189 text, and it is not needed for the decision below).

## Decision

1. **One new callback kind, `ask: "port"`, read-only.** While a dispatch runs, the kernel may write
   `{"callback": {"id": 2, "ask": "port", "domain": "...", "aggregate": "...", "operation": "...",
   "args": {...}, "verb": "..."}}`. The host answers `{"id": 2, "answer": <value>}`, or
   `{"id": 2, "refused": "<message>"}` when the adapter refuses; the refusal is the port's refusal (the
   `refuses` the domain declared) and the command is refused with it, as ADR 0186 words it. A `hello`
   lists the kinds it can answer (`"asks": ["fact", "port"]`); a client that sends none is taken to answer
   `fact` only, so every existing caller works unchanged. The answer is journaled with the step, as
   ADR 0189 requires of every callback answer.
2. **An adapter answers with data and never dispatches.** The answer carries what was read. Any follow-up
   command is a policy on that returned data, so the kernel dispatches it from the declaration. ADR 0189's
   rule stands unchanged: the host answers a callback before it sends anything else. There is no nested
   step, and `serve.rs` needs no re-entrancy.
3. **`row_sweeper` returns the rows it found.** It stops dispatching from inside the adapter; the follow-up
   it decided at run time becomes a policy on its answer. The other three readers already only read.
4. **Which mechanism answers a port.** One mechanism per port, never both:
   - When the port's `.adapter` declares a Wasm component (`runs`, ADR 0192), the host loads that
     component and answers; the Ruby client is not asked.
   - Otherwise the Ruby client answers through its callback, one registered adapter per port.
   - A port with neither refuses by name (`no adapter answers port <name>`). This is the route 0192's
     `runs` word selects; this record owns the Ruby side of it.
5. **Until the kernel and the client build this, the client refuses by name.** A dispatch from inside a
   Ruby adapter call raises `nested dispatch from a port callback is not built` rather than hanging. The
   refusal is removed by the slice that builds this ADR, not before (**I**: the client does not exist yet).

### Which parts are declared and which are code

Bluebook first.

- **Bluebook.** A port operation a domain asks for is already declared: `asks`, `answers`, `refuses` (see
  `tickets.ports.hecksagon`). That is the whole domain-side statement. The message kinds (a port callback,
  its answer, its refusal) are connection vocabulary and have no bluebook owner yet: ADR 0189 said the
  connection should be declared, and that bluebook does not exist. **The callback, answer and refusal are
  added to the connection bluebook before the kernel or client code lands**, so the Ruby client, the
  kernel loop and other clients are projected from one place.
- **Hecksagon.** Which adapter answers a port is wiring (decision 4) and is unchanged in shape; `runs` is
  ADR 0192's word.
- **Adapter code.** The kernel loop (`rust/src/kernel/serve.rs`), the Ruby client
  (`lib/hecks/rust_build/kernel_client.rb`) and the Ruby adapters behind the ports are imperative code
  outside the bluebook world, because the kernel owns no I/O and something that does has to answer.

## Consequences

- The four readers answer from Ruby, through `Asking.with(registry)`, after `row_sweeper` is changed to
  return data.
- Each port callback is a pipe round trip plus JSON each way. A policy chain that asks per step can lose
  the speed margin; the gate in the plan prices a verb with one port callback as its own workload.
- A dispatch that used a port callback is not replayable from its journal alone; the journaled answer is
  what makes it so (ADR 0189).
- The protocol stays simple: one callback open at a time, no depth rule, no change to the kernel's session
  borrow.
- Not built: all of it. This record fixes the shape so slice 6 starts from an accepted text.

## Rejected alternatives

- **One nested step for a dispatching adapter.** Needs a real change to `rust/src/kernel/serve.rs` (**I**:
  whether it holds the `Session` mutably during `handle` was not read), amends ADR 0189 for one named
  caller, and that caller can return data instead.
- **Unbounded nesting.** Reaches deadlock and unbounded stack through the pipe for no case found.
- **A second connection to the same store (ADR 0189 "not built").** Needs state shared between two
  connections, which the in-memory store does not have.
