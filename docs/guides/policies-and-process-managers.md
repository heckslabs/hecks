# Policies and process managers

A command answers a synchronous caller directly. Much of what a real
system does is not synchronous — a payment gateway's webhook fires, a
delivery truck crosses the gate, and nothing is waiting for a direct
answer. Something inside the domain still has to react, and the
reaction is a domain decision, not infrastructure. `policy` is the seam
where an external fact becomes that decision: not a script, not a
callback bolted onto an event bus, a declared reaction the runtime
fires and records the outcome of, the same way it records everything
else. `process_manager` is the seam for the reaction that cannot finish
in one step — a delivery that has to leave one place before it can
arrive at another, with a real chance of failing partway through.

Both are provable within one small domain.

A construction site. Material gets logged onto a stockpile as trucks
arrive, an alarm gets installed and can be sounded, and units of
material get hauled from one bin to another — with the bin at either
end sometimes shut.

## The declaration

```ruby bluebook
Hecks.bluebook "Chantier" do
  vision "A construction site — material arrives, gets moved, and occasionally an alarm won't stop."
  supporting

  aggregate "Stockpile" do
    description "A pile of one material, tracked by weight, on site."

    identified_by { material.value }

    attribute :material, MaterialName
    attribute :quantity, Quantity

    value_object "MaterialName" do
      attribute :value, String
      invariant("a stockpile names its material") { !value.to_s.empty? }
    end

    value_object "Quantity" do
      attribute :count, Integer, default: 0
    end

    value_object "DeliveryAmount" do
      attribute :count, Integer
      invariant("a delivery brings something") { count.positive? }
    end

    command "Open" do
      role "Site manager"
      goal "Start tracking a material on site"

      attribute :material, MaterialName

      emits "Opened"
    end

    # MUTATING, NOT CREATING — the policy below re-dispatches this every
    # time a delivery is logged at the gate, against the SAME pile. The
    # real rule (does this material even belong on site) stays here, not
    # on the port that merely reports the truck arrived.
    command "Receive" do
      role "System"
      goal "Add a logged delivery to the pile"

      reference_to Stockpile
      attribute :amount, DeliveryAmount

      then_set :quantity, increment: :amount

      emits "Received"
    end

    # THE EXTERNAL FACT ARRIVING IS NOT A DECISION THIS DOMAIN MAKES — the
    # gate merely reports a truck crossed it. See the DeliveryGate port
    # below (pizzas.hecksagon's PaymentGateway is the same shape): no
    # given, no then_set on the port itself, reached only through here.
    policy "OnMaterialsDelivered" do
      on "MaterialsDelivered"
      trigger "Stockpile.Receive"
    end
  end

  aggregate "Alarm" do
    description "A siren whose sounding sets it off again — the loop MAX_REACTION_DEPTH exists to stop."

    identified_by { post.value }

    attribute :post, AlarmPost

    value_object "AlarmPost" do
      attribute :value, String
      invariant("an alarm names its post") { !value.to_s.empty? }
    end

    command "Install" do
      role "Site manager"
      goal "Hang a siren that can be sounded"

      attribute :post, AlarmPost

      emits "Installed"
    end

    # MUTATING, NOT CREATING — the policy below re-dispatches this against
    # the SAME siren every time the reaction feeds itself. A creating
    # command would refuse the second attempt as AlreadyExists, and the
    # loop this fixture exists to prove would never get past one bounce.
    command "Sound" do
      role "Site manager"
      goal "Sound the siren, which sounds the siren"

      reference_to Alarm

      emits "Sounded"
    end

    policy "ResoundOnSounded" do
      on "Sounded"
      trigger "Alarm.Sound"
    end
  end

  aggregate "Bin" do
    description "A bin holding units of one material, on site."

    identified_by { tag.value }

    attribute :tag,   BinTag
    attribute :units, Units

    value_object "BinTag" do
      attribute :value, String
      invariant("a bin is tagged") { !value.to_s.empty? }
    end

    value_object "Units" do
      attribute :count, Integer, default: 0
    end

    lifecycle :status, default: "open" do
      transition "Shut"   => "shut", from: "open"
      transition "Reopen" => "open", from: "shut"
    end

    command "Place" do
      role "Site manager"
      goal "Put a new bin on site"

      attribute :tag, BinTag

      emits "Placed"
    end

    command "LoadIn" do
      role "System"
      goal "Units arrive in the bin"

      reference_to Bin
      attribute :amount, Units

      given("the bin is open") { status == "open" }

      then_set :units, increment: :amount

      emits "LoadedIn"
    end

    command "TakeOut" do
      role "System"
      goal "Units leave the bin"

      reference_to Bin
      attribute :amount, Units

      given("the bin is open")    { status == "open" }
      given("the units cover it") { units.count >= amount.count }

      then_set :units, decrement: :amount

      emits "TakenOut"
    end

    command "Shut" do
      role "Site manager"
      goal "Close a bin to further loads"

      reference_to Bin

      emits "BinShut"
    end

    command "Reopen" do
      role "Site manager"
      goal "Open a bin back up"

      reference_to Bin

      emits "BinReopened"
    end
  end

  aggregate "Consignment" do
    description "Units in transit from one bin to another, tracked till they land or come back."

    identified_by { docket.value }

    attribute :docket, DocketNumber
    attribute :units,  Units

    value_object "DocketNumber" do
      attribute :value, String
      invariant("a consignment is numbered") { !value.to_s.empty? }
    end

    value_object "Units" do
      attribute :count, Integer, default: 0
    end

    reference_to Bin, as: :source
    reference_to Bin, as: :destination

    lifecycle :status, default: "requested" do
      transition "Haul"    => "hauling",   from: "requested"
      transition "Deliver" => "delivered", from: "hauling"
      transition "Return"  => "returned",  from: "hauling"
    end

    command "Request" do
      role "Site manager"
      goal "Ask for units to move from one bin to another"

      attribute :docket, DocketNumber
      attribute :units,  Units
      reference_to Bin, as: :source
      reference_to Bin, as: :destination

      given("a consignment moves something") { units.count.positive? }

      then_set :units,       to: :units
      then_set :source,      to: :source
      then_set :destination, to: :destination

      emits "ConsignmentRequested"
    end

    command "Haul" do
      role "System"
      goal "The source bin gave the units up"

      reference_to Consignment

      emits "ConsignmentHauled"
    end

    command "Deliver" do
      role "System"
      goal "The destination bin has the units"

      reference_to Consignment

      emits "ConsignmentDelivered"
    end

    command "Return" do
      role "System"
      goal "The units went back to where they started"

      reference_to Consignment

      emits "ConsignmentReturned"
    end
  end

  # THE FIELD, NAMED — not the value object that carries it.
  # `correlates_by :docket` would key this saga on the whole
  # DocketNumber, and a non-scalar correlation key is ambiguous by
  # construction: keying on the object and keying on its rendered text
  # are both defensible readings that correlate differently.
  # `:"docket.value"` reaches past the wrapper for the one scalar with a
  # single unambiguous rendering — the same discipline `identified_by
  # { docket.value }` already holds Consignment's own identity to.
  process_manager "Haulage" do
    correlates_by :"docket.value"
    starts_on "ConsignmentRequested"
    ends_on   "ConsignmentDelivered"

    state "requested"
    state "hauling"
    state "delivered"
    state "returned"

    on "ConsignmentRequested", transition: { "requested" => "requested" } do
      dispatch "Chantier::Bin.TakeOut", with: { tag: :source, amount: :units, docket: :docket }
    end

    on "TakenOut", transition: { "requested" => "hauling" } do
      dispatch "Chantier::Consignment.Haul", with: { docket: :docket }
      dispatch "Chantier::Bin.LoadIn", with: { tag: :destination, amount: :units, docket: :docket }
    end

    on "LoadedIn", transition: { "hauling" => "delivered" } do
      dispatch "Chantier::Consignment.Deliver", with: { docket: :docket }
    end

    # THE COMPENSATING LEG. Its trigger is a REFUSAL, not an event — no
    # aggregate announces "the leg you dispatched was declined" — so it
    # answers `:refused` instead of a name any command emits.
    on :refused, transition: { "hauling" => "returned" } do
      dispatch "Chantier::Bin.LoadIn", with: { tag: :source, amount: :units, docket: :docket }
      dispatch "Chantier::Consignment.Return", with: { docket: :docket }
    end
  end
