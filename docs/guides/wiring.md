# Wiring

A domain that boots in memory and refuses correctly —
[getting-started.md](getting-started.md) or [commands.md](commands.md) covers that ground. That domain does
not yet know where its records will actually live when someone other
than the developer is running it, and it should not: a bluebook that named its
own database would be a bluebook that lied the day the provider changed.
This page is where that knowledge lives instead — the
`.hecksagon` and the `.world` — and it is where the decisions
a shipped feature cannot leave unmade get made: which adapter holds each
aggregate, what an outside fact has to look like before this domain
will listen to it, and which values differ from one deployment to the
next. The domain says WHAT: the wiring says
WHERE, and neither file is allowed to say the other's part.

## The folder convention, briefly

`README.md`'s own **folder convention** section is the source of
truth here and is not repeated in full below; read it first if it has not been read yet.
The shape it settles: a domain's own `bluebook/` folder holds exactly
three files with three different jobs — `.bluebook` (what the domain
IS), `.hecksagon` (how THIS deployment wires it), `.world` (what
values THIS deployment uses) — and ports/adapters live with the
library or a project's own `ports/`/`adapters/` folder, never inside a
domain's own folder. Everything below is what actually goes inside the
second and third of those three files.

## The declaration

This page wires `examples/pizzas/bluebook/pizzas.bluebook` — the same
domain [getting-started.md](getting-started.md) declares in full and
[commands.md](commands.md) exercises command by command, not repeated
here. Two pieces of it matter for what follows: the aggregate's own
name, and the policy sitting beside it that a driving port below ends
up triggering.

```ruby skip
aggregate "Order" do
  identified_by :name
  # ...
end

# A PAYMENT ARRIVING IS AN EXTERNAL FACT, NOT A DECISION THIS DOMAIN MAKES —
# the business rules stay on Purchase itself, reached only through this.
policy "OnPizzaPaymentReceived" do
  on "PizzaPaymentReceived"
  trigger "Order.Purchase"
end
```

Nothing in that file says Postgres, Memory, or anything else that
could answer `persisted_by`. That absence is not an oversight — it is
the entire reason a `.hecksagon` exists.

## Wiring it

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))

Hecks.hecksagon("Pizzas") do
  Pizzas::Order.persisted_by("Memory")

  # An event this hecksagon takes from OUTSIDE Pizzas' own bluebook —
  # see "subscribe", below.
  subscribe "IngredientShipmentReceived"

  # THE DRIVING PORT — called by a payment processor's webhook, never by
  # the domain itself. This is pizzas.hecksagon's own real
  # PaymentGateway/Receive (examples/pizzas/bluebook/pizzas.hecksagon),
  # reproduced here so this page can wire it against Memory rather than
  # the Postgres binding that file actually ships with.
  Pizzas::Order.port "PaymentGateway" do
    operation "Receive" do
      reference_to Order, as: :name
      attribute :customer_name, CustomerName
      attribute :amount, Price
      emits "PizzaPaymentReceived"
    end
  end
end
```

```ruby boot
Hecks.world("Pizzas") do
  realm "Examples"
  persisted_by("Memory")
