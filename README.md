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

<!-- doctest:boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
Hecks.hecksagon("Pizzas") { Pizzas::Order.persisted_by("Memory") }
-->

```ruby
order = Order.create_pizza(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.add_topping(topping: { value: "Basil" }, amount: { value: 3 })
order.purchase(customer_name: { value: "Chris" }, amount: { cents: 1200 })

order.status             # => "sold"
order.events.last.name   # => "PizzaPurchased"

Order.count              # => 1
Order.find(order.id).customer_name.to_h   # => { value: "Chris" }
```

(That block is not an illustration — the suite extracts and runs it, claims
and all, on every push. Every `ruby`-fenced example in this README and in
`docs/guides/` is executed the same way; see `spec/guides_spec.rb`.)

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

## Guides

Task-oriented, doctested the same way the section above is — every guide's
own examples run against the real runtime on every push.

<!-- generated:begin id=guides -->
- [Aggregates and value objects](docs/guides/aggregates-and-value-objects.md)
- [Commands](docs/guides/commands.md)
- [Entities](docs/guides/entities.md)
- [Extending Hecks](docs/guides/extending-hecks.md)
- [Getting started](docs/guides/getting-started.md)
- [Guides](docs/guides/index.md)
- [Lifecycles](docs/guides/lifecycles.md)
- [Policies and process managers](docs/guides/policies-and-process-managers.md)
- [Queries and read models](docs/guides/queries-and-read-models.md)
- [Running a runtime](docs/guides/running-a-runtime.md)
- [Schema evolution](docs/guides/schema-evolution.md)
- [Verification](docs/guides/verification.md)
- [Wiring](docs/guides/wiring.md)
- [Writing an adapter](docs/guides/writing-an-adapter.md)
<!-- generated:end -->

## Reference

<!-- generated:begin id=reference -->
[The DSL reference](docs/reference/index.md) — 18 contexts, generated from `lib/hecksagain/language/bluebook/syntax.bluebook` and held to it by `spec/reference_golden_spec.rb`.
<!-- generated:end -->

## Writing a bluebook

Above is `pizzas.bluebook` already running — booted, and every command in it
real. Here is what declaring one from scratch actually looks like, the same
file quoted piece by piece: identity, a value object with an invariant, a
`list_of`, a simple lifecycle, one creating command, and one mutating command
that refuses before it mutates.

```ruby skip
aggregate "Order" do
  identified_by { name.value }

  attribute :name,     PizzaName
  attribute :toppings, list_of(Topping)

  value_object "PizzaName" do
    attribute :value, String

    invariant("a pizza is named") { !value.to_s.empty? }
  end

  value_object "Topping" do
    attribute :name,   String
    attribute :amount, Integer
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

    then_set :toppings, append: { name: :topping, amount: :amount }

    emits "ToppingAdded"
  end
end
```

(That is `examples/pizzas/bluebook/pizzas.bluebook`, trimmed to the pieces
this section walks through — `Pizza`, `ToppingName`, and `ToppingAmount` are
declared alongside it and read in full there.)

A creating command is a module method; a mutating command is a method on the
record it references, and never mutates without being asked to justify
itself first — `given` refuses before `then_set` ever runs, and `PizzaName`'s
`pattern:` refuses before either does — ahead of `PizzaName`'s own
"a pizza is named" invariant, on the same booted domain from above:

```ruby
Order.create_pizza(name: { value: "" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })   # ~> TypeMismatch: PizzaName.value must match [^ \t\n\r], got ""
```

Pizzas' own mutations either replace a field (`then_set :status, to: "sold"`,
on `Purchase`) or append to a list (`then_set :toppings, append: ...`,
above) — this corpus never needed to increment a running total, so it never
declared one. The banking corpus did: an account's balance is a number
`Credit` raises rather than replaces. It is real too, so here it is, declared
and booted the same way, trimmed to the one aggregate that needs it:

