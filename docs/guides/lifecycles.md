# Lifecycles

A command either fires or it refuses, and `given` is how you write the
refusal that depends on a fact you compute. A lifecycle is different: it
is how you say, once and for all, which STATES a command may fire from
— so the illegal call refuses on its own, and you never have to write
a `given` that just re-checks a field you already named the states of.
Before you ship a command that only makes sense at certain points in a
record's life, decide those points here. Get it right and a caller who
calls things out of order gets told so, in words you wrote, before
anything is written to your store. Get it wrong — forget to give a
state an exit, or declare a transition that can never fire — and
`bin/model_check` is the tool that tells you before your users do.

The examples in this guide run against the real corpus,
`examples/banking/bluebook/banking.bluebook`'s `CardPayment` aggregate:
a card authorisation that is captured, may be challenged after it
settles, and either comes back from that dispute or is charged back
for good. It is one aggregate out of a much larger domain, but
charging back a payment nobody ever disputed is exactly the bug a
lifecycle exists to make impossible.

## The declaration

`CardPayment`'s own lifecycle, exactly as it reads in the real file —
shown here, not redeclared, so nothing on this page can drift from
what the corpus actually says:

```ruby skip
# excerpted from examples/banking/bluebook/banking.bluebook
lifecycle :status, default: "authorized" do
  transition "Capture" => "captured", from: "authorized"
  transition "Void" => "voided", from: "authorized"
  transition "Refund" => "refunded", from: "captured"
  transition "Reverse" => "reversed", from: "captured"
  transition "Dispute" => "disputed", from: ["captured", "refunded"]
  transition "Chargeback" => "charged_back", from: "disputed"
  transition "RejectDispute" => "captured", from: "disputed"
end
```

That `lifecycle` block is the whole shape: a field (`:status`), a
`default:` it starts at, and one `transition` line per legal move —
`"Command" => "target", from: "source"`. Nothing else belongs to it.
`from:` may also be an array, when more than one state lets a command
fire — `Dispute` above fires from either `"captured"` or `"refunded"`,
the same command handling a challenge whether or not the charge was
ever refunded first.

## Wiring

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

A card payment authorizes against an existing account, so the
walkthrough needs one first:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                 name: { given: "Odile", family: "Payer" }, email: { address: "odile@example.com" })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                 kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## The default, and the automatic move

A payment starts in whichever state is named as `default:` — no
transition sets it, because `Authorize` is the creating command and
`"authorized"` is simply where a payment is born:

```ruby
payment = Banking::CardPayment.authorize(account: "a1",
  authorisation: { value: "auth-742" }, amount: { cents: 4200 },
  merchant: { value: "Corner Shop" })
payment.status  # => "authorized"
```

Capture it, and the field moves on its own. There is no `sets
:status` anywhere on `Capture` — the transition IS the assignment,
applied after the command's other mutations, the step
`command_interpreter.rb` calls `advance_lifecycle`:

```ruby
payment.capture
payment.status  # => "captured"
```

## One state, reached by more than one command

`"captured"` is not only where `Capture` lands a payment — it is also
where `RejectDispute` sends one back. Challenge the charge, then have
the dispute thrown out, and it returns to the same settled state by a
different transition:

```ruby
payment.dispute(disputed_by: "c1")
payment.status  # => "disputed"

payment.reject_dispute
payment.status  # => "captured"
```

Two commands, one target state, and neither has to know the other
exists. That is the whole benefit of naming states instead of a
boolean per fact: `"captured"` means one thing, however a payment
arrived there.

## The refusal

Try to charge back a payment that was never disputed — it is sitting
there `"captured"`, not `"disputed"` — and the command refuses before
anything is written:

```ruby
payment.chargeback  # ~> GivenNotMet: Chargeback refused — payment is disputed
```

`Chargeback` also carries its own `given("payment is disputed") {
status == "disputed" }` — a customer/account-status-guard-family
addition, naming in business language exactly the condition
`transition "Chargeback" => "charged_back", from: "disputed"` already
enforces structurally. `enforce_givens` runs BEFORE
`admissible_transition` in dispatch order, so where the two overlap
like this, the `given` is what your caller actually sees:
`GivenNotMet`, not `LifecycleRefused`, even though it is the lifecycle
that named `"disputed"` the only legal source state in the first place.
This is still the whole point of declaring it at the lifecycle: the
states `Chargeback` may fire from are named once, and every caller who
gets the order wrong meets a refusal instead of a `nil` or a corrupted
record — which check gets there first when a `given` also names the
same fact is a detail, not the guarantee.

## Terminal states

Dispute the payment again, and this time carry the charge back for
real — it lands in a state this lifecycle defines no exit from:

```ruby
payment.dispute(disputed_by: "c1")
payment.chargeback
payment.status  # => "charged_back"

payment.reject_dispute  # ~> GivenNotMet: RejectDispute refused — payment is disputed
```

