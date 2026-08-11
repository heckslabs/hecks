# Policies and process managers

A command answers a synchronous caller directly. Much of what a real
system does is not synchronous — a payment gateway's webhook fires, a
scheduled payment's presentment gets declined at the far end, and
nothing is waiting for a direct answer. Something inside the domain
still has to react, and the reaction is a domain decision, not
infrastructure. `policy` is the seam where a fact that already happened
becomes that decision: not a script, not a callback bolted onto an
event bus, a declared reaction the runtime fires and records the
outcome of, the same way it records everything else. `process_manager`
is the seam for the reaction that cannot finish in one step — money
that has to leave one account before it can arrive at another, with a
real chance of failing partway through.

Both are provable against the real corpus, not a small domain invented
to order. `examples/banking/bluebook/banking.bluebook` already carries
one of each shape this page teaches: a policy that reacts inside its
own domain, one that reaches across into another, one that re-triggers
itself on a bounded retry, and two sagas that coordinate a multi-step
change — one that undoes what it started when the second step refuses,
and one that has nothing to undo because nothing was ever created in
the first place.

## The shape of a reaction

`ScheduledPayment` holds the clearest example of a policy actually
closing a loop — a payment retries its own failed presentment, up to
the limit the schedule names, exactly as it reads in the real file:

```ruby skip
# ScheduledPayment, in examples/banking/bluebook/banking.bluebook
command "Fail" do
  role "System"
  goal "Record that today's presentment could not be collected"

  reference_to ScheduledPayment

  emits "ScheduledPaymentFailed"
end

# SELF-TRIGGERING, ON PURPOSE — the same shape reflex.bluebook's Echo/Ring
# proves MAX_REACTION_DEPTH with, grounded in a real rule instead of an
# unbounded ring: an automated re-presentment against an account still
# short of funds fails for the identical reason, so it re-announces the
# identical event, and `RetryOnPaymentFailure` below re-enters this same
# command. `given` is the REAL bound a bank actually enforces — a
# schedule's own `max_attempts`, ordinarily well inside the runtime's
# five-deep reaction ceiling, which exists as the backstop under
# whatever a caller configures it to, not as this policy's normal exit.
#
# MUTATING, NOT CREATING — same reason Echo.Ring is: the reaction
# re-dispatches this against the SAME record every time it re-enters,
# and a creating command now refuses a second creation over one
# identity (AlreadyExists).
command "Retry" do
  role "System"
  goal "Re-present a failed payment, up to the limit the schedule names"

  reference_to ScheduledPayment

  given("a retry is still allowed") { attempts.value < max_attempts.value }

  then_set :attempts, increment: { value: 1 }

  ensures("a retry never lowers the attempt count") { attempts.value == old.attempts.value + 1 }

  emits "ScheduledPaymentFailed"
end

policy "RetryOnPaymentFailure" do
  on      "ScheduledPayment.ScheduledPaymentFailed"
  trigger "ScheduledPayment.Retry"
end
```

Read the keyword off that block: `policy` is three lines, `on` names
the event, `trigger` names the command it fires, and that is the whole
of it — no condition of its own, because the condition already ran on
the way in (the `given`s on the command it triggers) and the `on` event
is already a committed fact. `Fail` and `Retry` both emit the identical
event name, `ScheduledPaymentFailed`, which is the entire mechanism:
nothing about `policy` cares whether the event it watches for came from
the command that first failed a payment or from a retry re-announcing
the same failure.

## Wiring

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::ScheduledPayment.persisted_by("Memory")
  Banking::Transfer.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
end
```

## A policy firing, self-triggering and all

A scheduled payment needs an account to stand against:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c3" },
                  name: { given: "Kofi", family: "Mensah" }, email: { address: "kofi@example.com" })
runtime.dispatch("Banking::Account.Open", customer_id: "c3", number: { value: "a3" },
                  kind: { name: "current" }, daily_limit: { cents: 50_000 })
runtime.dispatch("Banking::ScheduledPayment.Schedule", account_id: "a3",
                  instruction: { value: "instr1" }, amount: { cents: 500 },
                  recipient: { value: "Landlord Realty" }, due_on: { value: "2026-09-01" })

Banking::ScheduledPayment.find("instr1").attempts.to_h      # => { value: 0 }
Banking::ScheduledPayment.find("instr1").max_attempts.to_h  # => { value: 3 }
```

`Schedule` names no `max_attempts` of its own — there is no argument
for it — so every schedule in this domain gets `RetryLimit`'s declared
default, 3. Fail the presentment once, and watch what one dispatch
actually does:

