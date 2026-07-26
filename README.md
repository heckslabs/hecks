# hecksagain

Hecks, rewritten — with **Ruby as the source of truth**.

## The thesis

In Hecks the parser is authored twice: once as a Ruby DSL, once as a Rust
parser, kept in step by a parity suite. Every drift retired over the last
months was a disagreement between those two authors — never a routing
disagreement, because routing was already data.

So hecksagain inverts the direction. Ruby holds the semantics. **Rust becomes a
projection** — except the interpreter, which stays hand-written and small.

One author. Nothing to be at parity with.

```
  regular Ruby  →  extraction  →  IR  →  Rust / SQL / anything
```

The arrow only runs one way. The IR is extracted FROM Ruby ; Ruby is never
generated from the IR.

## Try it

```sh
bin/console
```

Booting constructs the classes, so a domain is just Ruby:

```ruby
pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
pizza.add_topping(name: "Basil", amount: 3)
pizza.purchase(customer_name: "Chris")

pizza.status        # => "sold"
pizza.events.last   # => PizzaPurchased(Pizzas::Pizza#pizza-085a6ecc)

Pizza.count         # => 1
Pizza.find(pizza.id)
```

A creating command is a class method and returns the new record. A command that
references its aggregate is an instance method — identity is already known, so
it is never passed by hand — and returns self, so commands chain. Dispatch is
plumbing; nobody writing a domain should ever type it.

## Two runtimes, one answer

```sh
bin/parity
#   AGREED — ruby and rust returned the same answer for every step
```

Ruby parses the bluebook and exports an IR ; Rust currently reads that IR.

**That is a scaffold, not the destination.** Both runtimes should parse the
native `.bluebook` format — and since a `.bluebook` file is already Ruby, the
parseable subset and the evaluable subset turn out to be the same question. The
JSON handover exists because it made semantic parity provable early, and it
retires when the Rust parser lands.

The mistake this project exists to avoid is not *two parsers*. It is two
parsers **authored twice by hand**, held together by a suite that can only
detect drift after the fact. A Rust parser that is a *projection* of the Ruby
one is a different thing: one author, two artifacts. Rust is a projection,
except the interpreter.

The harness runs successes and every refusal path, because a runtime that
ACCEPTS what the other refuses is the failure most worth catching. Only JSON
key order is normalised before diffing (key order is not semantics); final
state, event order, and refusal wording all have to match on their own.

## The expression sublanguage

Everything in a command was already data except the predicate — and a `Proc`
crosses no language boundary. So predicates are **extracted**, not closed over.
Ruby 3.3 ships Prism, so the developer's actual source is parsed by Ruby's own
parser and lowered to canonical text:

```ruby
given("at most 10 toppings") { toppings.size < 10 }
                     ↓
            "toppings.size < 10"
```

The Ruby stays exactly as written. What changed is that it is now *read* as
well as run — and **both runtimes evaluate the text**, because a Ruby running a
closure while Rust runs text agrees only by luck.

The admissible subset is conceived in
[`lib/hecksagain/grammar/expression.bluebook`](lib/hecksagain/grammar/expression.bluebook)
and bounded by what the interpreter floor can evaluate:

```
||  →  &&  →  .include?  →  >= <= < > == !=  →  leaves
```

Leaves are literals, dotted value-object paths, `.size`/`.length`,
`.positive?`/`.negative?`/`.zero?`, and `.modulo(n)`. An operator is admitted
only once it reads in EVERY target — one with no Rust rendering is not a slow
operator, it is not an operator.

## The folder convention

A domain's `bluebook/` folder holds only what is **its own**:

```
examples/pizzas/
  bluebook/
    pizzas.bluebook        the domain
    pizzas.hecksagon       the wiring — Pizzas::Pizza.persisted_by("Sqlite")
    pizzas.world           the per-deployment values
  data/
```

Ports and adapters are **not** in there. They are the two halves of the
inverted arrow, and each ships with the library beside its implementation:

```
lib/hecksagain/ports/
  persistence.port         the PORT — the how-verb and the signal
lib/hecksagain/adapters/
  sqlite.adapter           the DECLARATION — its port, and the config it needs
  sqlite.rb                the IMPLEMENTATION — the same thing said in Ruby
  memory.adapter
  memory.rb
```

A declaration and its implementation are one thing described two ways, so they
live together. A project bringing its **own** port or adapter puts them in a
`ports/` or `adapters/` folder above its domains, found by walking up — the
library's load first, so a project's can only add, never silently replace.

Fields belong to the **adapter**, not the port. Adapters implementing one port
genuinely differ — Sqlite needs a `database`, Memory nothing at all — and the
`.world` block is checked against what that adapter declares, so a value it does
not know is refused at boot rather than ignored.

Load order is dependency order, not alphabetical: ports declare the verb, an
adapter declares a port, the hecksagon names both, the world supplies values.

## The library

```
lib/hecksagain/
  bluebook/     dsl → ir → expression.  WHAT A BLUEBOOK IS.
  runtime/      dispatch, instances, the registry.  RUNNING IT.
  adapters/     sqlite, memory.
  projector/    the IR exporter, and whatever targets follow.  SENDING IT ELSEWHERE.
```

The split follows the dependency direction rather than the topic. The
expression evaluator is in `bluebook/` and not `projector/` because the Ruby
runtime evaluates every given and every invariant through it — it is the
semantic core, and Rust is merely the first thing to read it.

## The shape

- **An aggregate IS the port**, and the hexagon wires the real class —
  `Pizzas::Pizza.persisted_by("Sqlite")` is a genuine method call.
- **A family names a how-verb**, a signal, and config field *names*. It never
  names its adapters — the adapter declares the family, so a new backend is
  purely additive.
- **A bind resolves only if the adapter's family carries the verb**, checked for
  every bind at boot.
- **Commands are declared, never scripted.** `given` guards, `then_set`
  mutates, `emits` announces. No handler body exists anywhere — which is what
  makes the same declaration projectable.
- **Events are emitted last**, after the state is persisted. An event is a
  promise that the state behind it survived.
- **The SQLite schema is projected from the IR** — one column per attribute,
  lists as JSON, never hand-written.

## Verify

```sh
rspec                  # 41 examples — the Ruby side
(cd projection/rust && cargo test) # 11 tests — the Rust half of the sublanguage contract
bin/parity             # the two runtimes agree
```

Every Rust interpreter test has a named Ruby twin. The sublanguage is specified
once and implemented twice, so each implementation needs its own tests or the
second is only believed rather than known.
