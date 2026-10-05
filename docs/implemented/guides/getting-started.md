# Getting started

This guide shows the whole shape of the language in one sitting — a
domain declared, wired, booted, and refused. It is not a tour of
features, but one small thing, done completely.

First, what is being shown. A `.bluebook` file declares a business
domain — its aggregates, their rules, what they may do and what they
must refuse — and the runtime boots that declaration directly. There is
no handler body anywhere, no class to write, no schema to migrate.
The domain is data. Everything this project can do — diff a domain,
store it, translate it across versions, verify it statically — follows
from that one choice: if it is data, it can be read, and what can be
read can be checked.

## What you need

hecks is published as the `hecks` gem, and the gem carries the pizzas example
this guide walks through:

```sh
gem install hecks
hecks console   # boots the pizzas example this guide walks through
```

From a clone of the repository, which also holds the other examples and the
sources, it is `bundle install` and then `bundle exec hecks console`.

No database server is needed. The console loads pizzas on the in-memory
adapter and keeps hecks's own journal in memory too. To open another domain, add `subject=<domain>`, for
example `subject=examples/banking`, which is bound to the Heki file
adapter and writes into git-tracked files under `examples/banking/data/`.
See [Schema evolution](schema-evolution.md) for when Postgres earns its
place.

## The first declaration

The following example declares a domain about selling pizzas. It is
small enough to review in full, and demonstrates both what the
language allows and what it refuses. It is, in fact, the same
`pizzas.bluebook` that console already boots for you.

```ruby bluebook
Hecks.bluebook "Pizzas" do
  vision "Put toppings on a pizza and sell it to a customer."
  supporting

  aggregate "Order" do
    description "An order that gathers toppings on a pizza and is eventually sold to a customer."

    identified_by :name

    attribute :name,          PizzaName
    attribute :pizza,         Pizza
    attribute :toppings,      list_of(Topping)
    attribute :customer_name, CustomerName

    value_object "PizzaName" do
      attribute :value, String, pattern: '[^ \t\n\r]'
      invariant("a pizza is named") { !value.to_s.empty? }
    end

    value_object "Price" do
      attribute :cents, Integer
      invariant("a price is never negative") { cents >= 0 }
    end

    value_object "CustomerName" do
      attribute :value, String, pattern: '[^ \t\n\r]'
      invariant("a customer is named") { !value.to_s.empty? }
    end

    value_object "ToppingName" do
      attribute :value, String, pattern: '[^ \t\n\r]'
      invariant("a topping is named") { !value.to_s.empty? }
    end

    value_object "ToppingAmount" do
      attribute :value, Integer
      invariant("an amount is positive") { value.positive? }
    end

    value_object "Topping" do
      attribute :name,   String, pattern: '[^ \t\n\r]'
      attribute :amount, Integer
    end

    value_object "Size" do
      attribute :value, String, one_of: ["small", "large"]
    end

    value_object "Pizza" do
      attribute :price_cents, Price
      attribute :size,        Size
    end

    lifecycle :status, default: "available" do
      transition "Purchase" => "sold", from: "available"
    end

    command "CreatePizza" do
      role "Chef"
      goal "Put a new pizza on the menu"

      attribute :name,  PizzaName
      attribute :pizza, Pizza

      emits "PizzaCreated"
    end

    command "AddTopping" do
      role "Chef"
      goal "Customize a pizza with an ingredient"

      reference_to Order
      attribute :topping, ToppingName
      attribute :amount, ToppingAmount

      given("a sold pizza cannot be changed") { status == "available" }
      given("at most 10 toppings")            { toppings.size < 10 }

      sets :toppings, append: { name: :topping, amount: :amount }

      emits "ToppingAdded"
    end

    command "Purchase" do
      role "Customer"
      goal "Buy the pizza"

      reference_to Order
      attribute :customer_name, CustomerName
      attribute :amount, Price

      given("a pizza needs at least one topping") { toppings.size.positive? }
      given("it must still be available")         { status == "available" }
      given("a payment was actually made")         { amount.cents.positive? }

      sets :customer_name

      emits "PizzaPurchased"
    end
  end
end
```

Read it once as prose before you read it as code. An aggregate is the
thing with identity — two orders named `"Margherita"` ARE the same
order, which is exactly what `identified_by :name` declares.
A value object has no identity at all; a `PizzaName` is only its
value, and its invariant travels with it everywhere the value goes.
The lifecycle names the states an order may hold and the one
transition between them. And every command says three things: what it
needs, what it refuses (`given`), and what it announces (`emits`). A
command has no additional responsibilities beyond these three.