```ruby
before = runtime.reactions.size
runtime.dispatch("Banking::ScheduledPayment.Fail", instruction: "instr1")
cascade = runtime.reactions[before..]

cascade.size  # => 4
```

One call to `Fail` produced four reactions, not one — `Fail` emitted
`ScheduledPaymentFailed`, `RetryOnPaymentFailure` matched it and
dispatched `Retry`, `Retry`'s own mutation succeeded and emitted
`ScheduledPaymentFailed` again, and the policy matched its own
trigger's output a second time, and a third, before the schedule's
`given` finally had something to say:

```ruby
cascade.count { |r| r[:delivered] == true }                # => 3
cascade.count { |r| r[:delivered] == false }                # => 1
cascade.find { |r| r[:delivered] == false }[:reason]  # => "Retry refused — a retry is still allowed"
```

`delivered: true` three times because `Retry` accepted the call while
`attempts` still read below `max_attempts` — 0, then 1, then 2. The
fourth attempt found `attempts.value == 3`, `given("a retry is still
allowed")` came back false, and `react` recorded the refusal instead of
letting it fly, the same way it would for any command a policy's
trigger reaches: `GivenNotMet` and the rest of the refusal family are
caught and written down; a real defect — a typo in a `trigger`, an
argument the event never carries — is not, and reaches you the way any
other bug would. What is left standing:

```ruby
Banking::ScheduledPayment.find("instr1").status         # => "failed"
Banking::ScheduledPayment.find("instr1").attempts.to_h  # => { value: 3 }
```

Three real attempts, recorded on the record itself, and a `status` that
never left `"failed"` — `Retry`'s own lifecycle transition is `"Retry"
=> "failed", from: "failed"`, so a successful retry is still a failure
until someone dispatches something else.

## The reaction depth limit

Nothing about `policy`'s declaration proves this loop terminates — a
policy is not required to prove that, any more than a `given` is
required to prove anything about the commands it unblocks later. What
actually stopped this one was `given("a retry is still allowed")`, a
fact about a specific schedule's `max_attempts`, not the runtime
stepping in. The runtime's own backstop sits well outside where this
example ever reached it:

```ruby
Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH  # => 5
```

Four reactions from one `Fail` is comfortably inside five, and there is
currently no command on `ScheduledPayment` that lets a caller raise
`max_attempts` past it — every schedule in this domain retries at most
three times before `Abandon` is the only way forward. A policy that
genuinely never stopped — the same shape `RetryOnPaymentFailure`
carries, minus the `given` that bounds it — would instead run into
`Dispatcher::MAX_REACTION_DEPTH` itself: the reaction that would be the
sixth in a chain is refused with `reaction depth 5 reached` instead of
firing, and everything dispatched before it stands as it was. That is
proved directly, on a fixture built for nothing else, by this repo's
own dispatcher tests (`spec/fixtures/reflex.bluebook`) — not
reproduced here, because banking's own retry never needs it: the
business rule that bounds a real retry is also the one you would
want to hit first, in production, before a ceiling built to catch a bug
ever has to.

## When the event's shape and the trigger's don't agree

A policy forwards the event's WHOLE payload as the trigger's arguments,
verbatim — not reshaped, not filtered — so the event's shape and the
trigger's argument shape have to agree before either is written.
Banking's own corpus carries a policy where they don't:

```ruby skip
# Banking, top level, in examples/banking/bluebook/banking.bluebook
policy "FreezeAccountsOnSuspension" do
  on      "CustomerSuspended"
  trigger "Account.Freeze"
end
```

`Customer.Suspend` emits `CustomerSuspended` carrying its own two
arguments — the customer's own reference and the `standing` it was
suspended with. `Account.Freeze` declares neither: it takes no argument
at all beyond which account to act on. Suspend a customer and watch the
policy fire and refuse in the same beat:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c2" },
                  name: { given: "Nadia", family: "Osei" }, email: { address: "nadia@example.com" })
runtime.dispatch("Banking::Account.Open", customer_id: "c2", number: { value: "a2" },
                  kind: { name: "current" }, daily_limit: { cents: 50_000 })

before = runtime.reactions.size
runtime.dispatch("Banking::Customer.Suspend", reference: "c2", standing: { value: "under review" })
runtime.reactions[before..].size  # => 1

runtime.reactions.last[:delivered]  # => false
runtime.reactions.last[:reason]     # => "Freeze does not declare standing — it takes "
```

`Suspend` itself succeeded — the customer really is suspended:

```ruby
Banking::Customer.find("c2").status  # => "suspended"
Banking::Account.find("a2").status   # => "open"
```

