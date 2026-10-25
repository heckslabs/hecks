# Custom RuboCop cops

This project has custom, project-specific RuboCop cops living under
`lib/rubocop/cop/hecks/` — one file per cop, `RuboCop::Cop::Hecks::*`,
each guarding against a real bug class already found and fixed in this
codebase, so the NEXT instance of the same shape is caught mechanically
instead of by a future audit.

Each cop has a matching spec under `spec/rubocop/cop/hecks/*_spec.rb`
using `RuboCop::RSpec::ExpectOffense` (bundled with the `rubocop` gem
itself as `rubocop/rspec/support` — no extra dev dependency needed).
Those specs are ordinary RSpec examples: `bundle exec rspec
spec/rubocop/cop/hecks` runs them, and they already run as part of any
whole-suite `bundle exec rspec` / `bundle exec parallel_rspec spec`
invocation, including the CI jobs that run the suite.
No CI change is needed to test the cops themselves.

The cops are the files under `lib/rubocop/cop/hecks/`; `.rubocop.yml` names each one in
`require:` and gives it an `Enabled` stanza, with the `Include`/`Exclude` scope and the reason
in a comment above it. Read those two places for the current set rather than a list here. Three
that the sections below refer to:

- `Hecks::FallbackHashLookup` flags `holder[a] || holder[b]` (the same receiver looked up by two
  different keys, falling back to the second when the first is falsy), because `||` cannot tell a
  genuinely stored `false` from a missing key. See `lib/hecks/query_specification/field_path.rb#read`
  for the `key?`-first idiom this codebase converged on instead.
- `Hecks::ThreadSharedIvarMutation` flags plain `@ivar` mutation outside `initialize` on the
  thread-shared `Dispatcher`/`Registry` singletons.
- `Hecks::SequentialHashRenameInLoop` flags `hash[new] = hash.delete(old)` inside a loop, the M27
  shape (docs/audits/2026-08-10-main-bug-audit.md, docs/audits/2026-08-11-bug-triage.md) that lost
  data on any rename swap or chain.
- `Hecks::NoTransportInRuntime` holds the hecksagon boundary over `lib/hecks/runtime`,
  `lib/hecks/ports` and `lib/hecks/bluebook`: no network, shell or AWS library, no `require_relative`
  into `adapters/` or `cli/`, no `Hecks::Adapters` constant, and no `ENV`, `ARGV`, `STDIN` or
  `$stdin`. Adapters register with the runtime instead (`Ports::Loading.bootstrap_with`, an adapter's
  `dispatcher` for `dispatched_by`), `Hecks::Assembly` reads the boot's environment and installs the
  Ruby facade, and `Hecks::Switches` holds the developer toggles. `lib/hecks/runtime/adapter_namespace.rb`
  is the one excluded file: it turns a bound adapter name into its class.

## Wiring into the real `rubocop` run (done)

Every cop is wired into `.rubocop.yml`'s `require:` list with an `Enabled: true` stanza, so
each runs as part of the one `bundle exec rubocop -c .rubocop.yml` invocation that the
`rubocop` check of `lib/hecks/gate/stages.yml` runs. `.githooks/pre-push` runs that check
on every push and CI runs it as the `rubocop` gate (`.github/workflows/ci-checks.yml`), so
it is not only opt-in per clone and bypassable with `--no-verify`. The scope of each cop
(`Include`, `Exclude`) sits in its `.rubocop.yml` stanza beside the reason for it.

A cop's offense is fixed, not parked: there is no todo file.

## A historical note on `bundle exec rubocop --only Hecks/FallbackHashLookup`

Before this cop was wired in, running it against the whole tree ahead of
time (`bundle exec rubocop --require
./lib/rubocop/cop/hecks/fallback_hash_lookup.rb --only
Hecks/FallbackHashLookup`) found real, PRE-EXISTING instances of this
shape that were never part of the Tiers 1-5 fix set — mostly
`settings[:key] || settings["key"]` in the storage adapters (`d1.rb`,
`heki.rb`, `lambda.rb`, `postgres.rb`, `sqlite.rb`, the era plugin's
`postgres_era.rb` and `era_resolver.rb`), plus a handful of one-off
spots elsewhere in `lib/` and in specs that read a hash by
either-spelling key. Those were fixed separately (out of scope for
the cop itself), which is why wiring it in above found the tree already
clean.