## Wiring

The declaration says nothing about storage, deliberately. Where a
domain's state lives is a decision, and decisions are made in the
`.hecksagon` — one line here:

```ruby boot
Hecks.hecksagon("Pizzas") do
  attaches "Governance"
  Pizzas::Order.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

Memory for now. The same domain binds to SQLite or Postgres by changing
this one word, and the domain never learns which was chosen.

### Try it: keep the pizzas in a SQLite file

SQLite needs no server, so it is the quickest way to see data survive a
restart. Copy `examples/pizzas` somewhere you can write, then change two
files in the copy. In `bluebook/pizzas.hecksagon`, bind the aggregate to
`SqlitePersistence` (the adapter's name) and leave Governance on Memory:

```
Pizzas::Order.persisted_by("SqlitePersistence")
```

The hecksagon says *which* adapter. The *where* is a per-deployment value,
so it goes in `bluebook/pizzas.world`, which currently holds only the
realm:

```
Hecks.world "Pizzas" do
  realm "Examples"
  persisted_by("SqlitePersistence") do
    database "data/pizzas.db"
  end
end
```

A relative `database` path resolves against the domain directory, and the
file is created on first boot. Boot the copy, create an order, and quit.
Boot it again and `Order.all` still holds the order. The domain files
are the same as before; only the wiring changed. Run it with
`bundle exec hecks console subject=<your copy>`.

## Using it

Booting installs the door — your aggregates arrive as plain Ruby
constants, a creating command as a module method, everything else as a
method on the record in hand:

```ruby
order = Order.create_pizza!(name: "Margherita",
                            pizza: { price_cents: { cents: 1200 }, size: "large" })

order.status                   # => "available"
order.toppings                 # => []
```

Commands return the record, so calls can be chained in sequence:

```ruby
order.add_topping!(topping: "Basil", amount: 3)
order.purchase!(customer_name: "Chris", amount: { cents: 1200 })

order.status                   # => "sold"
order.toppings.map(&:to_h)     # => [{ name: "Basil", amount: 3 }]
order.events.map(&:name)       # => ["PizzaCreated", "ToppingAdded", "PizzaPurchased"]
```

A value object with a single attribute takes a bare scalar: `name:
"Margherita"` fills its one `value` field. The object form is equivalent,
so `name: { value: "Margherita" }` does the same thing; you need it when the
value object has several fields, as `pizza:` does (`price_cents` and
`size`).

Notice what you did not write: no `save`, no repository call, no id
passed by hand. Identity was declared once, and the door carries it.

## The refusals

Now the half of the language most systems treat as an afterthought.
Try to add a topping to the pizza you just sold:

```ruby
order.add_topping!(topping: "Late", amount: 1)   # ~> GivenNotMet: a sold pizza cannot be changed
```

And try to put a nameless pizza on the menu:

```ruby
Order.create_pizza!(name: "", pizza: { price_cents: { cents: 1200 }, size: "large" })   # ~> TypeMismatch: PizzaName.value must match [^ \t\n\r], got ""
```

Two different refusals, and the difference matters. The `given` is the
command's own rule — it reads the aggregate's state and says no on its
behalf. `PizzaName`'s `pattern:` is the value object's rule — it
travels with `PizzaName` into every command that carries one, declared
once, enforced everywhere, and checked ahead of `PizzaName`'s own
hand-written "a pizza is named" invariant (attribute coercion runs
before invariants, so a blank name never reaches it). Neither is an
exception in the Ruby sense. A refusal is the domain saying no, in
words declared for it, and the runtime treats it as half of what the
domain means.

Every example on this page is executed against the real runtime by
`spec/guides_spec.rb`, including the assertions and refusals. This
guide cannot drift from the language, because the suite fails the
moment it does. Documentation that is not tested can drift from the
implementation; every example here is tested.

## Where to go next

- **[Your own domain](your-own-domain.md)** — write a bluebook of
  your own, run it, and deploy it to AWS Lambda.
- **[Aggregates and value objects](aggregates-and-value-objects.md)** —
  identity in full, composite keys, defaults, patterns, closed sets,
  references between aggregates.
- **[Commands](commands.md)** — everything a command may do and refuse,
  including postconditions.
- **[Wiring](wiring.md)** — the hecksagon and world in full: adapters,
  ports, per-deployment values.
- **[Schema evolution](schema-evolution.md)** — what happens when a
  domain's shape changes and its data must survive; the reason
  Postgres earns its place.
