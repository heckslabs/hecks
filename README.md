# hecksagain

A `.bluebook` file declares a business domain — aggregates, value objects,
commands, invariants — and the runtime boots it. Nothing in a domain is
scripted: `given` guards, `then_set` mutates, `emits` announces, and no
handler body exists anywhere. That is the load-bearing choice everything else
follows from: a domain that is entirely **data** can be diffed, stored,
translated across versions, and projected into another language.

Two runtimes read the same file. **Ruby holds the semantics.** Rust runs the
same domains from a projection minted out of the language's own
self-description — how far that projection reaches today, and what stays
hand-written on purpose, is [its own section below](#the-rust-projection).
`bin/parity` is what makes every claim in this file real:

```
  a .bluebook  →  Ruby runtime  ┐
                                ├─→  must agree, or it is a SPLIT
  the same file →  Rust runtime ┘
```

## Try it

```sh
bin/console
```

Booting installs the door, so a domain is just Ruby:

```ruby
pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
pizza.add_topping(name: "Basil", amount: 3)
pizza.purchase(customer_name: "Chris")

pizza.status        # => "sold"
pizza.events.last   # => PizzaPurchased(Pizzas::Pizza#pizza-085a6ecc)

Pizza.count         # => 1
Pizza.find(pizza.id)
```

A creating command is a module method and returns the new record in hand. A
command that references its aggregate is a method on that record — identity is
already known, so it is never passed by hand — and returns self, so commands
chain. Dispatch is plumbing; nobody writing a domain should ever type it. (No
domain classes exist behind this: the door is a per-boot facade of modules
closing over the dispatcher, and the IR is the only graph the runtime runs.)

For scripted runs, `bin/run <domain> <script.json>` executes a step list —
commands and queries — and reports events, refusals, and rows. It is the same
entry `bin/parity` drives.

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
exceptions; they are half the language, and the parity harness runs every one
of them — a runtime that ACCEPTS what the other refuses is the failure most
worth catching.

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
well as run — and **both runtimes evaluate the text**, because a Ruby running
a closure while Rust runs text agrees only by luck.

The admissible subset is conceived in
[`lib/hecksagain/grammar/expression.bluebook`](lib/hecksagain/grammar/expression.bluebook)
and bounded by what the interpreter floor can evaluate:

```
||  →  &&  →  .include?  →  >= <= < > == !=  →  leaves
```

Leaves are literals, dotted value-object paths, `.size`/`.length`,
`.positive?`/`.negative?`/`.zero?`, and `.modulo(n)`. An operator is admitted
only once it reads in EVERY target — one with no Rust rendering is not a slow
operator, it is not an operator. That sentence is checked, not aspired to:
every operator the evaluator runs passes through the grammar chapter's own
Admit gate on each suite run
(`lib/hecksagain/grammar/expression_operators.json`, held by
`spec/operator_conformance_spec.rb`).

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
purpose: evaluated inside Postgres, it never needs byte-identical logic in
Ruby and Rust, which is this project's single most recurring bug class.

Eras are a Postgres concern only. Memory, Sqlite, and Heki carry no era
concept at all — a domain there boots the text it is handed.

## Language versions

The language applies the same discipline to itself. Every word of the
bluebook surface carries a lifecycle in `syntax.bluebook` — proposed,
admitted, deprecated, retired — and a proposed or retired word reaches no
projected parser table: to a projected reader it does not exist. A renamed
word keeps its old spelling in `was:`, and the old spelling parses forever
in both runtimes (`sets` is the word; `then_set` is the era the whole
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
  projector/    IR export and the Rust projection.  SENDING IT ELSEWHERE.
```

The split follows the dependency direction rather than the topic. The
expression evaluator is in the semantic core and not `projector/` because the
Ruby runtime evaluates every given and every invariant through it — Rust is
merely the first other thing to read it.

## The Rust projection

The language describes itself:
[`lib/hecksagain/language/bluebook/`](lib/hecksagain/language/bluebook)
declares what an aggregate, a command, a transition ARE, in bluebooks. The
Rust IR is generated from that self-description — `bin/ir_structs` and
`bin/ir_vocabulary` emit the typed structs and the closed sets they sit in,
and specs hold the checked-in Rust byte-equal to its generators.
`crate::ir::Aggregate` is not a port of a Ruby class; it is the language's own
declaration, rendered in Rust.

`bin/ir_rust` takes the next rung: a whole domain, projected as Rust
**values** of those structs and compiled into the binary. `Runtime::boot`
prefers a projection to a parse, and a projected chapter boots with no file at
all. Every projection is sealed to its source by SHA — a projection that no
longer matches its source refuses to stand in for it, because name-only lookup
once booted stale after an edit.

The distinction this project cares about is agreement **by construction** (one
author, nothing to drift) versus agreement **by checking** (two authors, a
harness, and a corpus exactly as wide as its coverage). The generated structs
and projected domains are by-construction; everything else is still
by-checking — and `bin/parity` stays the gate either way, diffing what the two
runtimes DO at three stages: the IR they read, the behaviour they run, and the
records they write. Successes and every refusal path, byte-exact past JSON key
order.

What is not projected, and why:

- **The dispatcher still reads the flattened JSON IR in most places.** The
  typed domain is in the runtime now and readers move over one at a time —
  moving them blind would leave two sources of truth mid-flight. The
  flattening is where the recurring bug class lives (a typed `Vec<String>`
  read back with `as_str` returns None on an array, silently, and compiles),
  which is the whole reason the projection exists.
- **The expression evaluator is hand-written in both runtimes.** The language
  can declare what an expression is; it cannot declare how to evaluate one.
- **Era minting stays Ruby-only, and the reference transform stays
  hand-written in both runtimes, by policy** — independence of authorship is
  the point. Generating one from the other would put correlated error exactly
  where identity is created.

The path to a third target is a ratchet, not a port: hand-write a runtime in
the new language **from the `.bluebook` files** — never from the Ruby or Rust,
since an implementation ported from reading Ruby inherits Ruby's misreadings —
drive it parity-complete, and only then specialize it, diffing the projected
output against the hand-written, parity-complete artifact: a golden file at
the scale of a whole runtime.

`docs/porting/` is the kit for that first step:

- [`grammar.md`](docs/porting/grammar.md) — the expression sublanguage as a
  formal precedence-ordered grammar.
- [`conformance-kit.md`](docs/porting/conformance-kit.md) — what
  `spec/golden/ir/*.json` and `spec/parity/*.json` are, and what `bin/parity`
  actually checks (no per-step expected values anywhere — a full-output diff).
- [`behavior-notes.md`](docs/porting/behavior-notes.md) — the non-obvious
  behavioral rules this project only learned by breaking.
- [`build-order.md`](docs/porting/build-order.md) — a staged path (parser →
  expressions → dispatch → query → full corpus) with a checkpoint at each
  stage, since `bin/parity` alone gives no signal until an implementation is
  substantially complete.

## Verify

```sh
rspec                    # the Ruby side
(cd rust && cargo test)  # the Rust side
bin/parity               # the two runtimes agree
```

`bin/parity` always rebuilds the Rust workspace first — a compiled artifact is
never trusted to match the source tree. It expects a local Postgres for the
era gates (`postgres://localhost/hecks_parity` by convention;
`HECKS_PARITY_POSTGRES` overrides the URL, and an unset variable does not skip
the gate — skipping-on-unset once let a broken era dance exit 0 twice).

Every Rust interpreter test has a named Ruby twin. The sublanguage is
specified once and implemented twice, so each implementation needs its own
tests or the second is only believed rather than known.
