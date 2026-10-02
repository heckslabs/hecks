# Commands declare the outside facts they need, and a rule across records gets an aggregate that owns it

**Status:** Partly built (section 1, for `now` on commands; section 2 and port-answered facts are not). Date: 2026-09-28. Builds on item 5 of `docs/HECKS_IMPLEMENTATION_PLAN.md` (identity generation and replay) and stage 2 of its execution pipeline, "Runtime enrichment (UUIDs, clock, caller, external facts)". Unblocks two QualityControl rules in [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md). Ships in a 3.x minor after 3.0: every change here is additive, so it needs no major version. Section 1 is built for `needs :now` on commands, as the first slice (see "What is built"); the rest below is not.

## Context

Business rules that belong in bluebooks still live in adapter code. An audit of the adapters in this repository and in the domains that consume it sorted them three ways:

- **Expressible today, just not moved.** For example: a bug being fixed before its patch opens (`bin/qa_open_pr:120`), release preflight checks (`lib/hecks/release/runner/preflight.rb:53-95`), and settlement guards in a mock ACH adapter (`mock_ach_settlement_adapter.rb:28-32`). These need moving, not new language.
- **Real IO.** `gh` and `git` calls, webhook signature checks, token cryptography. These belong in adapters.
- **Not expressible.** Two kinds of rule account for most of this group.

The first kind needs a fact from outside the aggregate at the moment of the command:

- the time, for link lifetimes, a grant's start, "opened since midnight";
- an answer from a port, for "the fix commit is an ancestor of `HEAD`" (`bin/qa_open_pr:126`), a payment's customer check (the payments bluebook says "the expression sublanguage cannot call a port at all"), or a release tag not already pointing elsewhere (`tagger.rb:22`).

Because the language cannot say "now", the same lifetime has drifted between engines: one domain's unsubscribe links last 365 days in its Ruby host and 730 days in its Rust host.

The second kind is a rule across many records: a seat cap counted over registrations, or a per-day cap counted over opened patches. One consuming domain enforces its seat cap in four places, two host implementations, the site and a status table, and its bluebook says the seat rule "lives in the site's and the host's seat rule, not in this aggregate".

Parts of the machinery already exist:

- The `clock` port with its `SystemClock` adapter (`lib/hecks/adapters/driven/system_clock.adapter`).
- Identity generation (plan item 5). A minted id is baked into the command's recorded arguments, so replay re-dispatches the same arguments and never calls the adapter again. `Event#occurred_at` works the same way.
- What item 5 left undone is "facade-level automatic enrichment": having the runtime fill an argument in, rather than each caller doing it by hand.

## Decision

### 1. A command declares the facts it needs; the runtime supplies them

A command names each outside fact it depends on and the port that answers it. At dispatch, before any `given` runs, the runtime asks the port and writes the answer into the command's arguments. From there it is an ordinary argument: givens read it, and the event records it. Replay re-dispatches the recorded arguments and never asks again, exactly as with minted ids.

A sketch, not settled grammar:

```ruby
command "Open" do
  needs :now                                         # from the clock port
  needs :fix_on_head, from: Git.ancestor?(fix_commit, "HEAD")

  given("the fix is on HEAD") { fix_on_head }
end
```

- **The domain never does IO.** A `given` never calls a port; it reads a value the runtime gathered beforehand. Givens stay pure, and a command's outcome is a function of its recorded arguments.
- **`now` is the common case.** It comes from the `clock` port, so tests bind a fixed clock and both engines read the same declared rule. A lifetime written once in the bluebook, as `issued_at + days(730) > now`, cannot drift between Ruby and Rust.
- **Expressions gain a timestamp type and durations** (`days`, `hours`, comparison, addition), since today they admit only `+` and `.modulo` for arithmetic.
- **A fact the port cannot supply refuses the command** with the port's own message, before any given runs.

### 2. A rule across records gets an aggregate that owns it

There is no `given` that counts records. A rule that must hold across many records says that something owns those records, and that owner becomes an aggregate:

