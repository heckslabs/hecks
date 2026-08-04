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

A warehouse. Crates arrive, get put away, get pulled for an order, and
either go back on the shelf or go out the door. Small enough to hold in
one hand, real enough that shipping the wrong crate at the wrong point
in its life is exactly the bug a lifecycle exists to make impossible.

## The declaration

```bluebook
Hecks.bluebook "Depot" do
  vision "A crate's life from the receiving dock to the outbound truck, and nothing skipped."
  supporting

  aggregate "Crate" do
    description "One crate of goods, tracked from arrival to departure."

    identified_by { label.value }

    attribute :label, CrateLabel

    value_object "CrateLabel" do
      attribute :value, String
      invariant("a crate is labelled") { !value.to_s.empty? }
    end

    lifecycle :status, default: "received" do
      transition "Stow"    => "stowed",  from: "received"
      transition "Pick"    => "picked",  from: "stowed"
      transition "Restock" => "stowed",  from: "picked"
      transition "Ship"    => "shipped", from: "picked"
    end

    command "Receive" do
      role "Dock clerk"
      goal "Log a crate as it comes off the inbound truck"

      attribute :label, CrateLabel

      emits "Received"
    end

    command "Stow" do
      role "Warehouse operative"
      goal "Put a received crate on a shelf"

      reference_to Crate

      emits "Stowed"
    end

    command "Pick" do
      role "Warehouse operative"
      goal "Pull a stowed crate to fill an order"

      reference_to Crate

      emits "Picked"
    end

    command "Restock" do
      role "Warehouse operative"
      goal "Put a picked crate back — the order it was pulled for fell through"

      reference_to Crate

      emits "Restocked"
    end

    command "Ship" do
      role "Dock clerk"
      goal "Load a picked crate onto the outbound truck"

      reference_to Crate

      emits "Shipped"
    end
  end
end
```

That `lifecycle` block is the whole shape: a field (`:status`), a
`default:` it starts at, and one `transition` line per legal move —
`"Command" => "target", from: "source"`. Nothing else belongs to it.
`from:` may also be an array, when more than one state lets a command
fire — `Close` on a bank customer moves from either `"active"` or
`"suspended"`, the same idea one array wider.

## Wiring

```ruby boot
Hecks.hecksagon("Depot") { Depot::Crate.persisted_by("Memory") }
```

## The default, and the automatic move

A crate is born in whichever state you named as `default:` — no
command sets it, because none has run yet:

```ruby
crate = Depot::Crate.receive(label: { value: "PLT-1042" })
crate.status  # => "received"
```

Stow it, and the field moves on its own. There is no `then_set
:status` anywhere on `Stow` — the transition IS the assignment, applied
after the command's other mutations, the step `command_interpreter.rb`
calls `advance_lifecycle`:

```ruby
crate.stow
crate.status  # => "stowed"
```

## One state, reached by more than one command

`"stowed"` is not only where `Stow` lands a crate — it is also where
`Restock` sends one back. Pull the crate for an order, then have the
order fall through, and it returns to the same shelf state by a
different door:

```ruby
crate.pick
crate.status  # => "picked"

crate.restock
crate.status  # => "stowed"
```

Two commands, one target state, and neither has to know the other
exists. That is the whole benefit of naming states instead of a
boolean per fact: `"stowed"` means one thing, however a crate arrived
there.

## The refusal

Try to ship a crate that was never picked — it is sitting there
`"stowed"`, not `"picked"` — and the command refuses before anything is
written:

```ruby
crate.ship  # ~> LifecycleRefused: status is "stowed", and Ship moves it only from "picked"
```

Nothing in `Ship`'s declaration wrote that sentence — no `given`
reading `status`, no hand-rolled check. The transition's own `from:`
IS the rule, and `LifecycleRefused` is what a command raises when the
current state names no matching transition. This is the whole point:
you declared which states `Ship` may fire from once, at the lifecycle,
and every caller who gets the order wrong meets the same refusal
instead of a `nil` or a corrupted record.

## Terminal states

Pick the crate again and ship it for real, and it lands somewhere
nothing in this lifecycle ever leaves:

```ruby
crate.pick
crate.ship
crate.status  # => "shipped"

crate.stow  # ~> LifecycleRefused: status is "shipped", and Stow moves it only from "received"
```

No transition names `from: "shipped"` — on purpose, a shipped crate is
done. `bin/model_check` notices this shape on every lifecycle in the
corpus and reports it as a `stuck_state` finding — but at `:warning`
severity, not `:error`, because a genuinely terminal state (`"sold"`
in the pizzas example, `"closed"` on a bank account) is completely
fine. The finding exists so you *notice* and confirm it is what you
meant, not so the checker blocks you for it. Ask the checker yourself,
the same way `spec/model_check_spec.rb` does — boot a registry, hand
the bluebook to `ModelCheck.call`:

```ruby
require "hecksagain/bluebook/model_check"

findings = Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Depot"))
findings.map { |f| [f.kind, f.severity] }  # => [[:stuck_state, :warning]]
```

One finding, one warning, and it names exactly the state we just
proved has no exit. Nothing here is an error — this crate lifecycle is
clean to ship.

## What model_check refuses to let you ship

A stuck state is a judgment call. A **dead transition** and an
**unreachable state** are not — they are declarations that can never
mean anything at runtime, and `bin/model_check` reports both as
`:error`. Here is the shape that produces them, a lot-inspection flow
that names a state, `"flagged"`, that nothing ever actually flags a lot
INTO:

```bluebook
Hecks.bluebook "Depot" do
  vision "A lot logged at the dock, inspected, and either cleared or discarded — except nothing ever flags one."
  supporting

  aggregate "InboundLot" do
    description "One inbound lot, from logging to inspection."

    identified_by { lot.value }

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
findings = Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Depot"))

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
work simply never fires.

## Entities have lifecycles too

Everything shown here about an aggregate's `lifecycle` applies
unchanged to an `entity` nested inside one — `entity_builder.rb`
declares the same `lifecycle` keyword, and `model_check` walks an
entity's states exactly as it walks its owning aggregate's. See the
entities guide for the rest of what an entity carries.

— Miette
