# Wiring

You already have a domain that boots in memory and refuses correctly —
`getting-started.md` or `commands.md` got you there. That domain does
not yet know where its records will actually live when someone other
than you is running it, and it should not: a bluebook that named its
own database would be a bluebook that lied the day you changed
providers. This page is where that knowledge lives instead — the
`.hecksagon` and the `.world` — and it is where you make the decisions
a shipped feature cannot leave unmade: which adapter holds each
aggregate, what an outside fact has to look like before this domain
will listen to it, and which values differ from one deployment to the
next. *Le fond des choses* : the domain says WHAT: the wiring says
WHERE, and neither file is allowed to say the other's part.

## The folder convention, briefly

`README.md`'s own **folder convention** section is the source of
truth here and I am not going to repeat it — read it if you have not.
The shape it settles: a domain's own `bluebook/` folder holds exactly
three files with three different jobs — `.bluebook` (what the domain
IS), `.hecksagon` (how THIS deployment wires it), `.world` (what
values THIS deployment uses) — and ports/adapters live with the
library or a project's own `ports/`/`adapters/` folder, never inside a
domain's own folder. Everything below is what actually goes inside the
second and third of those three files.

## The declaration

A shop counter. One till, one drawer, one card terminal bolted to it —
small enough to wire end to end in one sitting.

```bluebook
Hecks.bluebook "Comptoir" do
  vision "One counter, one drawer of cash, and a payment terminal bolted to the till."
  supporting

  aggregate "Counter" do
    description "A single counter's cash drawer, open for the day and rung up sale by sale."

    identified_by { label.value }

    attribute :label,   CounterLabel
    attribute :balance, Amount

    value_object "CounterLabel" do
      attribute :value, String
      invariant("a counter is labelled") { !value.to_s.empty? }
    end

    value_object "Amount" do
      attribute :cents, Integer, default: 0
      invariant("an amount is never negative") { cents >= 0 }
    end

    command "Open" do
      role "Cashier"
      goal "Start a counter for the day"

      attribute :label, CounterLabel

      emits "Opened"
    end

    command "RecordSale" do
      role "Cashier"
      goal "Ring up a sale at the counter"

      reference_to Counter
      attribute :amount, Amount

      given("a sale is never free") { amount.cents.positive? }

      then_set :balance, increment: :amount

      emits "SaleRecorded"
    end
  end
end
```

Nothing in that file says Postgres, Memory, or anything else that
could answer `persisted_by`. That absence is not an oversight — it is
the entire reason a `.hecksagon` exists.

## Wiring it

```ruby boot
Hecks.hecksagon("Comptoir") do
  Comptoir::Counter.persisted_by("Memory")

  # An event this hecksagon takes from OUTSIDE Comptoir's own bluebook —
  # see "subscribe", below.
  subscribe "SupplierInvoiceSettled"

  # THE DRIVING PORT — called by a card terminal outside this domain
  # entirely, never by the domain itself. Pizzas' PaymentGateway/Receive
  # (examples/pizzas/bluebook/pizzas.hecksagon) is the precedent this
  # shape follows.
  Comptoir::Counter.port "CardReader" do
    operation "Confirm" do
      reference_to Counter, as: :label
      attribute :amount, Amount
      emits "CardPaymentConfirmed"
    end
  end
end
```

```ruby boot
Hecks.world("Comptoir") do
  realm "RiveGauche"
  persisted_by("Memory")
end
```

Two files, three jobs done in them: `persisted_by` binds an aggregate
to an adapter; `port`/`operation` declares a boundary the domain will
listen through; `subscribe` names an event taken from elsewhere.
`.world` supplies the values a binding actually needs. I will walk
each one separately, live, against what just booted.

## Binding persistence, decided outside the domain

`persisted_by` is the whole syntax: an aggregate, a string naming an
adapter. Swap the string and the domain never learns — there is no
hook, no callback, nothing in `Comptoir::Counter`'s own declaration
that could even ask which adapter answered:

```ruby
counter = Comptoir::Counter.open(label: { value: "Comptoir-1" })
counter.balance.to_h   # => { cents: 0 }

counter.record_sale(amount: { cents: 500 })
counter.balance.to_h   # => { cents: 500 }
```

