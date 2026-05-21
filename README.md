<p align="center">
  <img src="una.png" width="200" alt="Una, the Embryonaut brand mark">
</p>

# What the Hecks?

**Hecks is executable specifications, not a translation.** You write your domain in the *Bluebook* — Hecks's specification language — and the running program *is* the spec. There is no translation layer between what you wrote and what runs ; no documentation that can lie to you. The Bluebook IS the program.

```ruby
Hecks.bluebook "Banking" do
  aggregate "Account" do
    attribute :balance, Float, default: 0.0

    command "Deposit" do
      reference_to Account
      attribute :amount, Float
      then_set :balance, plus: :amount
    end

    invariant("balance must not be negative") { balance >= 0 }
  end
end
```

That's the source of truth. Boot it, dispatch a command, watch an event :

```ruby
require "hecks"
app = Hecks.boot(__dir__)
account = app.Account.create
app.Account.deposit(account_id: account.id, amount: 50.0)
# => DepositedAccount { balance: 50.0 }
```

The whole language is five rules. **[Bluebook on a Napkin →](docs/napkin.md)** · For the longer argument, see [embryonaut.ai/letter](https://embryonaut.ai/letter).

---

## Quick Start

### 1. Install

```bash
gem install hecks
```

Or from source :

```bash
git clone https://github.com/chrisyoung/hecks.git
cd hecks
bundle install
```

### 2. Run the pizzas example

```bash
ruby -Iruby examples/pizzas/pizzas.rb
```

You get a real domain : pizzas with toppings, orders with lifecycle, events streaming, queries running — all from the files in [`examples/pizzas/`](examples/pizzas/). Read on to see what those files are.

---

## The Shape of a Hecks App

A Hecks app is a small set of declarative DSL files, each guarded by an allow-list. None of them is general-purpose Ruby — the loaders refuse anything outside the surface, so the runtime can parse them in Ruby OR Rust and get the same answer.

```
examples/pizzas/
├── hecks/
│   ├── pizzas.bluebook    # the domain — aggregates, commands, events
│   └── pizzas.hecksagon   # the wiring — which adapters
└── pizzas.rb              # the boot — one line
```

Larger or multi-deployment domains add a third file alongside the others :

```
hecks/
├── voice.bluebook         # the domain
├── voice.hecksagon        # the wiring shape
└── voice.world            # the deployment values
```

Each file has a single job. Below : what pizzas looks like end-to-end, then the voice pattern for when an adapter has API surface worth declaring.

### `pizzas.bluebook` — the domain

The Bluebook is the contract. It declares aggregates, value objects, commands, lifecycles, validations, queries, policies. No I/O, no config — pure shape.

```ruby
Hecks.bluebook "Pizzas" do
  aggregate "Pizza" do
    attribute :name
    attribute :description
    attribute :toppings, list_of(Topping)

    value_object "Topping" do
      attribute :name
      attribute :amount, Integer
      invariant("amount must be positive") { amount > 0 }
    end

    command "CreatePizza" do
      role "Chef"
      attribute :name
      attribute :description
    end

    command "AddTopping" do
      reference_to Pizza
      attribute :name
      attribute :amount, Integer
      given("max 10 toppings") { toppings.size < 10 }
      then_set :toppings, append: { name: :name, amount: :amount }
    end

    query "ByDescription" do |desc|
      where(description: desc)
    end
  end

  aggregate "Order" do
    reference_to Pizza
    attribute :customer_name
    attribute :status, default: "pending" do
      transition "CancelOrder" => "cancelled"
    end

    command "PlaceOrder" do
      reference_to Pizza
      attribute :customer_name
      attribute :quantity, Integer
    end

    command "CancelOrder" do
      reference_to Order
    end

    query "Pending" do
      where(status: "pending")
    end
  end
end
```

Full reference : [`docs/usage/dsl_reference.md`](docs/usage/dsl_reference.md).

### `pizzas.hecksagon` — the wiring

The hecksagon names *which* adapters the domain uses. No values, no secrets, no environments — just which kinds of I/O, and which capabilities are generated.

```ruby
Hecks.hecksagon "Pizzas" do
  capabilities :crud
end
```

`capabilities :crud` gives Pizza and Order the full create/read/update/delete surface at the bus, backed by in-process memory repositories by default. To swap in a persistence backend at boot time :

```ruby
app = Hecks.boot(__dir__, adapter: :sqlite)
```

That's enough for the demo. Real apps usually declare adapters explicitly in the hecksagon ; see the voice pattern below for the wired form.

### `pizzas.rb` — the boot

One line wires it all together :

```ruby
require "hecks"
app = Hecks.boot(__dir__)
```

`Hecks.boot` reads the bluebook and hecksagon in `hecks/`, validates the bluebook, builds the IR, wires the adapters, and returns a running app. From there you dispatch commands and subscribe to events :

```ruby
pizza = Pizza.create(name: "Margherita", description: "Classic")
pizza.toppings.create(name: "Mozzarella", amount: 2)

order = Order.place(pizza: pizza.id, customer_name: "Ada", quantity: 1)
Order.cancel(order: order.id)

Pizza.by_description("Classic").each { |p| puts p.name }
```

The full demo script is at [`examples/pizzas/pizzas.rb`](examples/pizzas/pizzas.rb).

---

## When an Adapter Has Shape

Pizzas only needs the default repository ; its hecksagon is one line. Adapters with surface — commands, retry policy, caching, hosted-API config — deserve to be declared, not buried in source.

The pattern : give the adapter a named instance in the hecksagon, bind it to a bluebook command via `trigger_on`, and keep per-deployment values in a sibling `.world` file. This is the canonical Miette voice integration.

**`voice.bluebook` — what the adapter does (the commands it handles)**

```ruby
Hecks.bluebook "Voice" do
  aggregate "Voice" do
    command "Speak" do
      attribute :text, String
    end
  end
end
```

**`voice.hecksagon` — which adapter handles which command**

```ruby
Hecks.hecksagon "Voice" do
  adapter :memory

  adapter :tts, name: :miette_speech do
    trigger_on "Voice.Speak"
  end
end
```

**`voice.world` — per-deployment values**

```ruby
Hecks.world "Voice" do
  miette_speech do
    provider          :elevenlabs
    voice_id          "WwS1lF7yiubZWoroH5D5"
    model             "eleven_turbo_v2_5"
    stability         0.25
    cache_dir         "~/.config/miette/audio"
  end
end
```

`Voice.Speak` is now a real declared command. It validates like any other command, it shows up in the dispatch log, and the adapter is bound to it by name — not by string convention. Swapping providers between dev and prod is a one-file change to `voice.world` ; the bluebook and hecksagon don't move.

The full version is the Miette voice integration at [`miette/body/voice/`](https://github.com/chrisyoung/miette). For framework-internal examples of the same pattern, see [`adapters/auth/`](adapters/auth/) and [`runtime/server/`](runtime/server/).

---

## Two Implementations, One Spec

Hecks ships two parsers for the same Bluebook language — a Ruby DSL (`ruby/`) and a Rust runtime (`rust/`, the `storehouse` binary). Both produce a single canonical IR. A parity suite holds them to **byte-identical IR**, run on every commit ; any drift between Ruby and Rust is a structural bug, not a style difference.

```bash
ruby -Iruby parity/parity_test.rb              # Ruby ↔ Rust IR parity
cargo test --lib --manifest-path rust/Cargo.toml
```

This matters because it's the proof that one specification can mean exactly the same thing in two languages — which means it can mean the same thing in any language a target generator emits next. A target generator is a function from the IR ; Ruby and Rust are the first two outputs. The Bluebook is the input.

`storehouse` is the canonical runtime today : it parses bluebooks, dispatches commands, runs validators, conceives companions, executes behavioral tests, and runs MCP. The Ruby gem is the convenient embedding for Ruby projects. See [`docs/usage/architecture_tour.md`](docs/usage/architecture_tour.md).

---

## The Bluebook DSL at a Glance

Each construct maps to a real generated thing :

| Construct | What it produces |
|----------|------------------|
| `aggregate` | Business object with typed attributes, identity, repository |
| `attribute` | Typed field with validation, default, lifecycle hooks |
| `command` | Class method that emits a domain event when called |
| `lifecycle` / `transition` | State machine with guarded transitions |
| `value_object` | Frozen, immutable detail embedded in an aggregate |
| `entity` | Mutable sub-object with its own identity |
| `validation` | Checked at command time |
| `invariant` | Enforced on aggregate state after every change |
| `specification` | Reusable, composable predicate |
| `query` | Named, chainable query object |
| `policy` | Reacts to an event by triggering another command |
| `service` | Orchestrates multiple commands across aggregates |
| `port` | Role-based access control boundary |

The full reference lives in [`docs/usage/dsl_reference.md`](docs/usage/dsl_reference.md) ; for each construct there's a matching usage doc under [`docs/usage/`](docs/usage/) with runnable examples.

---

## Behavioral Tests, For Free

Every Bluebook gets a behavioral-tests companion generated from its IR. Run them in pure memory — no database, no I/O :

```bash
storehouse conceive-behaviors path/to/source.bluebook
# writes path/to/source_behavioral_tests.bluebook

storehouse behaviors path/to/source_behavioral_tests.bluebook
# 12 tests · 12 passed · 0 failed
```

The test DSL is itself a Bluebook, sibling to `Hecks.bluebook` :

```ruby
Hecks.behaviors "Bookshelf" do
  test "CheckOutBook flips status to checked_out" do
    setup  "AddBook", title: "Dune", author: "Herbert"
    tests  "CheckOutBook", on: "Book"
    expect status: "checked_out"
  end
end
```

References resolve from in-scope — no IDs in test source. See [`docs/usage/behavioral_tests.md`](docs/usage/behavioral_tests.md).

---

## Build-Time Validation

Hecks validates your domain before generating anything. Every error includes a fix suggestion.

| Rule | What it checks |
|------|----------------|
| `CommandNaming` | Commands start with a verb |
| `NoBidirectionalReferences` | No circular A→B and B→A references |
| `ValidReferences` | References point to existing aggregates |
| `NoImplicitForeignKeys` | Warns when `_id String` should be `reference_to` |
| `LifecycleReachability` | Every state is reachable from the default |
| `PolicyWiring` | Triggered commands exist ; emitted events are real |
| `PortConsistency` | Port-allowed methods exist on the aggregate |
| + more | Name collisions, reserved words, value-object purity, structural shape |

```bash
hecks validate
```

See [`docs/usage/specialize_validator.md`](docs/usage/specialize_validator.md) and the validator entries in [`FEATURES.md`](FEATURES.md).

---

## AI-Native

Hecks ships an MCP server so Claude (or any MCP client) can model domains alongside you.

```bash
hecks mcp
```

> "Build me a photo gallery. Photos have a title, url, taken_at date, and tags."

Claude generates the Bluebook. Every operation reports its result.

> "Promote `Comment` into its own domain. Wire it into Blog and Photos."

Claude promotes the aggregate, creates the new domain file, wires both consumers through events.

> "When I upload a photo, create a draft blog post automatically."

```ruby
policy "AutoDraft" do
  on "UploadedPhoto"
  trigger "CreateDraftPost"
  map title: :title
end
```

Three domains talking through events. The event log shows the chain : `UploadedPhoto → AutoDraft → CreatedDraftPost`. See [`docs/usage/mcp_runtime_from_ir.md`](docs/usage/mcp_runtime_from_ir.md).

---

## Why Hecks

AI is good at writing code. It's bad at maintaining constraints across a codebase over time.

Ask Claude to generate a domain layer and you'll get something that works today. Next week, someone adds a bidirectional reference. The week after, a command gets named "ProcessData." A month later, a value object holds a reference to an aggregate root. None of these are bugs — the code runs. They're architectural violations that compound silently.

Hecks catches all of them at build time. The generated output has typed ports, event-driven policies, and bounded-context boundaries that can't be bypassed.

> Use AI to write the DSL. Use Hecks to guarantee the architecture holds.

For the longer argument, see [`docs/why_hecks.md`](docs/why_hecks.md), [`docs/ddd.md`](docs/ddd.md) (DDD mapping), and [`docs/hexagonal.md`](docs/hexagonal.md) (hexagonal architecture mapping).

---

## A Future Where AI Writes in Specs

Today's models are trained on empirical languages — Ruby, Python, Go, JavaScript — discovered through millions of human iterations, full of accidental complexity, unspoken conventions, and behaviour the language itself can't constrain. A specification language flips this. The Bluebook is small enough to learn completely. Its grammar is finite. Its rules — what an aggregate is, why a value object can't reference an aggregate root, what a policy emits — are *declared*, not absorbed.

An AI that writes a Bluebook writes intent directly, then watches that intent compile into Ruby, Rails, Go, or the next runtime someone targets. A bad imperative draft hides its violations inside a 300-line method ; a bad Bluebook gets caught by a validator with a one-line fix. The model doesn't have to be right about generated code. It has to be right about the spec.

Two implementations (Ruby and Rust) held to byte-identical IR are not a curiosity — they're the proof that one specification can mean exactly the same thing in two languages, which means it can mean the same thing in any language a generator targets next. For the technical argument — DDD validation, MCP-native modelling, the Futamura projection that lets Hecks specialize itself, cascade lockdown, language-neutral parity — see [`docs/papers/prior_use/`](docs/papers/prior_use/).

---

## A Covenant

Hecks is built around three principles encoded as defaults :

- **Transparency** — events are observable, state changes are auditable, nothing is hidden from the people the system affects.
- **Equity** — systems that serve without clinging. Not extracting engagement, not maximising dependency.
- **Consent** — design for the beings the software serves, not against them.

The defaults protect people. Overriding them requires a deliberate choice. See [`docs/covenant.md`](docs/covenant.md).

---

## Examples

The [`examples/`](examples/) directory has runnable domains for every target :

- [`examples/pizzas`](examples/pizzas) — **start here.** Two aggregates, value objects, lifecycle, queries. The example walked through above.
- [`examples/banking`](examples/banking) — four aggregates, value objects with invariants (Money is integer-cents, Currency is ISO three-letter code), a policy that cascades `IssuedLoan` into `Deposit`.
- [`examples/bookshelf`](examples/bookshelf) — Books with lifecycle, Loans with references. The simplest two-aggregate domain.
- [`examples/governance`](examples/governance) — 5 bounded contexts, 14 aggregates, cross-domain policies.
- [`examples/pizzas_rails`](examples/pizzas_rails) — same domain, Rails target.
- [`examples/pizzas_static_go`](examples/pizzas_static_go) — same domain, single Go binary.
- [`examples/pizzas_static_ruby`](examples/pizzas_static_ruby) — same domain, standalone Ruby.
- [`examples/sinatra_app`](examples/sinatra_app) — minimal HTTP integration.
- [`examples/multi_domain`](examples/multi_domain) — cross-context event flow.
- [`examples/llm_adapter`](examples/llm_adapter) — LLM-backed adapter wired through Hecks ports.
- [`examples/shell_adapter`](examples/shell_adapter) — shell-command adapter.

Each comes with a README and runs from the project root with one command.

---

## Repository Layout

```
hecks/
├── bluebook/        the language — grammar, verbs, primitives
├── chapters/        the framework's anatomy described in Bluebook
├── runtime/         execution machinery — boot, dispatch, projection, server
├── discipline/      antibody, validators, restructure, security
├── codegen/         specializer, meta-shapes, conceivers, target generators
├── cli/             argv, banner, console, status, statusline, terminal
├── integrations/    rails, web components, cloudflare deploy
├── tools/           inbox, project_management, training, inventions
├── ruby/            Ruby implementation — DSL, IR, runtime, generators, CLI
├── rust/            Rust implementation — bluebook parser, heki store, daemons
├── parity/          byte-identical IR proof between Ruby and Rust
├── examples/        runnable demo domains for every target
├── tooling/         git hooks, install scripts
└── docs/            prose — usage, papers, milestones, decisions
```

The framework's own anatomy is described in `chapters/` — twelve Bluebook files, parsed by the same parsers your domain is.

---

## Documentation

- **[DSL Reference](docs/usage/dsl_reference.md)** — every Bluebook construct
- **[Bluebook on a Napkin](docs/napkin.md)** — the five rules
- **[Usage docs](docs/usage/)** — one runnable doc per feature
- **[Architecture Tour](docs/usage/architecture_tour.md)** — how the pieces fit
- **[Architecture Decisions](docs/usage/architecture_decisions.md)** — why they fit that way
- **[Papers](docs/papers/prior_use/)** — DDD validation, MCP, Futamura, cascade lockdown, parity
- **[Covenant](docs/covenant.md)** — the principles encoded as defaults
- **[FEATURES.md](FEATURES.md)** — full feature index with usage links

---

## Contributing

After cloning, install the git hooks so drift can't land :

```bash
tooling/install-hooks
```

The pre-commit gate runs in roughly a second and blocks on :

- Test-suite failures (Ruby specs and Rust `cargo test --lib`)
- Parity drift between the Ruby and Rust IR (only **unexpected** drift ; known gaps live in `parity/known_drift.txt`)
- File-size regressions (200-line code-only ceiling)
- Antibody failures (scripts that should be Bluebook)

Run the suites manually :

```bash
ruby -Iruby parity/parity_test.rb              # Ruby ↔ Rust IR parity
ruby -Iruby parity/hecksagon_parity_test.rb    # Hecksagon parity
cargo test --lib --manifest-path rust/Cargo.toml
ruby -Iruby spec/                              # Ruby behavior
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The Apache 2.0 license grants you a perpetual, worldwide, no-charge, royalty-free license to use, modify, and redistribute Hecks. You must preserve the copyright notice, the NOTICE file, and the license text in any redistribution, and mark any modified Hecks files as changed. Apache 2.0 also includes an explicit patent grant covering contributions made to Hecks.
