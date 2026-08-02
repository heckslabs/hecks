# hecksagain

Hecks, rewritten — with **Ruby as the source of truth**.

## The thesis

In Hecks the parser is authored twice: once as a Ruby DSL, once as a Rust
parser, kept in step by a parity suite. Every drift retired over the last
months was a disagreement between those two authors — never a routing
disagreement, because routing was already data.

hecksagain does not fix that by generating one runtime from the other. **Both
runtimes are hand-written, and that is the design.** What changed is where
authority lives: **Ruby holds the semantics**, and Rust is a second
implementation held to Ruby's answers.

So parity here is a claim about OUTPUT, not about origin — two authors reading
the same source file must produce the same IR, the same behaviour, and the same
stored records. `bin/parity` is what makes the claim real.

```
  a .bluebook  →  Ruby runtime  ┐
                                ├─→  must agree, or it is a SPLIT
  the same file →  Rust runtime ┘
```

Neither runtime is handed the other's output. The IR is *extracted* from Ruby
for inspection and diffing ; Ruby is never generated from it, and neither is
Rust.

> **A note on the word "projection."** An earlier framing called Rust a
> projection of Ruby, with the interpreter as the one exception. It is not one:
> nothing here generates the Rust parser, and no step in any build produces it.
> It is written by hand, like the Ruby, and the two are kept together by
> `bin/parity` comparing what they DO.
>
> The word mattered because it described the wrong kind of safety. "Projection"
> promises agreement BY CONSTRUCTION — one author, so nothing to drift. What
> actually holds here is agreement BY CHECKING, which is a weaker promise and a
> real one, and which is only as wide as the corpus. Every divergence this
> project has found — `dims.length_cm`, the acronym snake rule, an aggregate
> named `Order` — hid in exactly the gap between those two claims.
>
> A related thing to know when reading this tree: parts of the Rust side were
> cherry-picked from Hecks ahead of the Ruby here, so it can carry vocabulary
> the Ruby has not yet grown. `has_many` / `has_one` / `belongs_to` were the
> longest-standing example of this — the Rust parser read them, Hecks's Ruby
> DSL had them, and hecksagain's Ruby did not, so a bluebook using one parsed
> on one side only. Ruby has them now, as sugar over `reference_to`. Porting
> them was also how two zero-tested Rust bugs surfaced: `has_one`/`belongs_to`
> built two attributes where Ruby builds one, and every aggregate's attributes
> were silently reordered relative to the source the moment a plain field was
> declared before a reference — invisible because the whole corpus happens to
> write references first. See `RESTART.md` for the rest. `subscribe`
> (`.hecksagon`'s word, not a bluebook one) remains unported, by scope rather
> than oversight.

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

Two parsers is not the mistake. Two parsers whose agreement nobody CHECKS is.
Both parsers here are authored by hand, so the whole burden falls on the
harness — and the harness answers it by comparing what the runtimes DO, at
three stages: the IR they read, the behaviour they run, and the records they
write.

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

## Porting to a new language

Adding a third implementation — or just maintaining these two — needs more than reading Ruby and
Rust side by side and guessing at intent. `docs/porting/` collects what's otherwise scattered:

- [`grammar.md`](docs/porting/grammar.md) — the expression sublanguage above, written out as a
  formal precedence-ordered grammar instead of two pieces of regex to reverse-engineer.
- [`conformance-kit.md`](docs/porting/conformance-kit.md) — precisely what `spec/golden/ir/*.json`
  and `spec/parity/*.json` are, and what `bin/parity` actually checks (there is no per-step expected
  value anywhere — it's a full-output diff, byte-exact past JSON key order).
- [`behavior-notes.md`](docs/porting/behavior-notes.md) — the non-obvious behavioral rules this
  project only learned by breaking, consolidated from comments scattered across both runtimes.
- [`build-order.md`](docs/porting/build-order.md) — a staged path (parser → expressions → dispatch →
  query → full corpus) with a checkpoint at each stage, since `bin/parity` alone gives no signal
  until a new implementation is substantially complete.

Persistence adapters are deliberately not covered — that's its own concern, separate from whether a
bluebook runs correctly.

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

- **An aggregate IS the port**, and the hexagon wires it by name —
  `Pizzas::Pizza.persisted_by("Sqlite")` reads as a method call and records a
  bind, whether it lands on the installed door or on the load-time proxy.
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
(cd rust && cargo test)  # the Rust half of the sublanguage contract
bin/parity             # the two runtimes agree
```

Every Rust interpreter test has a named Ruby twin. The sublanguage is specified
once and implemented twice, so each implementation needs its own tests or the
second is only believed rather than known.
