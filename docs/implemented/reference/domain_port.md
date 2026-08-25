# DomainPort

<!-- generated:begin id=page -->
Words available inside `port do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

`operation` is the spelling the corpus uses; `tells`, `asks` and `verb`
appear nowhere in it, so this page declares a domain that carries all
four — a shipment that asks a carrier for a quote, is told when it was
delivered, and records itself through a swappable resource port:

```ruby bluebook
Hecks.bluebook "DomainPortReference" do
  vision "A shipment, and the two directions a port can point."

  aggregate "Shipment" do
    attribute :waybill, Waybill

    identified_by :waybill
    attribute :note, Note

    value_object("Waybill") { attribute :value, String }
    value_object("Note")    { attribute :text,  String }

    command "Book" do
      sets :waybill
      sets :note
      emits "ShipmentBooked"
    end
  end
end
```

The adapter answering the ask refuses for one waybill and succeeds for
the other, so both endings are reachable from a single boot:

```ruby boot
# A CLASS, not a module — the runtime instantiates whatever it resolves
# for the port, so a bare module answers `NoMethodError: undefined
# method 'new'`. Which itself arrives as a `refuses` event rather than
# an exception, exactly as documented under `refuses` below.
class RefCarrier
  def quote(**args)
    raise "no service to that address" if args[:waybill].to_s.include?("remote")

    { "price" => { "cents" => 1_200 } }
  end
end

Hecks::Adapters.const_set(:RefCarrier, RefCarrier) unless Hecks::Adapters.const_defined?(:RefCarrier, false)
Hecks.adapter("RefCarrier") { port "Carrier" }

Hecks.hecksagon("DomainPortReference") do
  DomainPortReference::Shipment.persisted_by("Memory")

  DomainPortReference::Shipment.port "Carrier" do
    asks "Quote" do
      attribute :waybill, Hecks::Bluebook::Reference.new("Shipment")
      answers "QuoteReturned"
      refuses "QuoteRefused"
    end

    tells "Delivered" do
      attribute :waybill, Hecks::Bluebook::Reference.new("Shipment")
      emits "DeliveryReported"
    end
  end

  # A PORT IS A `verb` OR ONE-OR-MORE `operation`s, never both — so the
  # resource port is a second port, not another word inside the first.
  DomainPortReference::Shipment.port "Ledger" do
    verb "recorded_by"
  end
end
```

```ruby
runtime.dispatch("DomainPortReference::Shipment.Book", waybill: { value: "wb-1" }, note: { text: "two crates" })
runtime.dispatch("DomainPortReference::Shipment.Book", waybill: { value: "wb-remote" }, note: { text: "one crate" })
```

## operation

<!-- generated:begin word=operation -->
`operation name, to: do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `to:` | constant | false | to |
<!-- generated:end -->

Opens one translation from an external fact into this domain's own event vocabulary — `reference_to`, `attribute`, and `emits`, nothing else: the builder behind it defines no `given` or `sets`, so an operation cannot read aggregate state or mutate a record itself. A `port` declares `operation`s or a `verb` (below) — never both, and never neither. Pizzas' `PaymentGateway` port and its `Receive` operation (`examples/pizzas/bluebook/pizzas.hecksagon`) are the worked example — it only emits `PizzaPaymentReceived`; the actual rules (must have a topping, must still be available) stay on `Order`'s own `Purchase` command, reached through the `OnPizzaPaymentReceived` policy beside it. See the PortOperation reference page for the vocabulary inside.

An operation is addressed through its port, not directly off the
aggregate — `Aggregate.Port.Operation`:

```ruby
shipment = runtime.registry.bluebook("DomainPortReference").aggregate("Shipment")
shipment.ports.map(&:name)  # => ["Carrier"]
shipment.ports.find { |port| port.name == "Carrier" }.operations.map(&:hecks_name)  # => ["Quote", "Delivered"]
```

## tells