end
```

Read the two new keywords off that file. `policy` is three lines: `on`
names the event, `trigger` names the command it fires, and that is the
whole of it — no condition of its own, because the condition already
ran on the way in (the `given`s on the command it triggers) and the
`on` event is already a committed fact. `process_manager` is a
protocol: `correlates_by` says which conversation an event belongs to,
`starts_on`/`ends_on` bound it, `state` enumerates what it may be in,
and each `on ..., transition:` block is one leg — an event that must
arrive in one state before the saga moves to the next and dispatches
whatever that leg does next.

## Wiring

```ruby boot
Hecks.hecksagon("Chantier") do
  Chantier::Stockpile.persisted_by("Memory")
  Chantier::Alarm.persisted_by("Memory")
  Chantier::Bin.persisted_by("Memory")
  Chantier::Consignment.persisted_by("Memory")

  # THE PRIMARY PORT — called by an adapter outside this domain entirely
  # (a gate log, in practice; pizzas.hecksagon's PaymentGateway is the
  # same shape for a payment webhook). `as: :material` is chosen
  # deliberately to equal Stockpile's own `Receive` self-reference key —
  # `identified_by { material.value }` gives Stockpile that key for
  # free, so the policy below can forward the port's payload straight
  # into `Receive` without either side needing to know the other's
  # field names by any other means.
  Chantier::Stockpile.port "DeliveryGate" do
    operation "Log" do
      reference_to Stockpile, as: :material
      attribute :amount, DeliveryAmount
      emits "MaterialsDelivered"
    end
  end