end
```

Two files, three jobs done in them: `persisted_by` binds an aggregate
to an adapter; `port`/`operation` declares a boundary the domain will
listen through; `subscribe` names an event taken from elsewhere.
`.world` supplies the values a binding actually needs. Each one is walked through
separately below, live, against what just booted.

## Binding persistence, decided outside the domain

`persisted_by` is the whole syntax: an aggregate, a string naming an
adapter. Swap the string and the domain never learns — there is no
hook, no callback, nothing in `Pizzas::Order`'s own declaration
that could even ask which adapter answered:

```ruby
order = Order.create_pizza(name: { value: "Margherita" },
                            pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.status   # => "available"

order.add_topping(topping: { value: "Basil" }, amount: { value: 3 })
order.toppings.map(&:to_h)   # => [{ name: "Basil", amount: 3 }]
```

This page binds `Order` to Memory above because that is what it needs
to run without a database behind it. The exact same shape, unchanged,
already ships against a real one: `pizzas.hecksagon` itself binds
`Order` with `Pizzas::Order.persisted_by("Postgres")`, one line —
quoted here, not run, since this page does not require a database:

```ruby skip
Pizzas::Order.persisted_by("Postgres")
```

That is what "decided outside the domain" means in practice, not in
theory — a real file in this repository proves it.

## Driving ports

A `port` declared in the hecksagon is a second front door, for facts
that did not originate inside this domain at all — a payment
processor's webhook confirming a charge, not a chef ringing one up on
the menu. Read the inventory off `PaymentGateway`'s `Receive`
operation above, because it is the whole inventory: a `reference_to`
saying which record the fact is about, an `attribute` or two, an
`emits`. No `given`. No `then_set`. Those are not omissions made at
the authoring level — `DomainPortBuilder`/`PortOperationBuilder`
simply define no such methods, so there is nothing to reach for even
by mistake. A port operation TRANSLATES an external fact into this
domain's own event vocabulary; it does not hydrate a record, does not
mutate one, does not save. Whatever should happen next — crediting the
sale, flagging a mismatch — happens wherever a `policy` reacts to the
event this emits, exactly the way `pizzas.bluebook`'s
`OnPizzaPaymentReceived` reacts to `PizzaPaymentReceived`; wiring that
reaction is [policies-and-process-managers.md](policies-and-process-managers.md)'s job, not this page's.

Call it the way a real payment processor's webhook handler would —
through `dispatch_port`, never through the door a chef's own commands
use:

```ruby
events = runtime.dispatch_port("Pizzas", "Order", "PaymentGateway", "Receive",
                                name: order.id, customer_name: { value: "Chris" }, amount: { cents: 1200 })
events.map(&:name)   # => ["PizzaPaymentReceived"]
```

And here is the "no `then_set`" claim, not just asserted but shown:
`events` above holds exactly the one event `PaymentGateway`'s `Receive`
itself declares with `emits` — not `"PizzaPurchased"`, which belongs to
`Purchase`, never to the port that led to it. The port's own return
value proves it touched nothing beyond translating the call.

The order sold anyway — read it back:

```ruby
Order.find(order.id).status              # => "sold"
Order.find(order.id).customer_name.to_h  # => { value: "Chris" }
```

That mutation did not come from the port. It came from
`OnPizzaPaymentReceived`, wired in `pizzas.bluebook` itself, reacting
to the very event the port above just emitted and dispatching
`Purchase` — the same command, the same `given` guards, that a real
purchase flow would call directly. The reaction is on the record, not
just asserted:

```ruby
runtime.registry.reaction_log   # => [{ policy: "OnPizzaPaymentReceived", on: "PizzaPaymentReceived", trigger: "Pizzas::Order.Purchase", delivered: true }]
```

An external call came in shaped nothing like this domain's own
commands, and everything that happened because of it stayed exactly
where every other business rule in this language lives — in a command,
reached through a policy, never inside the port.

## `subscribe`

`subscribe "EventName"` inside a hecksagon names an event this
domain's own wiring takes in from OUTSIDE `Pizzas`' own bluebook —
`hecksagon_builder.rb`'s own comment on the method calls it exactly
that: an event this hecksagon takes from outside the domain's own
bluebook. It is declared the same way everything else in a hecksagon
is — read straight back off the registry once booted:

```ruby
runtime.registry.hecksagon("Pizzas").subscriptions   # => ["IngredientShipmentReceived"]
```

Nothing more is claimed for it than that. It is a fact recorded
at the deployment boundary, not a routing table this page can show
dispatching anything — if a feature needs a subscribed event to
actually trigger a reaction, that reaction is a `policy`, the same as
every other one.

## `.world`: per-deployment values

A `.hecksagon` says WHICH adapter. A `.world` says what THAT adapter
needs to actually run — values, and only values, checked against the
exact binding they answer:

```ruby
runtime.registry.world("Pizzas").realm                                  # => "Examples"
runtime.registry.world("Pizzas").for_binding("persisted_by", "Memory")  # => { adapter: "Memory" }
```

Memory needs nothing beyond its own name, which is why that block
above is one bare word. A real deployment binding to Postgres instead
carries the values Postgres actually declares — `database` and `role`,
the two fields `postgres.adapter` names, though a deployment only ever
supplies what it actually uses. This is not hypothetical for Pizzas
either — this is `examples/pizzas/bluebook/pizzas.world`, quoted
verbatim, not run here (`.world` files are never loaded through the
doctest boot path, only through a real `Hecks.boot`):

```ruby skip
Hecks.world "Pizzas" do
  realm "Examples"
  persisted_by("Postgres") do
    database "postgres://localhost/hecks_pizzas"
  end
end
```

## Writing your own port or adapter

Everything above reached for a port and an adapter the library already
ships (`persistence`, and `Memory`/`Postgres` answering it). A project
whose feature needs neither — a receipt printer, say — declares its
own the same two ways the library's own are said:

```ruby skip
Hecks.port "receipt" do
  verb "receipted_by"
end

Hecks.adapter "ThermalPrinter" do
  port   "receipt"
  field  :device_path
  secret :pairing_key
end
```

That declares "receipt" as a project-wide port — reusable by any
aggregate, worth its own file the moment more than one might bind it.
A port that belongs to exactly one aggregate does not need a file of
its own: the same `verb` word reached from *inside* the hecksagon,
right beside the aggregate it addresses, registers the identical
`IR::Port` — bound, verified, and settings-resolved exactly the same
way, just spelled where it is actually used instead of a level of
indirection away:

```ruby skip
Pizzas::Order.port "receipt" do
  verb "receipted_by"
end
```

Same name, same aggregate-scoped `port` call [Driving ports](#driving-ports)
above already reaches for `operation` — a port is one shape or the
other, `verb` or `operation`, never both. `Hecks.adapter
"ThermalPrinter"` does not change at all; an adapter names the port it
answers by string (`port "receipt"`), and does not care which of the
two ways that port was declared.

[writing-an-adapter.md](writing-an-adapter.md) is where that contract lives in full — what
`field` versus `secret` actually buys you, what a driven adapter must
implement, how a driving one calls back in. Reach for the library's
own port before inventing a new one; a new port is a bigger decision
than a new adapter, because every future adapter answering it inherits
the shape you chose today.

## Fields belong to the adapter, not the port

One rule worth carrying forward from `README.md`'s own wording: fields
belong to the **adapter**, not the port. `Postgres` and `Memory` both
answer `persistence`, and they genuinely need different things —
`database`, in Postgres's case; nothing at all, in Memory's. A
`.world` block is checked against exactly what the named adapter
declares, so a value it does not know is refused at boot, not silently
dropped. Get a field name wrong in a real `pizzas.world` and you find
out before the kitchen ever opens, not the first time a customer tries
to buy a pizza against it.