```ruby bluebook
Hecks.bluebook "Banking" do
  vision "Customers hold accounts, accounts move money, and every movement is a transfer that can fail halfway. The domain that has to get it right twice — once in the rules, once in the recovery."
  core

  aggregate "Account" do
    identified_by { number.value }

    attribute :number,  AccountNumber
    attribute :balance, Money

    value_object "AccountNumber" do
      attribute :value, String
      invariant("an account number is present") { !value.to_s.empty? }
    end

    value_object "Money" do
      attribute :cents,    Integer, default: 0
      attribute :currency, String,  default: "USD"

      invariant("a currency is a three-letter code") { currency.to_s.size == 3 }
    end

    value_object "PositiveMoney" do
      attribute :cents,    Integer
      attribute :currency, String, default: "USD"

      invariant("an amount is positive") { cents.positive? }
      invariant("a currency is a three-letter code") { currency.to_s.size == 3 }
    end

    lifecycle :status, default: "open" do
      transition "FreezeAccount" => "frozen", from: "open"
    end

    command "Open" do
      role "Branch clerk"
      goal "Give a customer somewhere to keep money"

      attribute :number, AccountNumber

      then_set :number, to: :number

      emits "AccountOpened"
    end

    command "Credit" do
      role "Teller"
      goal "Put money in"

      reference_to Account
      attribute :amount, PositiveMoney

      given("the account is open") { status == "open" }

      then_set :balance, increment: :amount

      emits "AccountCredited"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("Banking") { Banking::Account.persisted_by("Memory") }
```

```ruby
account = Account.open(number: { value: "1001" })
account.credit(amount: { cents: 500, currency: "USD" })

account.balance.to_h                                     # => { cents: 500, currency: "USD" }
account.credit(amount: { cents: -1, currency: "USD" })    # ~> InvariantViolation: an amount is positive
```

(That aggregate is a trimmed real subset of
`examples/banking/bluebook/banking.bluebook` — the full `Account` also holds a
`kind`, a `daily_limit`, a `ledger` of `LedgerEntry`, and a `Customer` it
belongs to, none of which this one point needed.)

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

```ruby skip
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

```ruby skip
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

```ruby skip
examples/pizzas/
  bluebook/
    pizzas.bluebook        the domain
    pizzas.hecksagon       the wiring — Pizzas::Order.persisted_by("Postgres")
    pizzas.world           the per-deployment values
  data/
```

Ports and adapters are **not** in there. They are the two halves of the
inverted arrow, and each ships with the library beside its implementation:

```ruby skip
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

## The corpus

Every domain this repository's own tests and docs draw examples from:

<!-- generated:begin id=corpus -->
- **banking** — Customers hold accounts, accounts move money, and every movement is a transfer that can fail halfway. The domain that has to get it right twice — once in the rules, once in the recovery.
- **compliance** — Something elsewhere already acted to contain a risk; this domain tracks the human review that decides what happens next.
- **pizzas** — Put toppings on a pizza and sell it to a customer.
<!-- generated:end -->

## The tools

<!-- generated:begin id=tools -->
| tool | |
|---|---|
| `bin/backfill_era_projections` | Proactively backfills `hecks_eras.held_projection` for every row of one domain that predates that column — an explicit, operator-run vers... |
| `bin/canonicalise` | Sorts a JSON document's object keys, recursively — key order is not semantics, so a diff a human reads should not have to notice it moved. |
| `bin/console` | Boots a domain (pizzas by default) and drops into IRB with its door installed — the fastest way to dispatch a real command by hand. bin/c... |
| `bin/doc_coverage` | EVERY LIVE WORD SHIPS WITH A RUNNING EXAMPLE, or this refuses. Prose is a declaration, and a declaration nothing runs cannot disagree wit... |
| `bin/docs` | A domain's usage document, projected from its own bluebook. bin/docs # list every domain in this checkout bin/docs examples/banking # the... |
| `bin/evolve` | The language-change convention, made executable. Adding a word to the bluebook surface has always been a many-file walk — syntax row, Rub... |
| `bin/expression_projection` | The expression machinery's tables, projected from the grammar chapter's admitted set and checked in, so the evaluator and the canonical f... |
| `bin/fuzz` | Generates random-but-valid command/query sequences from a domain's own IR (Hecksagain::Fuzzing::SequenceGenerator) and checks each one th... |
| `bin/generate` | Prints one randomly generated, valid dispatch sequence for a domain — the same generator bin/fuzz drives, exposed standalone so a sequenc... |
| `bin/history` | Prints every journal entry a domain's append-only adapters hold, as JSON — the full write history, not just the current head. bin/history... |
| `bin/ir` | Prints a booted domain's IR as JSON — the same `to_h` the golden specs pin and StorageShape hashes into an era, for reading rather than a... |
| `bin/merge_tail` | Tail-merge: the one deliberate command. It marks a business event — an old app retiring — never a shape change. One transaction: advance ... |
| `bin/model_check` | STATIC ANALYSIS OVER THE IR — unreachable lifecycle states, transitions nothing can ever fire, saga states no handler chain reaches, a co... |
| `bin/pattern-cases` | THE RECORDED FIXTURE for `pattern:`, and how to regenerate it : bin/pattern-cases > spec/corpus/fixtures/patterns.json spec/pattern_subse... |
| `bin/present` | Boots the banking example against the in-memory adapter (same rebind spec/facade/handle_spec.rb already uses — banking.hecksagon itself b... |
| `bin/project` | Refreshes every read-model projection a domain declares, by hand — the same catch-up a boot runs lazily, forced now rather than on first ... |
| `bin/project_cli` | Mints a command-line binary for a domain, named after its bluebook. bin/project_cli # every domain in this checkout bin/project_cli qa # ... |
| `bin/project_deploy` | The AWS DEPLOYMENT projector — docs/decisions/0018-rehydrate-replay-lambda-host.md. Generates the SAM template and build Makefile for rus... |
| `bin/project_field_hints` | Generates rust/host/src/field_hints.rs — the four regex hints Hecksagain::Forms::FieldShape#text_field (lib/hecksagain/ forms/field_shape... |
| `bin/project_kernel_capabilities` | Generates the two capability enums the hand-written Rust kernel (rust/src/kernel/attribute_shapes/*.rs, rust/src/kernel/ expression_opera... |
| `bin/project_model` | Projects the model's holding half from the language that declares it. Behaviour::X is hand-written and untouched; `settle` is the seam. b... |
| `bin/project_parser_table` | Projects the chapter's own Syntax aggregate into the Rust parser's keyword table — the parser's grammar knowledge DERIVED from hecksagain... |
| `bin/project_refusal_wording` | Generates rust/src/kernel/refusal_wording.rs from `Hecksagain::Runtime:: RefusalWording::TEMPLATES` (lib/hecksagain/runtime/refusal_wordi... |
| `bin/project_rust` | Generates Rust source for one domain into rust/src/generated/ — the driver for `RustProjection` (rust/project.rb, alongside the Rust crat... |
| `bin/project_vocabulary` | Projects the language's own closed sets into lib/hecksagain/vocabulary.rb. A one-line wrapper over the projector registry, deliberately —... |
| `bin/project_wasm` | The WASM projector — wraps THE SAME Rust binary bin/project_rust already generates, rather than a second, WASM-specific implementation (d... |
| `bin/project_wasm_browser` | The BROWSER wasm-bindgen projector — decision docs/decisions/0015-wasm-bindgen-browser-projection.md. Deliberately a SEPARATE binary from... |
| `bin/reattest_era` | The recovery path after a held-text integrity refusal. The digest is tamper-EVIDENCE — it catches accident and drift, not an adversary (a... |
| `bin/reference` | Regenerates docs/reference/ from the language's own Syntax chapter — the tables from the declaration, the prose preserved from the commit... |
| `bin/run` | Executes a step list — commands and queries, declared as JSON — and reports instances, events, refusals, reactions, sagas, and query rows... |
| `bin/rust_conformance` | THE DIFFERENTIAL HARNESS — docs/decisions/0010-ruby-is-the-reference-implementation.md. Ruby is the oracle a second runtime is checked ag... |
| `bin/rust_coverage` | THE COVERAGE CHECKER — a different question than bin/rust_conformance asks, deliberately, not a replacement for it. bin/rust_conformance ... |
| `bin/rust_kernel_coverage` | THE MECHANICAL, COMMENT-TAG-FREE HALF OF THE GUARANTEE. bin/project_kernel_capabilities generates the ENUM half — the compiler already re... |
| `bin/scaffold_translation` | The scaffold writes translations; humans resolve ambiguity. Diffs the held era against the current bluebook and writes the edge file: con... |
| `bin/shape` | The storage-shape projection of one bluebook file, as JSON — the exact form StorageShape.mint_hash hashes to name an era, printed so a bu... |
| `bin/smoke_test` | BOOTS A REAL DOMAIN AND ACTUALLY DISPATCHES AGAINST IT — the sibling `bin/model_check` never had. That tool proves a bluebook is STRUCTUR... |
| `bin/stores` | Prints every aggregate's current records, as JSON — the head, not the journal (bin/history prints the full write history instead). bin/st... |
| `bin/translation_audit` | The audit derives its assertions. Layer 1: every translated state passes the new era's types, invariants, and lifecycle. Layer 2: the com... |
<!-- generated:end -->

## The library

```ruby skip
lib/hecksagain/
  language/     the language, declared in its own bluebooks.  WHAT A BLUEBOOK IS.
  grammar/      the expression and translation sublanguages, and the Admit gate.
  bluebook/     dsl → ir → expression.  READING ONE.
  runtime/      dispatch, instances, the registry.  RUNNING IT.
  adapters/     driven: memory, sqlite, heki, postgres, folder, prism.
  translation/  domain-version translation — eras and lineage.
  projector/    IR serialization — the translation-edge digest reads it.
