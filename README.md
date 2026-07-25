# hecksagain

Hecks, rewritten — with **Ruby as the source of truth**.

## The thesis

In Hecks the parser is authored twice: once as a Ruby DSL, once as a Rust
parser, kept in step by a parity suite. Every drift retired over the last months
was a disagreement between those two authors — never a routing disagreement,
because routing was already data.

So hecksagain inverts the direction. Ruby holds the semantics. **Rust becomes a
projection** — except the interpreter, which stays hand-written and small.

One author. Nothing to be at parity with.

## The build chain

```
  Ruby domain semantics          ← the only hand-authored source
         ↓
  IR (plain, serialisable)       ← lib/hecksagain/ir
         ↓
  projections                    ← SQL schema today ; Rust next
         ↓
  Futamura                       ← interpreter + program → specialised program
```

The SQLite adapter is the first projection already in place: its table schema
is derived from the aggregate IR, never hand-written. Same move, smaller scale.

## Try it

```sh
bin/console
```

```ruby
pizza = runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", price_cents: 1200)
runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Basil", amount: 3)
runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

runtime.events.last
# => PizzaPurchased(Pizzas::Pizza#pizza-015d2d15) {:id=>"...", :customer_name=>"Chris"}
```

## The folder convention

A domain is a directory with a `bluebook/` folder holding every declaration:

```
examples/pizzas/
  bluebook/
    persistence.family     the how-verb vocabulary (persisted_by, :reply)
    sqlite.adapter         the inverted arrow — adapter declares its family
    pizzas.bluebook        the domain
    pizzas.hecksagon       the wiring — Pizzas::Pizza.persisted_by("Sqlite")
    pizzas.world           the per-deployment values
  data/
    pizzas.db
```

Load order is dependency order, not alphabetical: families and adapters first so
binds can type-check, then the domain, the wiring, the values.

## The shape

- **An aggregate IS the port.** Its commands-in and events-out are the whole
  contract ; a port is never declared separately.
- **A family names a how-verb**, a signal, and config field *names*. It never
  names its adapters — the adapter declares the family, so a new backend is
  purely additive.
- **A bind resolves only if the adapter's family carries the verb.** That check
  runs for every bind at boot, so a misconfiguration fails on line one.
- **Commands are declared, never scripted.** `given` guards, `then_set`
  mutates, `emits` announces. There is no handler body anywhere in this
  codebase — which is exactly what makes the same declaration projectable.
- **Events are emitted last**, after the state is persisted. An event is a
  promise that the state behind it survived.

## Status

First vertical slice. Pizzas boots, guards bite, value-object invariants hold,
state survives a reboot on SQLite.

```sh
rspec        # 16 examples, 0 failures, ~0.04s
```

Carried over from Hecks so far: the bluebook folder convention, the
family/adapter/bind vocabulary, the hexagon shape, and the Pizzas example. Not
carried over: the second parser, the parity suite, and the 903 Ruby files that
would have made this not a clean slate.
