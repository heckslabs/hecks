<p align="center">
  <img src="hecks_logo.png" width="200" alt="Hecks">
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

That's the source of truth. Validate it, dispatch a command against it, watch an event :

```bash
storehouse validate banking.bluebook
storehouse banking.bluebook Banking::Account.Deposit amount=50.0
# => DepositedAccount { balance: 50.0 }
```

The whole language is five rules. **[Bluebook on a Napkin →](docs/napkin.md)** · For the longer argument, see [embryonaut.ai/letter](https://embryonaut.ai/letter).

---

## Quick Start

Two implementations, one spec. The same Bluebook runs under the Rust runtime (**`storehouse`**, the default) and the Ruby DSL — pick whichever fits your stack.

### Rust — `storehouse` (the default runtime)

`storehouse` is the Rust binary in [`rust/`](rust/). It parses bluebooks, validates them, dispatches commands, runs validators and behavioral tests, and serves MCP — all from the IR.

```bash
git clone https://github.com/chrisyoung/hecks.git
cd hecks/rust
cargo build --release
# binary at target/release/storehouse — put it on your PATH
```

Validate a domain — every error includes a fix suggestion, and a valid bluebook is a runnable domain :

```bash
storehouse validate examples/banking/hecks/banking.bluebook
```

Run a self-contained, shebang-style bluebook end to end :

```bash
storehouse run examples/executable/hecks/executable.bluebook
```

Dispatch a command — a fully-qualified verb against an aggregates directory (or a single bluebook file), attributes as `key=value` pairs :

```bash
storehouse <aggregates_dir> Banking::Account.Deposit amount=50.0
# => DepositedAccount { balance: 50.0 }
```

Watch the event stream — every dispatch appends to a flat JSONL bus log ; `follow` is the dumb tail over it :

```bash
storehouse follow            # tail the whole bus
storehouse follow ShellTool  # filter to one aggregate
```

### Ruby — first-class, same Bluebook

The Ruby runtime reads the identical `.bluebook` and boots a domain in one line. Install the gem, or run from source :

```bash
gem install hecks
# or, from this repo:
bundle install
```

```ruby
require "hecks"

app = Hecks.boot(__dir__)   # finds the sibling hecks/ dir, defaults to in-memory repos

alice    = Customer.register(name: "Alice", email: "alice@example.com")
checking = Account.open(customer_id: alice.id, account_type: "checking")
Account.deposit(account_id: checking.id, amount: 50.0)
```

Run a worked example straight from the repo (`-Ilib` points Ruby at the source tree) :

```bash
ruby -Ilib examples/banking/app.rb
```

**Wire up SQLite** — swap the default in-memory repositories for persistent SQLite storage (via Sequel) with one keyword. The bluebook and your domain code don't change ; only the boot line does :

```ruby
require "hecks"

# :sqlite swaps the in-memory repos for Sequel-backed SQLite tables,
# created from the bluebook's aggregates (including join tables for lists).
app = Hecks.boot(__dir__, adapter: :sqlite)

Pizza.create(name: "Margherita", description: "Classic")
found = Pizza.find(pizza.id)   # round-trips through SQLite
```

The full runnable demo is [`examples/pizzas/sql_app.rb`](examples/pizzas/sql_app.rb).

---

## The Dispatch Convention

One address shape, everywhere :

- **Commands** are `Domain::Aggregate.Command` — PascalCase verb. e.g. `Tools::ShellTool.Bash`, `Primitive::Process.Spawn`, `Voice::Voice.Speak`.
- **Queries** are `Domain::Aggregate.snake_case` — e.g. `World::Hecks.current_state`.

The fully-qualified address is required at runtime ; short-form (`ShellTool.Bash`) is rejected. The bluebook IS the contract — any command any bluebook declares flows through the same door.

```bash
storehouse <aggregates_dir> Tools::ShellTool.Bash shell_command='ls -la'
storehouse <aggregates_dir> Primitive::Process.Spawn program=echo
```

---

## The Shape of a Hecks App

A Hecks app is a small set of declarative DSL files, each guarded by an allow-list. None of them is general-purpose Ruby — the loaders refuse anything outside the surface, so the runtime parses them and gets one canonical answer.

```
examples/pizzas/hecks/
├── pizzas.bluebook    # the domain — aggregates, commands, events
└── pizzas.hecksagon   # the wiring — which adapters
```

Larger or multi-deployment domains add a third file — a `.world` for per-deployment values :

```
hecks/
├── voice.bluebook         # the domain
├── voice.hecksagon        # the wiring shape
└── voice.world            # the deployment values
```

Each file has a single job.

### `.bluebook` — the domain

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

### `.hecksagon` — the wiring

The hecksagon names *which* adapters the domain uses. No values, no secrets, no environments — just which kinds of I/O, and which capabilities are generated. The runtime defaults to in-process memory repositories, so a bluebook runs with no wiring at all ; the hecksagon is override, not substrate.

```ruby
Hecks.hecksagon "Pizzas" do
  capabilities :crud
end
```

### When an adapter has shape — the `.world`

Adapters with real surface (commands, retry policy, hosted-API config) get a named instance in the hecksagon, bound to a bluebook command via `trigger_on`, with per-deployment values in a sibling `.world`. This is the Miette voice integration :

```ruby
# voice.hecksagon — which adapter handles which command
Hecks.hecksagon "Voice" do
  adapter :memory
  adapter :tts, name: :miette_speech do
    trigger_on "Voice.Speak"
  end
end
```

```ruby
# voice.world — per-deployment values
Hecks.world "Voice" do
  miette_speech do
    provider  :elevenlabs
    voice_id  "WwS1lF7yiubZWoroH5D5"
    model     "eleven_turbo_v2_5"
    cache_dir "~/.config/miette/audio"
  end
end
```

Swapping providers between dev and prod is a one-file change to `voice.world` ; the bluebook and hecksagon don't move. The live version is the Miette voice integration at [`miette/body/voice/`](https://github.com/chrisyoung/miette). For framework-internal examples of the same pattern, see [`adapters/auth/`](adapters/auth/) and [`runtime/server/`](runtime/server/).

---

## Two Implementations, One Spec

Hecks ships two parsers for the same Bluebook language — a Rust runtime (`rust/`, the `storehouse` binary) and a Ruby DSL (`ruby/`). Both produce a single canonical IR. A parity suite holds them to **byte-identical IR**, run on every commit ; any drift between Ruby and Rust is a structural bug, not a style difference.

```bash
cargo test --lib --manifest-path rust/Cargo.toml   # Rust runtime
ruby -Iruby parity/parity_test.rb                   # Ruby ↔ Rust IR parity
```

This is the proof that one specification can mean exactly the same thing in two languages — which means it can mean the same thing in any language a target generator emits next. A target generator is a function from the IR. The Bluebook is the input.

---

## The Bluebook DSL at a Glance

Each construct maps to a real generated thing :

| Construct | What it produces |
|----------|------------------|
| `aggregate` | Business object with typed attributes, identity, repository |
| `attribute` | Typed field with validation, default, lifecycle hooks |
| `command` | A verb that emits a domain event when dispatched |
| `lifecycle` / `transition` | State machine with guarded transitions |
| `value_object` | Frozen, immutable detail embedded in an aggregate |
| `entity` | Mutable sub-object with its own identity |
| `invariant` | Enforced on aggregate state after every change |
| `specification` | Reusable, composable predicate |
| `query` | Named, chainable query object |
| `policy` | Reacts to an event by triggering another command |
| `service` | Orchestrates multiple commands across aggregates |
| `port` | Role-based access-control boundary |

### Every keyword

The full authoring surface, grouped by where it appears :

- **Domain root** — `Hecks.bluebook` · `vision` · `category` · `entrypoint`
- **Aggregate** — `aggregate` · `identified_by` · `attribute` · `list_of(T)` · `value_object` · `entity` · `reference_to` · `command` · `query` · `view` · `lifecycle`
- **Command** — `role` · `goal` · `description` · `requires` · `given` · `emits` · `then_set` (`to:` `plus:` `append:` `increment:` `decrement:` `clamp:` `decay:` `default:`) · `then_toggle` · `then_delete`
- **Lifecycle** — `state` · `transition "Cmd" => "state", from:`
- **Policy** — `policy` · `on` · `trigger` · `correlates_by` · `from_event`
- **Query / view** — `where` · `order_by` · `limit` · `show` · `show_all` · `across` · `with`
- **Scheduled / iterating** — `every` · `starts_on` · `ends_on` · `from_iter` · `from_pm` · `dispatch` · `for_each`

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

References resolve from in-scope — no IDs in test source.

---

## Why Hecks

AI is good at writing code. It's bad at maintaining constraints across a codebase over time.

Ask a model to generate a domain layer and you'll get something that works today. Next week, someone adds a bidirectional reference. The week after, a command gets named "ProcessData." A month later, a value object holds a reference to an aggregate root. None of these are bugs — the code runs. They're architectural violations that compound silently.

Hecks catches all of them at validation time. The generated output has typed ports, event-driven policies, and bounded-context boundaries that can't be bypassed.

> Use AI to write the DSL. Use Hecks to guarantee the architecture holds.

A bad imperative draft hides its violations inside a 300-line method ; a bad Bluebook gets caught by a validator with a one-line fix. The model doesn't have to be right about generated code. It has to be right about the spec.

---

## A Covenant

Hecks is built around three principles encoded as defaults :

- **Transparency** — events are observable, state changes are auditable, nothing is hidden from the people the system affects.
- **Equity** — systems that serve without clinging. Not extracting engagement, not maximising dependency.
- **Consent** — design for the beings the software serves, not against them.

The defaults protect people. Overriding them requires a deliberate choice.

---

## Examples

The [`examples/`](examples/) directory has runnable domains :

- [`examples/pizzas`](examples/pizzas) — **start here.** Two aggregates, value objects, lifecycle, queries.
- [`examples/banking`](examples/banking) — four aggregates, value objects with invariants (Money is integer-cents, Currency is an ISO three-letter code), a policy that cascades `IssuedLoan` into `Deposit`.
- [`examples/executable`](examples/executable) — the minimal shebang-run bluebook (`storehouse run`).
- [`examples/terraform_projection`](examples/terraform_projection) — a bluebook projected to a non-code target.

---

## Documentation

**The bluebook is the documentation.** There are no separate prose docs to drift out of sync — the running spec *is* the reference. To read a domain :

```bash
storehouse tree    path/to/source.bluebook   # aggregates + commands at a glance
storehouse inspect path/to/source.bluebook   # the parsed IR
```

For full IR JSON over a tree, the MCP tools `storehouse__catalog` and `storehouse__describe_aggregate` return the canonical IR for a bluebook or a single aggregate — the same shape the runtime dispatches against.

The one prose artifact that remains is **[Bluebook on a Napkin](docs/napkin.md)** — the five rules on a single page. Everything else lives as bluebook : the framework's own anatomy is described in [`chapters/`](chapters/), parsed by the same parser your domain is, and the [`examples/`](examples/) are runnable spec. Read the corpus, or read the IR.

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
├── adapters/        wired adapters — auth and friends
├── integrations/    rails, web components, deploy
├── tools/           inbox, project management, training, inventions
├── ruby/            Ruby implementation — DSL, IR, runtime, generators, CLI
├── rust/            Rust implementation — storehouse binary, parser, heki store, daemons
├── parity/          byte-identical IR proof between Ruby and Rust
├── examples/        runnable demo domains
├── tooling/         git hooks, install scripts
└── docs/            the napkin + a milestone note + the prior-work paper
```

---

## Contributing

After cloning, install the git hooks so drift can't land :

```bash
tooling/install-hooks
```

The pre-commit gate runs in roughly a second and blocks on :

- Test-suite failures (Rust `cargo test --lib` and Ruby specs)
- Parity drift between the Ruby and Rust IR (only **unexpected** drift ; known gaps live in `parity/known_drift.txt`)
- File-size regressions (200-line code-only ceiling)
- Antibody failures (scripts that should be Bluebook)

Run the suites manually :

```bash
cargo test --lib --manifest-path rust/Cargo.toml   # Rust runtime
ruby -Iruby parity/parity_test.rb                  # Ruby ↔ Rust IR parity
ruby -Iruby spec/                                  # Ruby behavior
```

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The Apache 2.0 license grants you a perpetual, worldwide, no-charge, royalty-free license to use, modify, and redistribute Hecks. You must preserve the copyright notice, the NOTICE file, and the license text in any redistribution, and mark any modified Hecks files as changed. Apache 2.0 also includes an explicit patent grant covering contributions made to Hecks.