<!-- generated:begin word=tells -->
`tells name, to: do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `to:` | constant | false | to |
<!-- generated:end -->

What the outside TELLS this domain — an external fact arriving, translated
into the domain's own word for it. Identical to `operation`, which is the
spelling every chapter in this corpus still uses and which keeps working;
`tells` is the same word under a name that says which way it points, now
that it has a twin.

It emits, and that is all. There is no channel back to whoever called: an
inbound operation is the anti-corruption boundary, and whatever should
happen next happens wherever a `policy` reacts to the event it emitted.
Declaring `answers` or `refuses` on one is refused when the bluebook builds.

`Delivered` is an inbound fact: something outside says the crate
arrived, and the domain records that it was told:

```ruby
told = runtime.dispatch("DomainPortReference::Shipment.Carrier.Delivered", waybill: "wb-1")
told.events.map(&:name)  # => ["DeliveryReported"]
```

**Written exemption (ADR 0025 principle 4)** — no real corpus member
declares `tells`; pizzas' `PaymentGateway.Receive` (the one real
inbound port operation this corpus has) still spells it `operation`.
The MECHANISM `tells` names is proven for real by that call — the two
words fill the same `PortOperation` construct, identically — what is
unproven is only the SPELLING, and giving `tells` its own separate
corpus member would mean inventing a second inbound integration this
codebase does not otherwise need, for a word that changes nothing
about how the runtime behaves once declared.

Nothing goes back. The event is the whole of it, and what happens next
is a `policy`'s business:

```ruby
carrier = shipment.ports.find { |port| port.name == "Carrier" }
delivered = carrier.operations.find { |operation| operation.hecks_name == "Delivered" }
delivered.answers  # => nil
```

## asks

<!-- generated:begin word=asks -->
`asks name, to: do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `to:` | constant | false | to |
<!-- generated:end -->

What this domain ASKS of the outside — the direction the language did not
have until it was added, and the reason a `port` can now be read in both
directions.

Before it, a domain could be *called by* an adapter and never call one:
`Ports::Extraction.adapter.canonical(...)` is library code reaching for an
adapter, and `MockStripeAdapter#create_session` is an application doing the
same. Neither is the domain asking, and neither leaves a trace in the record.

An `asks` is dispatched like any other port operation — a `policy` can
`trigger` it off an event, because the dispatcher resolves ports before
entities — and it comes back as one of the two events it named. That is what
makes the outside world something the model can reason about instead of a
place exceptions come from.

It must name both endings (`answers` and `refuses`) and may not `emits`.
An ask that named only its happy ending would put the failure somewhere the
model cannot see, which is the whole reason a boundary is worth modelling.

The adapter really is called, and what it returned comes back as the
event the ask named:

```ruby
answered = runtime.dispatch("DomainPortReference::Shipment.Carrier.Quote", waybill: "wb-1")
answered.events.map(&:name)  # => ["QuoteReturned"]
```

And when the outside says no, that is an event too — not an exception
escaping into the caller:

```ruby
refused = runtime.dispatch("DomainPortReference::Shipment.Carrier.Quote", waybill: "wb-remote")
refused.events.map(&:name)  # => ["QuoteRefused"]
```

## verb

<!-- generated:begin word=verb -->
`verb verb` — fills `verb`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | verb |
<!-- generated:end -->

The driven half of the same `port` call — a swappable resource port
(`persisted_by`, `opened_by`, a project's own `provided_by`) rather than a
translation of an inbound fact. `verb "opened_by"` registers the exact same
`IR::Port` a standalone `.port` file's `Hecks.port "name" do verb "..."
end` would, reached by whichever adapters declare `port "Checkout"` and
bound the same way — one line, next to the aggregate it belongs to,
instead of a separate file. A port is a `verb` or one-or-more `operation`s,
never both; declaring neither, or both, refuses to build. See
writing-an-adapter.md's own section on resource ports for a worked
example.

A `verb` port declares no operations at all — it names the binding word
an adapter is reached by:

A `verb` port does not land beside the driving ports on the aggregate —
it registers as a RESOURCE port on the registry itself, next to the
persistence and extraction ports the framework declares the same way:

```ruby
runtime.registry.ports.keys.sort  # => ["Ledger", "extraction", "persistence"]
```

Which is the difference the prose above is drawing. A driving port is
part of the domain's own surface; a resource port is a socket an
adapter plugs into, and it has no operations of its own to address.

**Written exemption (ADR 0025 principle 4)** — every resource port a
real domain here actually needs (`persisted_by`, `projected_by`,
`opened_by`) is a FRAMEWORK-level default (`hecksagon_builder.rb`'s
own settings words), never a project declaring its own `port "X" do
verb "..." end` line — so nothing in `examples/` or
`lib/hecks/framework/` exercises the bare construct this section
documents. `writing-an-adapter.md`'s own worked example is the closest
this repo has to a real one, and it is a guide, not a corpus member.