```

The split follows the dependency direction rather than the topic. The
expression evaluator lives in the semantic core, not `projector/`, because
the runtime evaluates every given and every invariant through it directly.

Everything below is built on that core, each one a capability rather than
a bolt-on:

```ruby skip
lib/hecksagain/
  facade/               the door — Handle, AggregateDoor, JsonDoor, Surface.  Class-free, per boot.
  router/               the project-wide dispatch door; installs each chapter's namespace at boot.
  ports/                domain ports — auth, identity, persistence, query — declared like everything else.
  query_specification/  a query's shape, held apart from any engine that answers it.
  projections/          IR as a capability — `emits_ir`, and its consumers (OIDC, the DSL reference, the parser table).
  forms/                IR → HTML, and a Rack app content-negotiating it against plain JSON.
  fuzzing/              generated sequences, checked against declared properties — what `bin/fuzz` runs.
  doc/                  the generated DSL reference (`bin/reference`).
  framework/            shared, domain-agnostic bluebooks (Governance, Identity, ConsoleSettings) — referenced, not copied.
  deploy/               the Deploy bluebook — what `deployed_to` means, judged the same way as everything else.
```

Nothing here is required by `require "hecksagain"` unless a booted domain
actually uses it — `forms/` and `fuzzing/` each stay out of the core
boot chain on purpose, so a project that never touches one never pays
for it.

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
bundle exec rspec                 # the whole suite
bundle exec parallel_rspec spec   # same suite, split across your machine's cores (local only)
bin/model_check                   # static analysis over the IR — unreachable states, dead transitions
bin/fuzz                          # generated sequences, checked against declared properties
```