end
```

## A policy firing

The gate log is not part of this domain — it is an adapter's job to
call in, the same way a Rails controller or a payment webhook would.
`Dispatcher#dispatch_port` is that door for a port operation, and here
it stands in for the adapter:

```ruby
stockpile = Chantier::Stockpile.open(material: { value: "rebar" })
stockpile.quantity.to_h  # => { count: 0 }

runtime.dispatch_port("Chantier", "Stockpile", "DeliveryGate", "Log",
                      material: stockpile.id, amount: { count: 40 })

Chantier::Stockpile.find(stockpile.id).quantity.to_h  # => { count: 40 }
```

The pile moved without anything calling `Receive` directly. What
actually happened: the port emitted `MaterialsDelivered`, `on
"MaterialsDelivered"` matched it, and `PolicyInterpreter#react`
dispatched `Stockpile.Receive` with the event's own payload —
verbatim, not reshaped — and recorded what happened:

```ruby
runtime.reactions.last  # => { policy: "OnMaterialsDelivered", on: "MaterialsDelivered", trigger: "Chantier::Stockpile.Receive", delivered: true }
```

`delivered: true` because `Receive` accepted the call. Had `Receive`
carried a `given` this delivery violated, the record would read
`delivered: false` with the refusal's own message as `reason` — a
policy's target refusing is a fact about the domain, not a crash, and
`react` catches exactly the refusal family every command already
raises (`GivenNotMet`, `InvariantViolation`, and the rest) and writes
it down instead of letting it fly. Anything outside that family — a
typo in the policy's own `trigger`, a real defect — is not caught, and
reaches you the same way any other bug would.

This is also why the port's payload had to spell `material:` exactly
the way `Receive`'s own self-reference key reads: a policy forwards the
WHOLE event payload as the trigger's arguments, so the event's shape
and the trigger's argument shape have to agree before either is
written. Get that wrong — a stray field on the event the trigger never
declared, or a required argument the event never carries — and the
reaction dies as `UnknownArgument` or `AbsentArgument` on every single
delivery, which is why an external fact belongs on a lean port
operation rather than a creating command with bookkeeping fields of its
own: the fewer fields on the event, the fewer ways this can drift.

A policy also does not care where it was written. One declared inside
`aggregate "Stockpile"` and one declared at the bluebook's top level —
banking's corpus has both — behave identically at runtime; `on`'s event
name is all the interpreter reads. And when the command a policy
triggers lives in a different domain entirely, `across` names it:

```ruby skip
policy "NotifyOnClosure" do
  on      "AccountClosed"
  trigger "Notifications.Send"
  across  "Notifications"
end
```

— real, live usage from banking's own corpus, shown and not run here
because it names a domain this guide does not own. Leave `across`
off and the trigger is assumed to live in the same domain as the event
that fired it, which is the ordinary case and the one Chantier uses
throughout.

## The reaction depth limit

`ResoundOnSounded` triggers the very command that fired it. Nothing
about the declaration itself refuses that — a policy is not required
to prove it terminates, any more than a `given` is required to prove
anything about the commands it might unblock later. What stops it from
taking your production process down with it is `Dispatcher::MAX_REACTION_DEPTH`,
a hard ceiling on how many reactions may chain from one original
dispatch:

```ruby
alarm = Chantier::Alarm.install(post: { value: "gate-1" })
before = runtime.reactions.size
alarm.sound

(runtime.reactions.size - before)  # => Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1
```

One `sound` produced `MAX_REACTION_DEPTH` deliveries and one stopped
reaction — the loop ran exactly as far as the ceiling allows and no
further:

```ruby
stopped = runtime.reactions.select { |r| r[:policy] == "ResoundOnSounded" && r[:delivered] == false }
stopped.size            # => 1
stopped.first[:reason]  # => "reaction depth #{Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH} reached"
```

Nothing about the siren is actually broken — read it back and it sat
through every one of those soundings exactly the way `Sound` says it
should:

```ruby
Chantier::Alarm.find("gate-1").events.map(&:name).count("Sounded")  # => Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1
```

This is the safety net, not a design flaw to route around: a policy
that turns out to trigger itself — directly, the way `ResoundOnSounded`
does, or through a cycle two or three policies long — stops and records
why instead of exhausting your process. Read `runtime.reactions` (or
its saga twin, `runtime.sagas`, below) the way you would read a log:
`delivered: false, reason: "reaction depth ... reached"` is the
runtime telling you a loop exists, in production, before it becomes an
outage.

