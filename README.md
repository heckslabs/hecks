<p align="center">
  <img src="hecks_logo.png" width="200" height="200" alt="Hecks">
</p>

# Hecks

**A domain compiler for Ruby.** Describe your business in a five-rule DSL — the *Bluebook* — and Hecks generates the running runtime by construction. The description and the running code are byte-identical by design ; there is no layer of glue between what you wrote and what runs.

You get aggregates, events, lifecycles, queries, validations, a web explorer, behavioral tests, and a generated app — Ruby, Rails, Go, or Sinatra. You own the output.

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

That's the source of truth. Boot it, dispatch a command, watch an event:

```ruby
require "hecks"
app = Hecks.boot(__dir__)
account = app.Account.create
app.Account.deposit(account_id: account.id, amount: 50.0)
# => DepositedAccount { balance: 50.0 }
```

The whole language is five rules. **[Bluebook on a Napkin →](docs/napkin.md)**

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

Hecks ships two parsers — a Ruby DSL (`ruby/`) and a Rust runtime (`rust/`) — held to byte-identical IR by a parity suite. Most workflows only use the gem; the `hecks-life` binary becomes useful when you start authoring behavioral tests or running validators outside Ruby.

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

A complete domain looks like this:

```ruby
Hecks.bluebook "Bookshelf" do
  aggregate "Book" do
    attribute :title,  String
    attribute :author, String
    attribute :status, String, default: "available" do
      transition "CheckOutBook" => "checked_out"
      transition "ReturnBook"   => "available"
    end

    validation :title,  presence: true
    validation :author, presence: true

    command "AddBook" do
      attribute :title,  String
      attribute :author, String
    end

    command "CheckOutBook" do
      reference_to Book
    end

    query "Available" do
      where(status: "available")
    end
  end

  aggregate "Loan" do
    reference_to Book
    attribute :borrower_name, String
    attribute :due_date,      String
    attribute :status,        String, default: "active" do
      transition "CloseLoan" => "returned"
    end

    command "CreateLoan" do
      reference_to Book
      attribute :borrower_name, String
      attribute :due_date,      String
    end
  end
end
```

The full reference is in [`docs/usage/dsl_reference.md`](docs/usage/dsl_reference.md). For each construct there's a matching usage doc under [`docs/usage/`](docs/usage/) with runnable examples.

---

## Sketch and Play

You don't have to write the file in one shot. The console builds it for you.

```bash
$ hecks new blog
$ cd blog
$ hecks console
```

```
hecks(sketch)> Post
created Post
hecks(sketch)> Post.title String
added attribute title to Post
hecks(sketch)> Post.status String, default: "draft"
added attribute status to Post
hecks(sketch)> Post.transition "PublishPost" => "published"
added transition PublishPost → published
hecks(sketch)> Post.create.title String
added attribute title to CreatePost → CreatedPost
hecks(sketch)> play!
Entering play mode (1 aggregate, 2 commands)
hecks(play)> Post.create(title: "Hello World")
=> CreatedPost { title: "Hello World", status: "draft" }
hecks(play)> Post.publish(post_id: Post.all.first.id)
=> PublishedPost { status: "published" }
hecks(play)> export
Wrote hecks_domain.rb -- the source of truth.
```

`sketch` mode mutates the in-memory IR. `play` runs commands against a fresh in-memory store. `export` writes the Bluebook. See [`docs/usage/console_tour.md`](docs/usage/console_tour.md).

---

## The Web Explorer

```ruby
hecks(play)> serve!
# Serving BlogDomain on http://localhost:9292
```

Open the browser. Create a post. Watch the lifecycle badge flip from `draft` to `published`. Add a comment — the Post dropdown shows your aggregates. Hit `/_events` for the JSON event log.

These are domain events, not framework events: `CreatedPost`, `PublishedPost`, `CreatedComment`. This is your ubiquitous language.

The explorer also runs standalone:

```bash
$ hecks serve
```

See [`docs/usage/serve_web_app.md`](docs/usage/serve_web_app.md) for routes, embedding, and customisation.

---

## Build Targets

The same Bluebook compiles to multiple targets.

**Plain Ruby:**

```ruby
require "hecks"
app = Hecks.boot(__dir__)
app.Account.deposit(account_id: id, amount: 50.0)
```

**Rails:**

```bash
$ hecks build --target rails
$ rails server
```

```ruby
class PostsController < ApplicationController
  def create
    Post.create(title: params[:title], body: params[:body])
    redirect_to posts_path
  end
end
```

Hecks owns the domain and the database; Rails owns the request cycle. No ActiveRecord. See [`docs/usage/hecks_on_rails.md`](docs/usage/hecks_on_rails.md).

**Sinatra:**

```ruby
require "sinatra"
require "blog_domain"

post "/posts" do
  Post.create(title: params[:title], body: params[:body])
  redirect "/posts"
end
```

**Go (single binary):**

```bash
$ hecks build --target go
$ ./blog serve 9292
```

Same web explorer. Same forms. Same lifecycle badges. See [`docs/usage/go_runtime_interpreter.md`](docs/usage/go_runtime_interpreter.md).

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

When you `export`, the extensions are captured in the Bluebook so the next boot reproduces them. See [`docs/usage/extension_adapter_types.md`](docs/usage/extension_adapter_types.md) and [`docs/usage/creating_extensions.md`](docs/usage/creating_extensions.md) to write your own.

---

## Behavioral Tests, For Free

Every Bluebook gets a behavioral-tests companion generated from its IR. Run them in pure memory — no database, no I/O:

```bash
$ hecks-life conceive-behaviors path/to/source.bluebook
# writes path/to/source_behavioral_tests.bluebook

$ hecks-life behaviors path/to/source_behavioral_tests.bluebook
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
hecks-life check-lifecycle <bluebook>   # unreachable transitions, undefined refs
hecks-life check-io        <bluebook>   # confirms the bluebook stays in-memory
hecks-life check-all       <bluebook>   # both at once
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

The [`examples/`](examples/) directory has runnable domains for every target:

- [`examples/bookshelf`](examples/bookshelf) — Books with lifecycle, Loans with references — the canonical first read
- [`examples/banking`](examples/banking) — Accounts, ledger entries, ports, services, invariants
- [`examples/governance`](examples/governance) — 5 bounded contexts, 14 aggregates, cross-domain policies
- [`examples/pizzas`](examples/pizzas) — Value objects and lists
- [`examples/pizzas_rails`](examples/pizzas_rails) — Same domain, Rails target
- [`examples/pizzas_static_go`](examples/pizzas_static_go) — Same domain, single Go binary
- [`examples/sinatra_app`](examples/sinatra_app) — Minimal HTTP integration
- [`examples/multi_domain`](examples/multi_domain) — Cross-context event flow

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
