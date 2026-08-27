# Contributing

hecks is a research language. That is not a disclaimer to skip past —
it sets what a contribution should look like. The interesting bugs here
are rarely "it crashed"; they are "the declaration says one thing and
the runtime quietly did another." Read
[Verification](docs/implemented/guides/verification.md) before you
open a PR that touches the language surface, the IR, or the runtime —
it explains the four tools this project uses instead of trusting a
green suite by itself, and a PR that skips them is a PR someone else
has to re-verify by hand.

## Getting running

```sh
git clone https://github.com/chrisyoung/hecks
cd hecks
bundle install
bin/console          # boots the pizzas example, drops you into IRB with its door installed
```

Postgres is optional for most of the codebase — the suite and
`bin/console` both default to the in-memory adapter. You only need a
local Postgres for `PostgresEra`-flavored specs and the schema-evolution
guide's own live example; those specs check their own reachability and
skip themselves quietly if nothing answers on `localhost`.

## Running the suite

```sh
bundle exec rspec                 # the whole suite
bundle exec parallel_rspec spec   # same suite, split across your machine's cores
bundle exec rubocop -c .rubocop.yml
```

`.rubocop.yml` is tuned to this codebase's own established style —
long, deliberate prose comments, `module_function`-heavy modules,
Struct-based value types, comfortably long lines — not to force a
generic rewrite. Read a neighboring file before fighting a cop; the
answer is usually "match what's already here," and anything genuinely
pre-existing and out of scope lives in `.rubocop_todo.yml` rather than
being silently disabled.

Two tags are excluded from a plain `rspec` run and worth knowing about
before you assume a red suite everywhere:

- `fuzzing: true` — `spec/fuzzing/`, live-generated-history replays,
  ~18-20s on their own. Run with `bundle exec rspec spec/fuzzing --tag
  fuzzing`.
- `io: true` — real Rust builds, real Postgres, deploy-contract specs.
  CI runs these; locally, `bundle exec rspec spec/adapters/query_agreement_spec.rb
  --tag io` is the one cheap enough to run by hand (see its own header
  for why it earns a slot pre-push and the rest don't).

Install the pre-push hook once — it's the actual bar a change has to
clear before it leaves your machine, and matching it locally means you
find out here instead of in CI:

```sh
git config core.hooksPath .githooks
```

It runs, in order: the parallel suite, `spec/fuzzing`, the query-
agreement `io` spec, `bin/model_check`, `bin/doc_coverage`, and
`rubocop`. Bypass with `git push --no-verify` only when you mean to,
and say why in the push (or the PR).

## Verification beyond the suite

A green suite only proves the paths someone thought to write. Before a
PR that touches a `.bluebook`, the DSL builder, the runtime, or the
IR:

```sh
bin/model_check                          # static analysis over the IR — unreachable states,
                                          # dead transitions, sagas nothing reaches
bin/fuzz                                  # generated command/query sequences, checked against
                                          # declared properties and interpreter crashes
bin/doc_coverage                          # every live DSL word ships with a running example
bin/run examples/banking spec/corpus/banking.json   # the refusals someone already decided must hold
```

`spec/ir_golden_spec.rb` freezes the builder's `to_h` output per corpus
member. If your change is a deliberate shape change (not a bug), you
regenerate it explicitly and read the diff before trusting it — it's a
claim about the wire format, not a routine refresh:

```sh
GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb
```

**Docs are tests.** Every `ruby`-fenced block in the README and in
`docs/implemented/guides/` runs for real, against a real booted domain
— `spec/guides_spec.rb` is the harness. If you edit one of those code
fences, `bundle exec rspec spec/guides_spec.rb` either passes or tells
you the prose lied.

**Rust.** `rust/` is a second dispatch runtime, generated from the same
canonical IR and checked against Ruby continuously
(`spec/codegen_parity_spec.rb`, `spec/rust_conformance_spec.rb`). You
don't need a Rust toolchain to contribute Ruby-only changes — CI builds
and runs the conformance suite on every push. If you do touch anything
that changes what gets generated (`rust/project/*.rb`,
`bin/project_rust`, the kernel's hand-written half under
`rust/src/kernel/`), and you have `cargo` installed, run it yourself
before you find out from CI:

```sh
bundle exec bin/project_rust examples/banking
cd rust && cargo build --release && cargo test --lib
```

## What a PR should include

- Tests. A new keyword, argument, or resolution rule needs a corpus
  example or a spec exercising it, not just a passing existing suite.
- `bundle exec rubocop -c .rubocop.yml` clean.
- If you touched a `.bluebook` file that ships as part of the
  language's own definition (`lib/hecks/language/`) or added a DSL
  word: `bin/doc_coverage` clean, and a real prose section in
  `docs/implemented/reference/` — not the `TODO` sentinel — with a
  runnable example.
- If you touched a lifecycle, saga, or policy: `bin/model_check` clean.
- A short note on *why*, not just *what* — this repo's own comments
  (Gemfile, `.rubocop.yml`, `.githooks/pre-push`) are the house style
  for that: explain the reasoning that would otherwise get silently
  reverted by someone who didn't have it.

Small, single-purpose PRs are easier to verify against all of the
above than one that reshapes several things at once. If a change
touches the language surface itself — new syntax, not just new
behavior behind existing syntax — read
[Extending Hecks](docs/implemented/guides/extending-hecks.md) first;
a new word is a declared row (`proposed → admitted`) before it's a
line of Ruby, and skipping that ordering is the most common way a
first PR here goes sideways.

## Where to start

- [Getting started](docs/implemented/guides/getting-started.md) — the
  whole shape of the language in one sitting.
- [Extending Hecks](docs/implemented/guides/extending-hecks.md) — how a
  new DSL word gets added without breaking every `.bluebook` that
  already boots.
- [`docs/decisions/`](docs/decisions/) and
  [`docs/implemented/decisions/`](docs/implemented/decisions/) — one
  document per architectural decision; read the relevant ones before
  arguing with a design choice that was already made deliberately.
- [`docs/HECKS_IMPLEMENTATION_PLAN.md`](docs/HECKS_IMPLEMENTATION_PLAN.md)
  — the full architecture in one document.

If you're not sure whether an idea fits before writing any code, open
an issue first — see the templates under `.github/ISSUE_TEMPLATE/`.