## `process_manager` — a conversation with real state

A policy answers one event with one trigger. `Haulage` answers a
question a policy cannot: a consignment has to leave the source bin
before it can arrive at the destination, and something has to remember
which conversation a later event belongs to. `correlates_by
:"docket.value"` is that memory key — always a dotted path to one
scalar, never a bare value object, for the reason the comment beside it
in the bluebook gives: a value object has no single unambiguous
rendering to key on, so the declaration is refused at load time unless
it names a field.

Set two bins up and ask for a haul between them:

```ruby
yard = Chantier::Bin.place(tag: { value: "yard" })
site = Chantier::Bin.place(tag: { value: "site" })
runtime.dispatch("Chantier::Bin.LoadIn", tag: "yard", amount: { count: 100 })

runtime.dispatch("Chantier::Consignment.Request",
                 docket: { value: "c-1" }, units: { count: 25 }, source: "yard", destination: "site")

Chantier::Bin.find("yard").units.to_h  # => { count: 75 }
Chantier::Bin.find("site").units.to_h  # => { count: 25 }
Chantier::Consignment.find("c-1").status  # => "delivered"
```

Nothing dispatched `Haul`, `LoadIn` on the destination, or `Deliver`
directly — `Haulage` did, one leg at a time, exactly as its handlers
declare: `ConsignmentRequested` took the units out of `yard`,
`TakenOut` moved the consignment to `hauling` and put them into `site`,
and `LoadedIn` moved it to `delivered`, which is also `ends_on` — the
instance closes there and stops being tracked:

```ruby
runtime.sagas.select { |s| s[:ended] }  # => [{ process_manager: "Haulage", on: "ConsignmentDelivered", instance: "c-1", ended: true }]
runtime.registry.saga_instances["Haulage"].key?("c-1")  # => false
```

## Compensation — the refused leg

Shut the destination bin before asking for a second haul, and the
`LoadIn` leg refuses partway through — after the units already left
`yard`:

```ruby
runtime.dispatch("Chantier::Bin.Shut", tag: "site")
runtime.dispatch("Chantier::Consignment.Request",
                 docket: { value: "c-2" }, units: { count: 10 }, source: "yard", destination: "site")

Chantier::Bin.find("yard").units.to_h  # => { count: 75 }
Chantier::Consignment.find("c-2").status  # => "returned"
```

75, not 65 — the units are back where they started, because a refused
leg unwinds on its own. Nobody dispatched `Return` by hand, and nobody
had to notice the haul had stalled: `on :refused, transition: {
"hauling" => "returned" }` is the leg that fires the moment
`Bin.LoadIn` declines, and it dispatches exactly the pair that restores
consistency — units back into the source bin, the consignment
marked returned. Read the saga log and the refusal that triggered it is
right there, not swallowed:

```ruby
returned = runtime.sagas.select { |s| s[:process_manager] == "Haulage" && s[:instance] == "c-2" }
returned.find { |s| s[:delivered] == false }[:reason]  # => "LoadIn refused — the bin is open"
```

Without this compensation, a refusal like this would leave the units
gone from `yard`, credited nowhere, until a human noticed the stalled
haul and corrected it by hand. A
compensating leg that is itself refused does not unwind a second time —
no flag has to say so, because the state already moved to the
compensation's own `to_state` before its dispatches ran, and a repeat
refusal simply finds the instance no longer where the second unwind
would need it.

## What `bin/model_check` catches, before a customer's haul gets stuck

Every lifecycle and every process manager here is data, the same data
the runtime dispatches against — which means it can be walked
statically, with nothing booted, and checked against every corpus
domain before any of it ships. Run it here and only the two truly
open-ended states — `delivered` and `returned`, terminal by design, and
so flagged as informational, not blocking:

```ruby
require "hecksagain/bluebook/model_check"

Hecksagain::Bluebook::ModelCheck.call(runtime.registry.bluebook("Chantier")).select { |f| f.severity == :error }  # => []
```

Rename a `starts_on`/`ends_on` to an event nothing in the domain emits,
declare a saga `state` no handler chain ever reaches, or leave a
compensation's own `from_state` unreachable, and this same call
reports it by kind — `deaf_trigger`, `unreachable_pm_state`,
`dead_compensation` — with the process manager's name attached, the way
it genuinely did once in banking's own corpus (`ExternalSettlement`'s
`state "sent"` — real, reachable in the aggregate's own lifecycle, but
never wired into the saga's OWN handler chain, which model_check.rb
still names as a known, allowed finding rather than a design flaw
silently fixed out from under the example). The payoff is entirely
about when you find out: a saga with a state its own protocol can never
reach, or a compensation nothing can ever trigger, is a bug you want
`bin/model_check` to name in CI — not a stalled haul discovered in
production, with a customer's material sitting in neither bin.