— but the account it was meant to freeze never moved, because the
event handed `Account.Freeze` a `standing` field it never declared, and
`refuse_unknown_arguments` stops a command before it ever reaches the
record. There is a second, quieter reason this particular pairing could
never succeed even without `standing` in the way: `CustomerSuspended`
carries the CUSTOMER's own reference, and a customer may hold more than
one account — nothing in the event names which one to freeze, or how
many. A policy is exactly this literal. Get the shapes to agree — a
lean port or event carrying only what its trigger needs — and this
class of bug has nowhere left to hide; get them wrong and the reaction
dies as `UnknownArgument` or `AbsentArgument` on every single delivery,
which is why an external fact belongs on a narrow, purpose-built event
rather than one bookkeeping-heavy enough to drift from what reacts to
it.

## Reaching across domains

A policy does not care where it was written. One declared inside
`aggregate "ScheduledPayment"` and one declared at the bluebook's top
level — banking's corpus has both, and you have already seen one of
each — behave identically at runtime; `on`'s event name is all the
interpreter reads. And when the command a policy triggers lives in a
different domain entirely, `across` names it:

```ruby skip
# Account, in examples/banking/bluebook/banking.bluebook
policy "ReviewOnFreeze" do
  on      "Account.AccountFrozen"
  trigger "AccountFreezeReview.Open"
  across  "Compliance"
end
```

Banking's own `Compliance` domain is real — its own standalone
deployment, `examples/compliance` — but this guide never loads it, and
that is itself worth seeing, because `across` does not pretend
otherwise. Open an account, freeze it, and the policy still fires,
reaching for a domain that genuinely is not loaded HERE:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                  name: { given: "Théo", family: "Lindqvist" }, email: { address: "theo@example.com" })
runtime.dispatch("Banking::Account.Open", customer_id: "c1", number: { value: "a1" },
                  kind: { name: "current" }, daily_limit: { cents: 50_000 })

before = runtime.reactions.size
runtime.dispatch("Banking::Account.Freeze", number: "a1")
runtime.reactions[before..].size     # => 1
runtime.reactions.last[:trigger]     # => "Compliance::AccountFreezeReview.Open"
runtime.reactions.last[:delivered]   # => false
runtime.reactions.last[:reason]      # => "no domain \"Compliance\" loaded (verb Compliance::AccountFreezeReview.Open)"

Banking::Account.find("a1").status   # => "frozen"
```

`Freeze` itself is untouched by any of this — the account is frozen
either way, because a policy reacts to a committed fact and cannot
un-commit it. What `across` buys you the moment `Compliance` IS loaded
in the same process is a real cross-domain dispatch, recorded the same
way; what it buys you here, with `Compliance` absent, is a named
refusal instead of a silent no-op or a crash — `runtime.reactions`
tells you exactly which domain a policy reached for and did not find,
which is the difference between a page you can debug from its own log
and one where a reaction just quietly never happened.

## `process_manager` — a conversation with real state

A policy answers one event with one trigger. `Settlement` answers a
question a policy cannot: a transfer has to leave the source account
before it can arrive at the destination, and something has to remember
which conversation a later event belongs to.

```ruby skip
# Banking, top level, in examples/banking/bluebook/banking.bluebook
process_manager "Settlement" do
  # THE FIELD, NAMED — Transfer.Request declares `attribute :reference,
  # TransferReference`, which is also what Transfer's own `identified_by
  # { reference.value }` derives its id from, so this reads the exact same
  # scalar the old bare `:transfer` reached only by coincidence (the
  # aggregate's own reference key happening to spell the same as the
  # correlation name). Named, not guessed.
  correlates_by :"reference.value"
  starts_on "TransferRequested"
  ends_on   "TransferSettled"

  state "requested"
  state "awaiting_credit"
  state "settled"
  state "reversed"

  on "TransferRequested", transition: { "requested" => "requested" } do
    dispatch "Banking::Account.Debit", with: { number: :source, amount: :amount, narrative: { text: "transfer out" }, reference: :reference }
  end

  on "AccountDebited", transition: { "requested" => "awaiting_credit" } do
    dispatch "Banking::Transfer.Debited", with: { transfer: :reference }
    dispatch "Banking::Account.Credit", with: { number: :destination, amount: :amount, narrative: { text: "transfer in" }, reference: :reference }
  end

  on "AccountCredited", transition: { "awaiting_credit" => "awaiting_credit" } do
    dispatch "Banking::Transfer.Credited", with: { transfer: :reference }
  end

  on "TransferCredited", transition: { "awaiting_credit" => "settled" } do
    dispatch "Banking::Transfer.Settle", with: { transfer: :reference }
  end

  on :refused, transition: { "awaiting_credit" => "reversed" } do
    dispatch "Banking::Account.Credit", with: { number: :source, amount: :amount, narrative: { text: "transfer reversed" } }
    dispatch "Banking::Transfer.Reverse", with: { transfer: :reference }
  end
