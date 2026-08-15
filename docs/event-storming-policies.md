# Event storming's Policy, in hecksagain

> The consumer guide for policies and process managers now lives at
> [guides/policies-and-process-managers.md](guides/policies-and-process-managers.md);
> this file remains the original investigation record.

**Status: mostly a record of what's already built, verified directly.** Event
storming's reactive building block — the lilac sticky, "whenever this event happens,
trigger this command" — already exists in this language under the name `Policy`, and
has since before this document. This records what it actually is, corrects a couple
of wrong guesses made while investigating it, and names the one real gap.

## The mapping, and what's already built for each

| Event storming sticky | hecksagain construct |
|---|---|
| Command (blue) | `command` |
| Aggregate (yellow) | `aggregate` |
| Domain Event (orange) | `emits` |
| **Policy (lilac)** | **`Policy`** — `reaction.bluebook`, `runtime/policy_interpreter.rb` |
| Actor/Role | `role` (currently descriptive only — see the Rails integration doc's open questions; zero references anywhere in `lib/hecksagain/runtime`) |
| Long-running Process | `ProcessManager` — same file, `runtime/saga_interpreter.rb` |
| Read Model (green) | `read_model` |
| External System (pink) | **not modeled — the one real gap, see below** |

`Policy` is declared as part of the language's own self-description
(`lib/hecksagain/language/bluebook/reaction.bluebook`), the same way every other
construct in this language is. Its DSL surface is exactly three methods
(`PolicyBuilder`):

```ruby
policy "FreezeAccountsOnSuspension" do
  on      "CustomerSuspended"
  trigger Account::FreezeAccount
end

policy "NotifyOnClosure" do
  on      "AccountClosed"
  trigger Notifications::Send
  across  "Notifications"
end
```

`on` names the event; `trigger` names the command it fires (qualified with
`Domain.Command` when the target lives elsewhere); `across` only appears when the
trigger reaches a genuinely different domain. Both examples above are real, live
usage from `examples/banking/bluebook/banking.bluebook`.

`PolicyInterpreter#react` runs after a command's events are emitted: it finds every
policy watching that event, dispatches the trigger via `@door.reenter`, and records
the outcome in `registry.reaction_log` — `delivered: true` on success. A refusal from
the target (`GivenNotMet`, `InvariantViolation`, etc. — anything in
`DOMAIN_REFUSALS`) is caught and recorded as `delivered: false, reason: ...`, not
raised — the domain saying no is a fact, not a crash. Anything *outside* that list (a
real defect — `NoMethodError`, a missing constant) is deliberately allowed to fly,
specifically so a broken runtime can never be mistaken for a policy simply declining.

`ProcessManager`/`Handler`/`Dispatch` (same file, `SagaInterpreter`) cover event
storming's other reactive construct — a long-running process with real state
(`states`, `correlates_by`, `starts_on`/`ends_on`), multiple legs, and — found while
tracing it — a real compensating-leg mechanism: a saga leg that refuses `unwind`s to
the leg declared `on :refused`, so a partially-applied wire transfer's debit gets
reversed rather than left standing with no credit and no reversal. That `REFUSED`
trigger is specific to the saga's *own* internal refusal (a leg it dispatched came
back declined) — it is not a channel for an external system's response. Worth being
precise about this because it was guessed wrong once while investigating: the comment
mentioning a "Trigger vocabulary... when the leg answers something no aggregate
announces" is about compensation, not about adapters.

## Where a policy is written doesn't matter — only what `on` says

A policy declared inside an `aggregate` block and one declared at the bluebook's top
level behave *identically* at runtime. `IR::Policy#event_qualifier` comes from parsing
the `on` string itself (`Naming.qualifier`) — `"Account.AccountFrozen"` matches only
Account's own emission; a bare `"CustomerSuspended"` matches that event name from any
aggregate. The `aggregate` field on `IR::Policy` — which head a policy happened to be
*written* under — is hoisted to the chapter by the builder either way, excluded from
`to_h` (never crosses the wire, never read by the interpreter), and exists purely as a
fact about the source for anyone reading the file. Writing a policy at the top level
to signal "this belongs to no single aggregate" is a legitimate stylistic choice — it
just isn't a behavioral one.

## "Post validation" — what the phrase actually resolves to

