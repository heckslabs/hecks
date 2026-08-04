# hecksagain

A `.bluebook` file declares a business domain — aggregates, value objects,
commands, invariants — and the runtime boots it. Nothing in a domain is
scripted: `given` guards, `then_set` mutates, `emits` announces, and no
handler body exists anywhere. That is the load-bearing choice everything else
follows from: a domain that is entirely **data** can be diffed, stored,
translated across versions, and projected into another language.

One runtime reads the file: **Ruby holds the semantics.** A parallel Rust
runtime existed for a while, kept honest against Ruby by a full
differential-testing harness — retired now, and [its own section
below](#a-single-runtime) says why.

## Try it

```sh
bin/console
```

Booting installs the door, so a domain is just Ruby:

```ruby
order = Order.create_pizza(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.add_topping(topping: { value: "Basil" }, amount: { value: 3 })
order.purchase(customer_name: { value: "Chris" }, amount: { cents: 1200 })

order.status        # => "sold"
order.events.last   # => PizzaPurchased(Pizzas::Order#Margherita)

Order.count         # => 1
Order.find(order.id)
```

A creating command is a module method and returns the new record in hand. A
command that references its aggregate is a method on that record — identity is
already known, so it is never passed by hand — and returns self, so commands
chain. Dispatch is plumbing; nobody writing a domain should ever type it. (No
domain classes exist behind this: the door is a per-boot facade of modules
closing over the dispatcher, and the IR is the only graph the runtime runs.)

For scripted runs, `bin/run <domain> <script.json>` executes a step list —
commands and queries — and reports events, refusals, and rows. `bin/fuzz`
generates and runs these scripts itself, checking declared properties instead
of a scripted expectation.

## Writing a bluebook

```ruby
Hecks.bluebook "TillRoom" do
  vision "A till takes money in and gives money out, and the drawer count is arithmetic — never a guess."

  aggregate "Till" do
    identified_by { number.value }

    attribute :number,  TillNumber
    attribute :balance, Money, default: { cents: 0 }
    attribute :marks,   list_of(Mark)

    value_object "Money" do
      attribute :cents, Integer
      invariant("a cash amount is never negative") { cents >= 0 }
    end

    command "TakeIn" do
      role "Clerk"
      goal "Add cents to the drawer"

      reference_to Till
      attribute :amount, Money

      then_set :balance, increment: :amount
      then_set :marks,   append: { amount: :amount, direction: "in" }

      emits "TakenIn"
    end
  end
end
```

Everything a command may do is one of a closed set of declared effects, and
everything it may refuse is a named `given` or `invariant`. Refusals are not
exceptions; they are half the language, and the corpus scripts under
`spec/corpus/` exercise every one of them — a runtime that ACCEPTS what the
corpus says must be refused is the failure most worth catching.

A required attribute missing from a payload is refused at the gate, before any
effect resolves. Events are emitted last, after the state is persisted: an
event is a promise that the state behind it survived.

## The expression sublanguage

Everything in a command was already data except the predicate — and a `Proc`
crosses no language boundary. So predicates are **extracted**, not closed
over. The developer's actual source is parsed by Prism, Ruby's own parser, and
lowered to canonical text:

```ruby
given("at most 10 toppings") { toppings.size < 10 }
                     ↓
            "toppings.size < 10"
```

The Ruby stays exactly as written. What changed is that it is now *read* as
well as run — the canonical text is what makes a `given` a storable,
diffable FACT rather than a closure that can only ever be executed, the
same reason the domain as a whole is data (see the opening paragraph).

The admissible subset is conceived in
[`lib/hecksagain/grammar/expression.bluebook`](lib/hecksagain/grammar/expression.bluebook)
and bounded by what the interpreter floor can evaluate:

```
||  →  &&  →  .include?  →  >= <= < > == !=  →  leaves
```

Leaves are literals, dotted value-object paths, `.size`/`.length`,
`.positive?`/`.negative?`/`.zero?`, and `.modulo(n)`. An operator is admitted
only once it reads as a real rendering — an operator with no rendering is
not a slow operator, it is not an operator. That sentence is checked, not
aspired to: every operator the evaluator runs passes through the grammar
chapter's own Admit gate on each suite run
(`lib/hecksagain/grammar/expression_operators.json`, held by
`spec/operator_conformance_spec.rb`).

## The folder convention

A domain's `bluebook/` folder holds only what is **its own**:

```
examples/pizzas/
  bluebook/
    pizzas.bluebook        the domain
    pizzas.hecksagon       the wiring — Pizzas::Order.persisted_by("Postgres")
    pizzas.world           the per-deployment values
  data/
```

Ports and adapters are **not** in there. They are the two halves of the
inverted arrow, and each ships with the library beside its implementation:

```
lib/hecksagain/ports/            the PORT — the how-verb and the signal
lib/hecksagain/adapters/driven/
  sqlite.adapter                 the DECLARATION — its port, and the config it needs
  sqlite.rb                      the IMPLEMENTATION — the same thing said in Ruby
  memory.* heki.* postgres.* folder.* prism.*
```

A declaration and its implementation are one thing described two ways, so they
live together. A project bringing its **own** port or adapter puts them in a
`ports/` or `adapters/` folder above its domains, found by walking up — the
library's load first, so a project's can only add, never silently replace.

Fields belong to the **adapter**, not the port. Adapters implementing one port
genuinely differ — Sqlite needs a `database`, Memory nothing at all — and the
`.world` block is checked against what that adapter declares, so a value it
does not know is refused at boot rather than ignored. Persisted schemas are
projected from the IR — one column per attribute, lists as JSON, never
hand-written.

## Domain versions

A domain's shape changes; its stored history doesn't get to. On Postgres a
booted domain carries an **era**: the source text it was born from is held,
drift between held text and booting text is refused, and a deliberate change
ships with a translation — `rename`, `convert`, `drop`, `retype`, `retired`,
and `compute` rules in a `translations/*.bluebook` file — that carries the old
era's records into the new shape. `compute` is a raw SQL expression on
purpose: evaluated inside Postgres, it needs no second, application-side copy
of the same logic to drift from.

Eras are a Postgres concern only. Memory, Sqlite, and Heki carry no era
concept at all — a domain there boots the text it is handed.

## Language versions

The language applies the same discipline to itself. Every word of the
bluebook surface carries a lifecycle in `syntax.bluebook` — proposed,
admitted, deprecated, retired — and a proposed or retired word reaches no
projected parser table: to a projected reader it does not exist. A renamed
word keeps its old spelling in `was:`, and the old spelling parses forever
(`sets` is the word; `then_set` is the era the whole
corpus was written under, and the corpus still boots). The chapter declares
its own version, and `bin/evolve` walks a change through the stations —
snapshot, rewrite, regenerate, gate, restore-on-red.

## The library

```
lib/hecksagain/
  language/     the language, declared in its own bluebooks.  WHAT A BLUEBOOK IS.
  grammar/      the expression and translation sublanguages, and the Admit gate.
  bluebook/     dsl → ir → expression.  READING ONE.
  runtime/      dispatch, instances, the registry.  RUNNING IT.
  adapters/     driven: memory, sqlite, heki, postgres, folder, prism.
  translation/  domain-version translation — eras and lineage.
  projector/    IR export, for tooling and inspection (bin/ir).
```

The split follows the dependency direction rather than the topic. The
expression evaluator lives in the semantic core, not `projector/`, because
the runtime evaluates every given and every invariant through it directly.

## A single runtime

This project ran a parallel hand-written Rust implementation for a while,
kept honest against Ruby by a full differential-testing harness
(`bin/parity`). That's retired now — see
[`docs/rust-experiment.md`](docs/rust-experiment.md) for what it found and
why: the domain's structure (aggregates, commands, rules, shapes) is
genuinely declarative and belongs in `.bluebook`, judged by the self-hosted
grammar in `lib/hecksagain/language/bluebook/`; the empirical half (actual
parsing, actual dispatch, actual I/O) resisted that treatment and had to be
hand-duplicated, which is where the project's cost concentrated without a
matching return. One runtime now, and the `.bluebook` DSL keeps doing
exactly what it was already good at.

## Verify

```sh
bundle exec rspec   # the whole suite
bin/model_check     # static analysis over the IR — unreachable states, dead transitions
bin/fuzz            # generated sequences, checked against declared properties
```