end
```

`correlates_by` says which conversation an event belongs to — always a
dotted path to one scalar, never a bare value object, for the same
reason `identified_by { reference.value }` already holds `Transfer`'s
own identity to: a value object has no single unambiguous rendering to
key on. `starts_on`/`ends_on` bound the conversation, `state`
enumerates what it may be in, and each `on ..., transition:` block is
one leg — an event that must arrive in one state before the saga
dispatches whatever that leg does next and moves to the one named.

Open two accounts under one customer, fund the source, and ask for a
transfer between them:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c4" },
                  name: { given: "Rosa", family: "Klein" }, email: { address: "rosa@example.com" })
runtime.dispatch("Banking::Account.Open", customer_id: "c4", number: { value: "src1" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Open", customer_id: "c4", number: { value: "dst1" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: "src1", amount: { cents: 1000 }, narrative: { text: "opening balance" })

runtime.dispatch("Banking::Transfer.Request", reference: { value: "tr1" }, amount: { cents: 200 },
                  narrative: { text: "rent" }, source: "src1", destination: "dst1")

Banking::Account.find("src1").balance.to_h  # => { cents: 800, currency: "USD" }
Banking::Account.find("dst1").balance.to_h  # => { cents: 200, currency: "USD" }
Banking::Transfer.find("tr1").status        # => "settled"
```

Nobody dispatched `Debit`, `Debited`, `Credit`, `Credited`, or `Settle`
directly — `Settlement` did, one leg at a time, exactly as its handlers
declare, ending on `TransferSettled`, which is also `ends_on` — the
instance closes there and stops being tracked:

```ruby
runtime.sagas.select { |s| s[:instance] == "tr1" && s[:ended] }
# => [{ process_manager: "Settlement", on: "TransferSettled", instance: "tr1", ended: true }]

runtime.registry.saga_instances["Settlement"].key?("tr1")  # => false
```

## Compensation — the refused leg

Freeze the destination before asking for a second transfer, and the
`Credit` leg refuses partway through — after the money already left the
source:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c5" },
                  name: { given: "Iris", family: "Falk" }, email: { address: "iris@example.com" })