- **Seats.** `Event` (or a `Seating` aggregate) holds `seats_taken`. A registration first takes a seat with `ReserveSeat`, and cancelling one releases it. The cap is an ordinary given on one aggregate.
- **A daily cap.** A `DailyQuota` aggregate, identified by date, from which each `Patch.Open` takes a slot. The date comes from `now` (section 1).

One aggregate saves atomically, so two requests cannot both take the last seat. A count-based given would need the store to run the count inside the save's transaction to get the same guarantee, and it would hide the missing aggregate.

## Consequences

- The seat cap moves from four copies to one given on one aggregate. Consuming domains add the owning aggregate and route registration through it.
- Link lifetimes, grant windows and "since midnight" become declared rules that both engines read, which ends the drift between them.
- ADR 0080's two blocked QualityControl rules become expressible: the per-day PR cap as a `DailyQuota`, and the ancestry check as a declared fact the `GitPr` adapter answers.
- Replay stays deterministic: every outside answer is part of the recorded arguments.
- The Rust host has to run the same enrichment step before its givens, reading the same declarations.

## Alternatives considered

- **Givens that call ports directly.** Rejected: the domain would do IO during validation, and replay would ask the outside world again and could get a different answer.
- **A `count(...)` expression in givens.** Rejected: it races with concurrent saves unless the store counts inside the save's transaction, and it leaves the owning aggregate unnamed.
- **Keep these rules in adapters.** Rejected: they have already drifted between engines and been copied four times.

## What is built

The first slice, `needs :now` on commands, in Ruby and Rust:

- **The word is `needs`.** A command writes `needs :now` and declares the attribute it fills (`attribute :now, Instant`); the builder refuses a fact other than `now`, a repeated one, and a need with no attribute to fill. The Command IR carries `"needs": [{"fact": "now"}]` (an empty list on a command with none).
- **Where it runs.** The interpreter answers a needed fact in the existing `decode_arguments` step, before any argument refusal or `given` reads the arguments, so the dispatch-order vocabulary did not change. The strict `with:` envelope no longer counts a needed fact as absent.
- **A caller's value wins.** The runtime fills a needed fact only when the caller left it out. Nothing in the event marks which it was: the recorded arguments carry the value used, which is all a replay needs.
- **Time is whole epoch seconds, UTC.** `Ports::Clock.now` already answers that. "Since midnight" needs a zone and stays a separate, later fact.
- **Durations fold at canonicalisation.** `days(730)`, `hours(2)` and `minutes(15)`, written on a whole-number literal, become seconds when a predicate is stored (`issued_at + days(730) > now` is `issued_at + 63072000 > now`), by a new `scale_call` normalisation strategy. Both engines read one table of cases (`spec/fixtures/canonical_form_cases.json`). No timestamp type was added.
- **Door fill retired.** The CLI door no longer stamps a `now` argument; QualityControl's six commands and the `lease_clock` stress domain's four declare `needs :now` instead.
- **The Rust runtime.** The host fills a needed fact before the kernel's gates run and before the step is journaled, from the `needs` list in the IR, behind a small clock seam. It also passes the kernel a table of which commands need which facts, so a command a policy or saga triggers is answered the same way. Commands declared on entities are filled by Ruby but not yet by the Rust host or kernel, and a kernel-run binary relies on the host passing the table: generation would have to emit it for the kernel to fill on its own.
- **Not covered.** Queries cannot `needs` yet (the one query with a `now` argument still takes it from its caller). Port-answered facts (`needs :fix_on_head, from: ...`) are not built, and a replay refuses them. The seat and daily-cap aggregates (section 2) are not built.

## Open items

- How a port-answered fact is written in `needs`, and how a replay answers one (the recorded value, or a refusal).
- The timestamp type's resolution and time zone, since "since midnight" needs a zone.
- Whether a query may declare `needs`.
- The smaller gaps the same audit found, each for its own ADR:
  - `sets` that compute a value or clear a field
  - scheduled or deferred commands
  - signed tokens with a purpose and lifetime
  - an idempotent no-op on repeat instead of a refusal
  - nested fields in a policy's `with:`
  - grouped reductions (ADR 0061)