Same overlap as `Chargeback` above — `RejectDispute` carries the same
`given("payment is disputed")`, and it catches a `"charged_back"`
payment before the lifecycle's own `admissible_transition` gets a
turn. No transition names `from: "charged_back"` either way — on
purpose, a charged-back payment is done. `bin/model_check` notices this
shape on every
lifecycle in the corpus and reports it as a `stuck_state` finding —
but at `:warning` severity, not `:error`, because a genuinely terminal
state (`"sold"` in the pizzas example, `"closed"` on a bank account) is
completely fine. The finding exists so you *notice* and confirm it is
what you meant, not so the checker blocks you for it. Ask the checker
yourself, the same way `spec/model_check_spec.rb` does — boot a
registry, hand the bluebook to `ModelCheck.call`:

```ruby
require "hecksagain/bluebook/model_check"

findings = Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Banking"))
cp_findings = findings.select { |f| f.subject == "CardPayment" }

cp_findings.map { |f| [f.kind, f.severity] }  # => [[:stuck_state, :warning], [:stuck_state, :warning], [:stuck_state, :warning]]
cp_findings.any? { |f| f.message.include?("voided") }        # => true
cp_findings.any? { |f| f.message.include?("reversed") }      # => true
cp_findings.any? { |f| f.message.include?("charged_back") }  # => true
```

Three findings this time, not one — `CardPayment` has three states
this lifecycle never declares an exit from: `"voided"` and
`"reversed"`, reached by paths this walkthrough never took, and
`"charged_back"`, just shown live above. The checker names all three
anyway, because it reads the declaration, not a run — `bin/model_check`
would find `"voided"` and `"reversed"` stuck the same way even if this
page never dispatched a single command. Nothing here is an error — this
lifecycle is clean to ship, with three states its own domain considers
done.

## What model_check refuses to let you ship

A stuck state is a judgment call. A **dead transition** and an
**unreachable state** are not — they are declarations that can never
mean anything at runtime, and `bin/model_check` reports both as
`:error`. Nothing in `examples/banking` has either — the corpus stays
free of them on purpose, so the shape that produces them cannot come
from it. What follows is not a domain: it is a small, standalone
fragment, invented for exactly one purpose — giving the checker
something genuinely broken to catch, the same footing
`spec/fixtures/model_check/lifecycle_findings.bluebook` already stands
on in the test suite. It names a state, `"flagged"`, that nothing ever
actually flags a lot INTO:

```ruby bluebook
Hecks.bluebook "Impasse" do
  vision "A lot logged at the dock, inspected, and either cleared or discarded — except nothing ever flags one. A fragment, not a domain: the only place in this guide that is not banking."
  supporting

  aggregate "InboundLot" do
    description "One inbound lot, from logging to inspection."

    identified_by :lot

    attribute :lot, LotNumber

    value_object "LotNumber" do
      attribute :value, String
      invariant("a lot is numbered") { !value.to_s.empty? }
    end

    # "flagged" is only ever a `from:` — nothing transitions a lot INTO
    # it, so Discard can never fire, and "purged" — Discard's only
    # target — can never be reached either. One bad line, two findings.
    lifecycle :status, default: "logged" do
      transition "Inspect" => "cleared", from: "logged"
      transition "Discard" => "purged",  from: "flagged"
    end

    command "Log" do
      role "Dock clerk"
      goal "Register a lot as it arrives"

      attribute :lot, LotNumber

      emits "Logged"
    end

    command "Inspect" do
      role "Quality inspector"
      goal "Clear a logged lot for stowing"

      reference_to InboundLot

      emits "Inspected"
    end

    command "Discard" do
      role "Quality inspector"
      goal "Throw out a lot that failed inspection"

      reference_to InboundLot

      emits "Discarded"
    end
  end
end
```

```ruby
findings = Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Impasse"))

findings.map { |f| [f.kind, f.severity] }.uniq.sort_by { |kind, _| kind.to_s }
# => [[:dead_transition, :error], [:stuck_state, :warning], [:unreachable_state, :error]]

findings.find { |f| f.kind == :dead_transition }.message.include?("can never fire")
# => true

findings.find { |f| f.kind == :unreachable_state }.message.include?("no path from")
# => true
```

Three kinds fire on this one lifecycle, and the severities say which
ones you get to judge and which ones you cannot ship past: `Discard`
naming a `from:` no path ever reaches (`dead_transition`), `"purged"`
consequently unreachable by anything (`unreachable_state`) — both
errors, both real declarations that can never do anything — and
`"cleared"` genuinely has no exit either, which is only a `stuck_state`
warning, because maybe that really is where an inspection flow ends
and maybe you forgot a `Stow` transition out of it. The checker cannot
tell your intent apart from your typo; it can only tell you dead code
apart from a live one. Run `bin/model_check` before you ship a
lifecycle, not after a caller reports that a command they expected to
work simply never fires. `Impasse` stops here — the rest of this guide,
and every other page that runs against real data, is banking.

## Entities have lifecycles too

Everything shown here about an aggregate's `lifecycle` applies
unchanged to an `entity` nested inside one — `entity_builder.rb`
declares the same `lifecycle` keyword, and `model_check` walks an
entity's states exactly as it walks its owning aggregate's. Banking's
own `SafeDepositBox::KeyIssuance` carries one (`"issued"` to
`"returned"`, on the key itself, not the box that issued it). See the
[entities guide](entities.md) for the rest of what an entity carries.