`Comptoir` binds to Memory above because that is what this page needs
to run without a database behind it. The exact same shape, unchanged,
already ships against a real one: `pizzas.hecksagon` binds `Order`
with `Pizzas::Order.persisted_by("Postgres")`, one line, and
`pizzas.bluebook` did not change a single character to make that true.
That is what "decided outside the domain" means in practice, not in
theory — a real file in this repository proves it.

## Driving ports

A `port` declared in the hecksagon is a second front door, for facts
that did not originate inside this domain at all — a card terminal
confirming a charge, not a cashier ringing one up. Read the inventory
off `CardReader`'s `Confirm` operation above, because it is the whole
inventory: a `reference_to` saying which record the fact is about, an
`attribute` or two, an `emits`. No `given`. No `then_set`. Those are
not omissions I chose — `DomainPortBuilder`/`PortOperationBuilder`
simply define no such methods, so there is nothing to reach for even
by mistake. A port operation TRANSLATES an external fact into this
domain's own event vocabulary; it does not hydrate a record, does not
mutate one, does not save. Whatever should happen next — crediting the
sale, flagging a mismatch — happens wherever a `policy` reacts to the
event this emits, exactly the way `pizzas.bluebook`'s
`OnPizzaPaymentReceived` reacts to `PizzaPaymentReceived`; wiring that
reaction is `policies-and-process-managers.md`'s job, not this page's.

Call it the way a real card terminal's webhook handler would — through
`dispatch_port`, never through the door a cashier's own commands use:

```ruby
events = runtime.dispatch_port("Comptoir", "Counter", "CardReader", "Confirm",
                                label: counter.id, amount: { cents: 500 })
events.map(&:name)   # => ["CardPaymentConfirmed"]
```

And here is the "no `then_set`" claim, not just asserted but shown:
the counter's balance is exactly what `record_sale` left it at, one
sale's worth, not two — the port never touched it:

```ruby
Comptoir::Counter.find(counter.id).balance.to_h   # => { cents: 500 }
```

## `subscribe`

`subscribe "EventName"` inside a hecksagon names an event this
domain's own wiring takes in from OUTSIDE `Comptoir`'s own bluebook —
`hecksagon_builder.rb`'s own comment on the method calls it exactly
that: an event this hecksagon takes from outside the domain's own
bluebook. It is declared the same way everything else in a hecksagon
is — read straight back off the registry once booted:

```ruby
runtime.registry.hecksagon("Comptoir").subscriptions   # => ["SupplierInvoiceSettled"]
```

I am not going to claim more for it than that. It is a fact recorded
at the deployment boundary, not a routing table this page can show you
dispatching anything — if your feature needs a subscribed event to
actually trigger a reaction, that reaction is a `policy`, the same as
every other one.

## `.world`: per-deployment values

A `.hecksagon` says WHICH adapter. A `.world` says what THAT adapter
needs to actually run — values, and only values, checked against the
exact binding they answer:

```ruby
runtime.registry.world("Comptoir").realm                                  # => "RiveGauche"
runtime.registry.world("Comptoir").for_binding("persisted_by", "Memory")  # => { adapter: "Memory" }
```

Memory needs nothing beyond its own name, which is why that block
above is one bare word. A real deployment binding to Postgres instead
carries the values Postgres actually declares — `database`, `role`,
the same two fields `postgres.adapter` names and nothing more. This is
what `comptoir.world` would hold on disk (not run here — `.world`
files are never loaded through the doctest boot path, only through a
real `Hecks.boot`):

```
Hecks.world "Comptoir" do
  realm "RiveGauche"
  persisted_by("Postgres") do
    database "postgres://localhost/hecks_comptoir"
    role     "app"
  end
end
```

## Writing your own port or adapter

Everything above reached for a port and an adapter the library already
ships (`persistence`, and `Memory`/`Postgres` answering it). A project
whose feature needs neither — a receipt printer at the counter, say —
declares its own the same two ways the library's own are said:

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

`writing-an-adapter.md` is where that contract lives in full — what
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
dropped. Get a field name wrong in a real `comptoir.world` and you
find out before the counter ever opens, not the first time someone
tries to record a sale against it.

— Miette
