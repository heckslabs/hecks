# A policy reads the emitting record's identity as `:id`

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27.

## Context

A policy's `with:` says what its trigger is given: a Symbol names a field the policy can see,
anything else is a literal. For a plain trigger the visible fields are the event's payload and
the emitting record's identity, offered under the aggregate's identity heads, with the payload
winning any name it shares. A fan-out policy also sees its row, and reads that row's own `id`.

A plain trigger had no way to name the emitting record's identity as a whole. An aggregate with
a two-field identity, such as a box's branch and number, offers each head the same whole
identity string, and the payload shadows them, since the event carries both fields. So a policy
could not hand a downstream context "the thing that happened", only its fields one by one.

That blocked a generic Compliance `Review` (ADR 0143). Compliance cannot name each consumer's
fields, and the policy language has no way to join two of them. Reading `:id` unblocks it.

## Decision

1. **`:id` is readable in a policy's `with:`.** It is the emitting record's whole identity, a
   composite one joined by a colon, as the event carries it (`BR1:42`).
2. **It sits below everything else.** A fan-out row's own `id` wins it, and so does a payload
   field named `id`. An existing fan-out that reads `:id` reads the same value it did.
3. **The build-time check admits `:id`** for a policy, beside the emitter's identity heads. A
   saga leg's source is unchanged: it merges no emitter identity.
4. **Both runtimes do the same.** `PolicyInterpreter` offers it in Ruby and `trigger_args_with_row`
   in the kernel offers it in Rust, each with a test for the three precedence cases.
5. **A cross-domain policy's `with:` is applied in Rust.** Using `:id` for Compliance's `Review`
   exposed a gap that was already there: the kernel's `CrossDomainPolicyRule` carried no
   `with_spec`, so the host delivered an `across` policy's payload unchanged and ignored its
   projection, while Ruby applied it. Nothing had combined `across` with `with:` before. The rule
   now carries `with_spec`, the generator emits it, and the kernel delivers the projection of the
   payload and the emitter's identity (not sliced to the target's attributes, which live in the
   other domain). A policy with no `with:` still delivers the payload unchanged.
6. **An unloaded target domain refuses the same way with or without `with:`.** Ruby's explicit
   projection resolved its target first and refused with its own wording
   ("does not resolve to an aggregate") where the dispatcher says `no domain "X" loaded`. The
   explicit path now uses the shared `no_domain` template, so the recorded refusals agree.

## Alternatives considered

- **A new word, such as `:subject`.** It would not collide with a payload or row field. Rejected:
  `id` is already the name a fan-out row's identity goes by, so a second name for the same idea
  would be two ways to say it (ADR 0025).
- **Let `with:` compute a join of two fields.** More general, and a new expression form in both
  runtimes. Not needed for this: the identity is already the join.
- **Always offer `:id`, above the row's.** It would change what an existing fan-out reads.

## Consequences

- A policy can map any event to a downstream context's key in one word, which is what lets a
  supplier name no consumer.
- A payload that carries a field called `id` hides the record's identity from `:id`. That is
  the rule for every other shared name, so it is consistent, and it is documented on the policy
  reference page.
- The conformance corpus does not yet hold a fixture for `:id` across the two runtimes. The
  unit tests in each pin the precedence; a corpus fixture would pin the agreement. Re-verifying
  against a Rust build of the generated host was not done here.
