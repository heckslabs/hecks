# The host protocol is line-framed JSON with sessions and callbacks

**Status:** Proposed. Step 4 of the plan in ADR 0188. The first slice is built: `hello`, sessions,
dispatch with events, and one callback. Date: 2026-11-05.

## Context

ADR 0188 makes the Rust kernel the one thing that runs bluebooks and Ruby its front end. Ruby then
needs a way to reach the kernel that is not "boot a second runtime". The kernel already has one:
`rust --serve` reads one JSON step per line, keeps its store between lines, and answers one JSON line
each. The bench client (`lib/hecks/bench/rust_runner.rb`) is its only caller.

It is not yet a protocol. It has one anonymous session, no way to tell a client which version it
speaks, and no way for a dispatch to ask the host for anything. The kernel does no I/O (ADR 0012), so
a fact only the host knows (a clock reading it does not own, a value a Ruby adapter holds, an answer
a policy asks a person for) has to come from outside, and today the host must supply every such fact
before the dispatch starts.

## Decision

The host protocol is the `--serve` stream, given four things.

1. **Framing.** One JSON object per line in each direction, UTF-8, `\n` ended. Nothing else is on
   the stream. The kernel flushes after every line.
2. **Version.** A connection may open with `{"hello": {"protocols": [1], "callbacks": true,
   "needs": {...}, "query_needs": {...}, "defaults": {...}}}`. The kernel answers the highest
   version both ends speak, `{"ok": true, "protocol": 1, "features": ["sessions", "callbacks"]}`, or
   refuses with `ok: false` and the versions each side speaks. A client that sends no `hello` is
   taken to speak version 1 with no callbacks, so the bench client and every existing caller work
   unchanged. `needs`, `query_needs` and `defaults` are the tables the host builds from the domain's
   IR (`KernelInput`); a later `hello` replaces them.
3. **Sessions.** `{"open": "name"}` makes a session with its own store, sagas and logs;
   `{"close": "name"}` drops it. A step carries an optional `"session"`; with none it runs in the
   connection's default session, which cannot be closed. A step naming a session that is not open is
   refused.
4. **Callbacks.** When `hello` offered `callbacks`, the kernel may write, in the middle of a
   dispatch, `{"callback": {"id": 1, "ask": "fact", "fact": "amount", "type": "ToppingAmount",
   "verb": "Pizzas::Order.AddTopping"}}` and read the next line, `{"id": 1, "answer": <value>}`,
   before it goes on. A null answer, a missing one, an answer for another id or a closed stream leaves
   the fact out, exactly as with no callback, and the command is refused if it needed the fact. The
   host answers a callback before it sends anything else. The kernel asks only for a fact the
   command's `needs` names and the caller left out; a supplied value is never asked for.

Every answer is `{"ok": true, ...}` or `{"ok": false, "error": "<message>"}` (ADR 0186). A dispatch
answers its events as `{"ok": true, "events": [...]}`.

### Which parts are declared and which are code

- **The vocabulary is a bluebook, and it is the next slice, not this one.** The messages are domain
  facts: a connection, a session, a hello, a callback and its answer. They belong in a declared
  domain so that the Ruby client, the kernel loop and any other client (Rails, MCP, hecks-client)
  are projected from one place and cannot drift. This record fixes the shapes; the bluebook that
  declares them is a follow-up, and until it lands the shapes live in `rust/src/kernel/serve.rs` and
  `lib/hecks/rust_build/kernel_client.rb`, which a conformance spec holds to each other.
- **The loop is kernel code.** Reading a line, writing a line and holding the sessions are the one
  place the kernel's crate touches a stream (`rust/src/kernel/serve.rs`), as `cli.rs` already did.
  The evaluation underneath still takes only a callback (`needs::Asker`), so ADR 0012 holds: the
  kernel proper does no I/O.
- **The Ruby client is an adapter.** `Hecks::RustBuild::KernelClient` runs the binary and answers
  callbacks from a block; what answers them (a clock, an adapter, a person) is the caller's.

## Consequences

- Ruby can drive the kernel without a second runtime, and one process serves many sessions.
- A fact the host owns no longer has to be known before the dispatch; the kernel asks for it when a
  command needs it.
- Callbacks are synchronous: a dispatch waits for the host. A slow answer holds the connection, so a
  host that cannot answer quickly should refuse or answer null.
- A dispatch that asked a callback is not replayable from its journal alone, because the answer came
  from outside. The host must journal the answer with the step (as it journals `occurred_at`).
  Journaling is not part of this slice.
- Not built: events streamed ahead of a dispatch's answer, a callback for anything but a fact (an
  `Asking` policy, a Ruby adapter call), the declared vocabulary, a Wasm transport, and a second
  connection to a shared store.

## Rejected alternatives

- **A new transport (HTTP, a socket).** The stream already exists, needs no port, and the same
  framing runs over a socket or a Wasm host's stdio later.
- **Facts supplied up front only.** That is today's behavior; it forces the host to guess which
  facts a dispatch will need, including those behind a policy it has not run yet.
- **A binary framing.** It would save little against a JSON parse the kernel already pays, and lose
  the ability to read the stream by eye.