A policy fires *after* an event, which is already a committed fact — there's no
"reject the event" path, the transaction that produced it already succeeded. What a
policy validates is the *consequence*: does this fact, now that it's true, still leave
the world in a state some other rule cares about. That's answered by the triggered
command's own ordinary `given`/invariants running against real, current state — not
by anything declared on `Policy` itself, which carries no condition of its own.

Neither Evans nor "post validation" as a named pattern turned out to be quite the
right citation, worth recording precisely rather than left as a loose gesture:

- Evans's 2003 book has no Domain Events or Policy as named building blocks — those
  came later, largely through his own post-2003 writing and Vernon's *Implementing
  DDD*, specifically to handle a consequence of a rule Evans *does* state: one
  transaction, one aggregate. Anything spanning two aggregates has to become
  eventually consistent — reacting to a fact, because synchronous cross-aggregate
  validation is exactly what the rule forbids. That's the real DDD justification for
  why a policy has to exist at all.
- "Policy" as the sticky-note name and shape is Alberto Brandolini's, from Event
  Storming — not Evans's term.
- Meyer's Design by Contract *postconditions* are the closer technical analogue to the
  phrase "post validation" — and, found later while tracing `given`, this language
  actually has a real declared postcondition construct already: `ensures`, evaluated
  after mutations settle, with `old` bound to pre-mutation state. That's the honest,
  already-built answer to "how do I assert something about the far side of an effect"
  — separate from, and not to be confused with, what `Policy` does.

## Who's allowed to call a policy's trigger — resolved via Cockburn/hexagonal reading

A worked example (a Stripe-style external charge, resolved earlier via ports-and-adapters
reasoning) settled a question worth recording as policy for this construct generally:
the domain doesn't need to know, and shouldn't be told, whether a reentry into a
command came from a policy reacting to a domain event, a saga leg, a Rails controller,
or a webhook handler responding to an external system. All of them are driving
adapters calling in through the same `door.reenter`; Cockburn's hexagonal architecture
states this as the explicit goal ("blissfully ignorant of the nature of the input
device"), and Evans's Layered Architecture makes the same cut from the DDD side —
infrastructure mechanics stay out of the domain layer; only the resulting fact
crosses in, as an ordinary command call. Nothing about `PolicyInterpreter` needs to
change to support an adapter-driven policy target — it would dispatch exactly the way
it already does today.

## Idempotency: two separate layers, neither replacing the other

Also resolved via the Stripe example, general enough to record here: a policy or
adapter-driven reentry can be called more than once (redelivery, a retried job, a
race). Two different things have to be true, and they're not the same fact:

- **The adapter dedupes the delivery** — keyed on whatever the external system's own
  message ID is, entirely private bookkeeping the domain never needs to know exists.
  This is Cockburn's boundary directly: transport-layer hygiene stays in the adapter.
- **The target command still needs its own guard against re-applying a terminal
  transition** — an ordinary `given` (`given("still pending") { status == "pending" }`),
  because the aggregate shouldn't trust that whatever called it deduplicated
  correctly. This is the same category as `AlreadyExists` — a domain protecting its
  own consistency regardless of the caller's behavior.

No new declared "idempotent" property is needed for this. A flag would just be
metadata describing a guard that's already doing the real work — the `given` already
*is* the declaration, in the same uniform mechanism as every other rule in this
language.

## The one real gap: no External System concept

`Policy#target_domain` only ever names another bluebook domain. There is no way to
declare that a policy's effect reaches *past* the runtime boundary — an email, a
webhook call, a third-party API — as a checkable, visible fact the way `across`
already lets a policy declare it's reaching a different domain. This is genuinely
missing, not solved by anything above; everything above is about how an *inbound*
adapter-driven call is treated, not how a policy *declares an outbound* one. If this
gets built, the earlier reasoning still applies directly: the declared *effect*
belongs in the language (a named fact, checkable, visible in the source); the
mechanics of actually reaching the external system belong entirely in an adapter, and
the domain should stay exactly as ignorant of them as it already is of everything
else on the other side of a port.

## A small, pre-existing naming seam, not introduced here

The file is `reaction.bluebook`, the emitted event on declaration is
`ReactionDeclared`, but the aggregate, the interpreter, and every reader-facing name
says `policy`. Worth knowing before building on top of it — not urgent, not something
this document is proposing to fix, just a fact about the source worth having on
record.
