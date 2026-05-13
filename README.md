<p align="center">
  <img src="una.png" width="200" alt="Una, the Embryonaut brand mark">
</p>

# What the Hecks?

**Hecks is executable specifications, not a translation.** Describe your domain in the *Bluebook* — Hecks's specification language — and the running program is the spec. There is no translation layer between what you wrote and what runs ; no documentation that can lie to you. The Bluebook IS the program.

Two claims structure the work :

- *Specification is king.* The Bluebook is the contract. Validators, immune-system hooks, and parity gates make the discipline structural — the team does not have to remember it, the runtime does.
- *Building software correctly is fast.* The trade-off between speed and correctness is a category error. With no translation step to slip through, the spec compiles, the runtime obeys, and the rework cycle that consumes most engineering hours disappears.

Hecks ships two compatible implementations — a Rust runtime (`storehouse`) and a Ruby library — held to byte-identical IR by a parity suite. From the same Bluebook you generate Ruby, Rails, Sinatra, or a single Go binary. You get aggregates, events, lifecycles, validators, behavioral tests, and an MCP server for AI-native modelling. You own the output.

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

The whole language is five rules. **[Bluebook on a Napkin →](docs/napkin.md)** · For the longer argument, see the open letter at [embryonaut.ai/letter](https://embryonaut.ai/letter).

---

## Install

```bash
gem install hecks
```

Or from source:

```bash
git clone https://github.com/chrisyoung/hecks.git
cd hecks
bundle install
```

Hecks ships two parsers — a Ruby DSL (`ruby/`) and a Rust runtime (`rust/`) — held to byte-identical IR by a parity suite. Most workflows only use the gem; the `storehouse` binary becomes useful when you start authoring behavioral tests or running validators outside Ruby.

**[Getting Started — zero to a running domain in 10 minutes](docs/getting_started.md)**

---

## The Bluebook DSL

A Bluebook describes one bounded context. Each construct maps to a real generated thing:

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

A complete domain looks like this. The `Banking` bluebook is in [`examples/banking/hecks/banking.bluebook`](examples/banking/hecks/banking.bluebook) ; it carries four aggregates (Customer, Account, Transfer, Loan), value objects with invariants (Money is integer-cents, never Float ; Currency is an ISO three-letter code), an entity for ledger lines, lifecycles, commands, validations, specifications, and a policy that cascades an `IssuedLoan` event into a `Deposit` :

```ruby
Hecks.bluebook "Banking" do
  aggregate "Customer" do
    attribute :name,  PersonName
    attribute :email, EmailAddress

    value_object "PersonName" do
      attribute :given,  String
      attribute :family, String
      invariant("given name present")  { given  && !given.strip.empty?  }
      invariant("family name present") { family && !family.strip.empty? }
    end

    value_object "EmailAddress" do
      attribute :address, String
      invariant("must contain @")          { address.include?("@") }
      invariant("must contain domain dot") { address.split("@", 2).last.to_s.include?(".") }
    end

    lifecycle :status, default: "active" do
      transition "SuspendCustomer"  => "suspended"
      transition "ReinstateCustomer" => "active"
    end

    command "RegisterCustomer"  do attribute :name, PersonName; attribute :email, EmailAddress end
    command "SuspendCustomer"   do reference_to Customer end
    command "ReinstateCustomer" do reference_to Customer end
  end

  aggregate "Account" do
    reference_to Customer
    attribute :balance,      Money
    attribute :account_type, AccountType
    attribute :daily_limit,  Money
    attribute :ledger,       list_of(LedgerEntry)

    # Money is currency-aware, integer-cents — never Float.
    # IEEE 754 rounding has no place in a ledger.
    value_object "Money" do
      attribute :cents,    Integer
      attribute :currency, Currency
      invariant("non-negative for balance contexts") { cents >= 0 }
    end

    value_object "Currency" do
      attribute :code, String
      invariant("ISO 4217 three-letter code") { code.length == 3 && code == code.upcase }
    end

    value_object "AccountType" do
      attribute :name, String
      invariant("checking, savings, or money_market") { %w[checking savings money_market].include?(name) }
    end

    entity "LedgerEntry" do
      attribute :amount,      Money
      attribute :description, Description
      attribute :entry_type,  EntryType
      attribute :posted_at,   Timestamp
    end

    lifecycle :status, default: "open" do
      transition "CloseAccount" => "closed"
    end

    command "OpenAccount" do
      reference_to Customer
      attribute :account_type, AccountType
      attribute :daily_limit,  Money
    end
    command "Deposit"      do reference_to Account; attribute :amount, Money end
    command "Withdraw"     do reference_to Account; attribute :amount, Money end
    command "CloseAccount" do reference_to Account end

    specification "LargeWithdrawal" do |withdrawal|
      withdrawal.amount.cents > 1_000_000  # $10k
    end
  end

  aggregate "Transfer" do
    reference_to Account, as: :source
    reference_to Account, as: :destination
    attribute :amount, Money
    attribute :memo,   Memo

    value_object "Memo" do
      attribute :text, String
      invariant("under 280 chars") { text.nil? || text.length <= 280 }
    end

    lifecycle :status, default: "pending" do
      transition "CompleteTransfer" => "completed"
      transition "RejectTransfer"   => "rejected"
    end

    command "InitiateTransfer" do
      reference_to Account, as: :source
      reference_to Account, as: :destination
      attribute :amount, Money
      attribute :memo,   Memo
    end
    command "CompleteTransfer" do reference_to Transfer end
    command "RejectTransfer"   do reference_to Transfer end
  end

  aggregate "Loan" do
    # The Customer is reached via loan.account.customer_id ; one path
    # through the graph means there is nothing to disagree with.
    reference_to Account
    attribute :principal,         Money
    attribute :rate,              InterestRate
    attribute :term,              Term
    attribute :remaining_balance, Money

    # Rate as basis points (525 = 5.25%) — Float APRs are a
    # round-tripping nightmare in interest accrual.
    value_object "InterestRate" do
      attribute :basis_points, Integer
      invariant("between 0 and 10000 bps") { basis_points >= 0 && basis_points <= 10000 }
    end

    value_object "Term" do
      attribute :months, Integer
      invariant("positive duration") { months > 0 }
    end

    lifecycle :status, default: "active" do
      transition "DefaultLoan" => "defaulted"
      transition "PayOffLoan"  => "paid_off"
    end

    command "IssueLoan" do
      reference_to Account
      attribute :principal, Money
      attribute :rate,      InterestRate
      attribute :term,      Term
    end
    command "MakePayment" do reference_to Loan; attribute :amount, Money end
    command "DefaultLoan" do reference_to Loan end
    command "PayOffLoan"  do reference_to Loan end

    specification "HighRisk" do |loan|
      loan.principal.cents > 5_000_000 && loan.rate.basis_points > 1000
    end
  end

  # Funds disburse into the loan's referenced account. Because Loan only
  # references Account (not Customer directly), the cascade cannot
  # mis-route to a different customer's account.
  policy "DisburseFunds" do
    on      "IssuedLoan"
    trigger "Deposit"
    map     account_id: :account_id, principal: :amount
  end
end
```

The full reference is in [`docs/usage/dsl_reference.md`](docs/usage/dsl_reference.md). For each construct there's a matching usage doc under [`docs/usage/`](docs/usage/) with runnable examples.

---

## Two Implementations, One Spec

Hecks ships two parsers for the same Bluebook language : a Ruby DSL (`ruby/`) and a Rust runtime (`rust/`, the `storehouse` binary). Both produce a single canonical IR. A parity suite holds them to **byte-identical IR**, run on every commit ; any drift between Ruby and Rust is a structural bug, not a style difference.

```bash
$ ruby -Iruby parity/parity_test.rb           # Ruby ↔ Rust IR parity
$ cargo test --lib --manifest-path rust/Cargo.toml
```

This matters because it's the proof that one specification can mean exactly the same thing in two languages — which means it can mean the same thing in any language a generator targets next. A target generator is a function from the IR ; Ruby and Rust are the first two outputs. The Bluebook is the input.

`storehouse` is the canonical runtime today : it parses bluebooks, dispatches commands, runs validators, conceives companions, executes behavioral tests, and runs MCP. The Ruby gem is the convenient embedding for Ruby projects. See [`docs/usage/architecture_tour.md`](docs/usage/architecture_tour.md).

---

## Extensions

Persistence and integrations layer on at runtime — one line each, no migrations to write, no reboot.

```ruby
extend :sqlite                              # local file
extend :postgres                            # production
extend :tenancy                             # multi-tenant scoping
extend :slack,    webhook: ENV["SLACK_URL"] # event notifications
extend :queue,    adapter: :rabbitmq        # publish events
extend :outbox                              # transactional outbox
extend :scheduler                           # cron policies
```

Extensions are declared in the Bluebook and boot alongside the domain. See [`docs/usage/extension_adapter_types.md`](docs/usage/extension_adapter_types.md) and [`docs/usage/creating_extensions.md`](docs/usage/creating_extensions.md) to write your own.

---

## Behavioral Tests, For Free

Every Bluebook gets a behavioral-tests companion generated from its IR. Run them in pure memory — no database, no I/O:

```bash
$ storehouse conceive-behaviors path/to/source.bluebook
# writes path/to/source_behavioral_tests.bluebook

$ storehouse behaviors path/to/source_behavioral_tests.bluebook
# 12 tests · 12 passed · 0 failed
```

The test DSL is itself a Bluebook, sibling to `Hecks.bluebook`:

```ruby
Hecks.behaviors "Bookshelf" do
  test "CheckOutBook flips status to checked_out" do
    setup  "AddBook", title: "Dune", author: "Herbert"
    tests  "CheckOutBook", on: "Book"
    expect status: "checked_out"
  end
end
```

References resolve from in-scope — no IDs in test source. The cascade-aware planner follows policy chains so tests assert on the final state. Three validators stack on top:

```bash
storehouse check-lifecycle <bluebook>   # unreachable transitions, undefined refs
storehouse check-io        <bluebook>   # confirms the bluebook stays in-memory
storehouse check-all       <bluebook>   # both at once
```

See [`docs/usage/behavioral_tests.md`](docs/usage/behavioral_tests.md).

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
| `PolicyWiring` | Triggered commands exist; emitted events are real |
| `PortConsistency` | Port-allowed methods exist on the aggregate |
| + more | Name collisions, reserved words, value-object purity, structural shape |

```bash
$ hecks validate
```

See [`docs/usage/specialize_validator.md`](docs/usage/specialize_validator.md) and the validator entries in [`FEATURES.md`](FEATURES.md) for the full list.

---

## AI-Native

Hecks ships an MCP server so Claude (or any MCP client) can model domains alongside you.

```bash
$ hecks mcp
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

Three domains talking through events. Upload a photo, a draft post appears. The event log shows the chain: `UploadedPhoto → AutoDraft → CreatedDraftPost`. See [`docs/usage/mcp_runtime_from_ir.md`](docs/usage/mcp_runtime_from_ir.md) and [`docs/usage/mcp_visible_output.md`](docs/usage/mcp_visible_output.md).

---

## Why Hecks

AI is good at writing code. It's bad at maintaining constraints across a codebase over time.

Ask Claude to generate a domain layer and you'll get something that works today. Next week, someone adds a bidirectional reference. The week after, a command gets named "ProcessData." A month later, a value object holds a reference to an aggregate root. None of these are bugs — the code runs. They're architectural violations that compound silently.

Hecks catches all of them at build time. The generated output has typed ports, event-driven policies, and bounded-context boundaries that can't be bypassed.

> Use AI to write the DSL. Use Hecks to guarantee the architecture holds.

For the longer argument, see [`docs/why_hecks.md`](docs/why_hecks.md), [`docs/ddd.md`](docs/ddd.md) (DDD mapping), and [`docs/hexagonal.md`](docs/hexagonal.md) (hexagonal architecture mapping).

---

## A Future Where AI Writes in Specs

Today's models are trained on empirical languages — Ruby, Python, Go, JavaScript — discovered through millions of human iterations, full of accidental complexity, unspoken conventions, and behaviour the language itself can't constrain. The model learns the surface and infers the architecture from a corpus that disagrees with itself.

A specification language flips this. The Bluebook is small enough to learn completely. Its grammar is finite. Its rules — what an aggregate is, why a value object can't reference an aggregate root, what a policy emits — are *declared*, not absorbed. An AI that writes a Bluebook writes intent directly, then watches that intent compile into Ruby, Rails, Go, or the next runtime someone targets. The mistakes change shape too: a bad imperative draft hides its violations inside a 300-line method ; a bad Bluebook gets caught by a validator with a one-line fix. The model doesn't have to be right about generated code. It has to be right about the spec.

Hecks bets on this direction. The Bluebook is the source of truth ; code is generation ; correctness is decidable at the spec level before a line of runtime exists. Two implementations (Ruby and Rust) held to byte-identical IR are not a curiosity — they're the proof that one specification can mean exactly the same thing in two languages, which means it can mean the same thing in any language a generator targets next. We're shipping in a way that's compatible with a near future where the AI's working language isn't a programming language at all. It's a spec.

For the technical argument behind this — DDD validation, MCP-native modelling, the Futamura projection that lets Hecks specialise itself, cascade lockdown, language-neutral parity — see [`docs/papers/prior_use/`](docs/papers/prior_use/).

---

## A Covenant

Hecks is built around three principles encoded as defaults:

- **Transparency** — events are observable, state changes are auditable, nothing is hidden from the people the system affects.
- **Equity** — systems that serve without clinging. Not extracting engagement, not maximising dependency.
- **Consent** — design for the beings the software serves, not against them.

The defaults protect people. Overriding them requires a deliberate choice. See [`docs/covenant.md`](docs/covenant.md).

---

## Examples

The [`examples/`](examples/) directory has runnable domains for every target :

- [`examples/banking`](examples/banking) — the canonical first read. Four aggregates, value objects with invariants, an entity, a cross-aggregate policy. The example from the section above.
- [`examples/bookshelf`](examples/bookshelf) — Books with lifecycle, Loans with references. The simplest two-aggregate domain.
- [`examples/governance`](examples/governance) — 5 bounded contexts, 14 aggregates, cross-domain policies.
- [`examples/pizzas`](examples/pizzas) — Value objects and lists.
- [`examples/pizzas_rails`](examples/pizzas_rails) — Same domain, Rails target.
- [`examples/pizzas_static_go`](examples/pizzas_static_go) — Same domain, single Go binary.
- [`examples/pizzas_static_ruby`](examples/pizzas_static_ruby) — Same domain, standalone Ruby.
- [`examples/sinatra_app`](examples/sinatra_app) — Minimal HTTP integration.
- [`examples/multi_domain`](examples/multi_domain) — Cross-context event flow.
- [`examples/llm_adapter`](examples/llm_adapter) — LLM-backed adapter wired through Hecks ports.
- [`examples/shell_adapter`](examples/shell_adapter) — Shell-command adapter.

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

The framework's own anatomy is described in `chapters/` — twelve Bluebook files, parsed by the same parsers your domain is. If you want the deep version of how that works, the prior-use papers in [`docs/papers/prior_use/`](docs/papers/prior_use/) cover validation, MCP, the Futamura projection, cascade lockdown, and language-neutral parity.

---

## Documentation

- **[Getting Started](docs/getting_started.md)** — first 10 minutes
- **[DSL Reference](docs/usage/dsl_reference.md)** — every Bluebook construct
- **[Usage docs](docs/usage/)** — one runnable doc per feature
- **[Architecture Tour](docs/usage/architecture_tour.md)** — how the pieces fit
- **[Architecture Decisions](docs/usage/architecture_decisions.md)** — why they fit that way
- **[Papers](docs/papers/prior_use/)** — DDD validation, MCP, Futamura, cascade lockdown, parity
- **[Covenant](docs/covenant.md)** — the principles encoded as defaults
- **[FEATURES.md](FEATURES.md)** — full feature index with usage links

---

## Contributing

After cloning, install the git hooks so drift can't land:

```bash
$ tooling/install-hooks
```

The pre-commit gate runs in roughly a second and blocks on:

- Test-suite failures (Ruby specs and Rust `cargo test --lib`)
- Parity drift between the Ruby and Rust IR (only **unexpected** drift; known gaps live in `parity/known_drift.txt`)
- File-size regressions (200-line code-only ceiling)
- Antibody failures (scripts that should be Bluebook)

Run the suites manually:

```bash
$ ruby -Iruby parity/parity_test.rb           # Ruby ↔ Rust IR parity
$ ruby -Iruby parity/hecksagon_parity_test.rb # Hecksagon parity
$ cargo test --lib --manifest-path rust/Cargo.toml
$ ruby -Iruby spec/                           # Ruby behavior
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow, branch conventions, and PR template.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The Apache 2.0 license grants you a perpetual, worldwide, no-charge,
royalty-free license to use, modify, and redistribute Hecks. You must
preserve the copyright notice, the NOTICE file, and the license text
in any redistribution, and mark any modified Hecks files as changed.
Apache 2.0 also includes an explicit patent grant covering
contributions made to Hecks.