runtime.dispatch("Banking::Account.Open", customer_id: "c5", number: { value: "src2" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Open", customer_id: "c5", number: { value: "dst2" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: "src2", amount: { cents: 1000 }, narrative: { text: "opening balance" })
runtime.dispatch("Banking::Account.Freeze", number: "dst2")

runtime.dispatch("Banking::Transfer.Request", reference: { value: "tr2" }, amount: { cents: 200 },
                  narrative: { text: "rent" }, source: "src2", destination: "dst2")

Banking::Account.find("src2").balance.to_h  # => { cents: 1000, currency: "USD" }
Banking::Transfer.find("tr2").status        # => "reversed"
```

1000, not 800 — the money is back where it started, because a refused
leg unwinds on its own. Nobody dispatched `Reverse` by hand, and nobody
had to notice the transfer had stalled: `on :refused, transition: {
"awaiting_credit" => "reversed" }` is the leg that fires the moment
`Account.Credit` declines, and it dispatches exactly the pair that
restores consistency — the amount back into the source, the transfer
marked reversed. Read the saga log and the refusal that triggered it is
right there, not swallowed:

```ruby
refused = runtime.sagas.select { |s| s[:instance] == "tr2" && s[:delivered] == false }
refused.map { |s| s[:reason] }  # => ["Credit refused — the account is open"]
```

Without this compensation, a refusal like this would leave the money
gone from the source, credited nowhere, until a human noticed the
stalled transfer and corrected it by hand — and the comment beside
`Settlement`'s real declaration says exactly this happened once: the
leg hung off `"TransferReversed"` before, an event only a human
dispatching `Transfer.Reverse` by hand would ever produce, so the
reversal was written and never armed. `:refused` is a refusal, not an
event any command emits, which is why the leg answers it by name rather
than by an `on` string nothing announces.

## When there is nothing to compensate

`Settlement` compensates because a transfer stopped halfway is money
unaccounted for — something must be put back. `Onboarding`, banking's
newest saga, does not, and its own comment says exactly why:

```ruby skip
# Banking, top level, in examples/banking/bluebook/banking.bluebook

# THE FIRST SAGA THAT DOES NOT COMPENSATE. Settlement and ExternalSettlement
# both carry an `on :refused` leg because a transfer stopped halfway is
# money unaccounted for — something must be put back. A KYC case that does
# not clear has nothing to put back: no account was ever opened and no
# money ever moved, so Decline is simply where the flow stops. There is no
# `on :refused` leg here — compare its shape against Settlement's above
# rather than trusting the claim.
process_manager "Onboarding" do
  correlates_by :"reference.value"
  starts_on "OnboardingOpened"
  ends_on   "AccountOpened"

  state "screening"
  state "cleared"
  state "declined"

  on "OnboardingCleared", transition: { "screening" => "cleared" } do
    dispatch "Banking::Account.Open", with: {
      customer_id: :customer,
      number:      :account_number,
      kind:        { name: "current" },
      daily_limit: { cents: 0 }
    }
  end

  # THE NON-COMPENSATING LEG — no dispatch, because nothing was ever
  # created to undo.
  on "OnboardingDeclined", transition: { "screening" => "declined" }
end
```

Clear a case, and the saga does what `Settlement` does — dispatches the
one leg it owns and closes on `ends_on`:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c6" },
                  name: { given: "Salim", family: "Haddad" }, email: { address: "salim@example.com" })
runtime.dispatch("Banking::OnboardingCase.Open", customer: "c6",
                  reference: { value: "ob1" }, account_number: { value: "acct1" })
runtime.dispatch("Banking::OnboardingCase.Clear", reference: "ob1")

runtime.sagas.select { |s| s[:instance] == "ob1" && s[:ended] }
# => [{ process_manager: "Onboarding", on: "AccountOpened", instance: "ob1", ended: true }]

runtime.registry.saga_instances["Onboarding"].key?("ob1")  # => false
Banking::Account.find("acct1").status                      # => "open"
```

Decline one instead, and the saga's own log tells the rest of the
story on its own:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c7" },
                  name: { given: "Priya", family: "Nair" }, email: { address: "priya@example.com" })
runtime.dispatch("Banking::OnboardingCase.Open", customer: "c7",
                  reference: { value: "ob2" }, account_number: { value: "acct2" })
runtime.dispatch("Banking::OnboardingCase.Decline", reference: "ob2")

runtime.sagas.select { |s| s[:instance] == "ob2" }.size  # => 2
runtime.sagas.select { |s| s[:instance] == "ob2" && s.key?(:dispatch) }  # => []

Banking::OnboardingCase.find("ob2").status  # => "declined"
Banking::Account.find("acct2")              # => nil
```

Two log entries — the saga being born, and the one transition to
`"declined"` — and neither one is a `dispatch`, because `on
"OnboardingDeclined"` names no block at all. No account was minted for
`"acct2"` because nothing ever asked for one. And notice what did NOT
happen: `runtime.registry.saga_instances["Onboarding"]` still holds
`"ob2"` —

```ruby
runtime.registry.saga_instances["Onboarding"].key?("ob2")  # => true
```

— because `ends_on` names `"AccountOpened"`, and a declined case never
emits it. `"declined"` is a real, terminal state as far as the KYC case
itself is concerned, but the SAGA's own bookkeeping only closes on the
event it was told to end on — a distinction worth knowing before you
assume every saga that reaches a natural stopping point also stops
being tracked.

## What `bin/model_check` still catches here

Every policy and every process manager here is data, the same data the
runtime dispatches against, which means the checker `verification.md`
covers in depth can walk it with nothing booted. Four of its finding
kinds are specific to this page's own vocabulary: `deaf_trigger` (a
saga's `starts_on`/`ends_on` names an event nothing emits),
`unreachable_pm_state` (a declared saga state no handler chain ever
reaches), `dead_compensation` (a compensation's own `from_state` no
handler chain ever reaches), and `deaf_policy` / `unknown_trigger` (a
policy's `on` or `trigger` naming something that isn't there). Run it
against the same domain this page just walked:

```ruby
require "hecksagain/bluebook/model_check"

findings = Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Banking"))
errors = findings.select { |f| f.severity == :error }

errors.size          # => 1
errors.first.kind     # => :unreachable_pm_state
errors.first.subject  # => "ExternalSettlement"
```

One finding, and it is the same one `verification.md` names and
`ModelCheck::ALLOWED_FINDINGS` allows on purpose: `ExternalSettlement`
leaves its own `"sent"` state unreachable through the handler chain the
checker walks, even though the underlying transfer genuinely sends —
the SAGA's own bookkeeping just never closes on it, the same class of
gap `Onboarding`'s declined leg leaves on its saga tracking above,
caught here by the checker rather than by a customer noticing a
transfer that never seems to finish.
