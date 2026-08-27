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
invocation, including the ones `.github/workflows/ci.yml` already runs.
No CI change is needed to test the cops themselves.

Currently present:

- `lib/rubocop/cop/hecks/fallback_hash_lookup.rb` —
  `Hecks::FallbackHashLookup`. Flags `holder[a] || holder[b]` (the same
  receiver looked up by two different keys, falling back to the second
  when the first is falsy) — the shape behind 8+ real bugs already fixed
  one at a time across Tiers 1-5, because `||` cannot tell a genuinely
  stored `false` from a missing key. See that file's own header comment
  and `lib/hecks/query_specification/field_path.rb#read` for the `key?`
  -first idiom this codebase already converged on instead.
- `lib/rubocop/cop/hecks/thread_shared_ivar_mutation.rb` —
  `Hecks::ThreadSharedIvarMutation`. Flags plain `@ivar` mutation outside
  `initialize` on the thread-shared `Dispatcher`/`Registry` singletons.
- `lib/rubocop/cop/hecks/sequential_hash_rename_in_loop.rb` —
  `Hecks::SequentialHashRenameInLoop`. Flags `hash[new] = hash.delete(old)`
  inside a loop — the M27 shape (docs/audits/2026-08-10-main-bug-audit.md,
  docs/audits/2026-08-11-bug-triage.md) that lost data on any rename swap
  or chain, because each rule's write became the next rule's read target
  against the SAME hash before the pass finished.

## Wiring into the real `rubocop` run (done)

All three cops above are wired into `.rubocop.yml`'s `require:` list and
each has an `Enabled: true` stanza, so they now run as part of the same
`bundle exec rubocop -c .rubocop.yml` invocation `.githooks/pre-push`
already runs on every push — no more ad hoc `--require`/`--only` needed
to exercise them for real. `Hecks/FallbackHashLookup` carries no
`Include`/`Exclude` scoping (the `[]`/`[]` `||` shape it matches has no
legitimate use anywhere in this codebase); `Hecks/ThreadSharedIvarMutation`
is scoped via `Include` to `Dispatcher`/`Registry` alone, matching its own
stanza's comment in `.rubocop.yml`.

A full-tree run at wiring time (`bundle exec rubocop -c .rubocop.yml`)
came back with 0 offenses across all three cops — including
`Hecks/FallbackHashLookup`, whose earlier ad hoc run (see below) had
found real pre-existing instances; those were fixed by the time this
pass landed, so nothing needed an `Exclude` entry in `.rubocop_todo.yml`
alongside the new `require:` entries.

`.github/workflows/ci.yml`'s `checks:` job also now runs
`bundle exec rubocop -c .rubocop.yml` as its own step, in the same
integration pass that wired these three cops in — not only
`.githooks/pre-push`, which is opt-in per clone and bypassable with
`--no-verify`. See that step's own comment in `ci.yml` for the reasoning.
Nothing about that step is custom-cop-specific: it is the exact command
the pre-push hook already runs, picking up whatever `.rubocop.yml`
requires.

## A historical note on `bundle exec rubocop --only Hecks/FallbackHashLookup`

Before this cop was wired in, running it against the whole tree ahead of
time (`bundle exec rubocop --require
./lib/rubocop/cop/hecks/fallback_hash_lookup.rb --only
Hecks/FallbackHashLookup`) found real, PRE-EXISTING instances of this
shape that were never part of the Tiers 1-5 fix set — mostly
`settings[:key] || settings["key"]` in the storage adapters (`d1.rb`,
`heki.rb`, `lambda.rb`, `postgres.rb`, `sqlite.rb`, the era plugin's
`postgres_era.rb` and `era_resolver.rb`), plus a handful of one-off
spots (`bin/fuzz`, `lib/hecks/bluebook/dsl/word_gate.rb`,
`lib/hecks/facade/cli_door.rb`, and a few specs reading fixture hashes
by either-spelling key). Those were fixed separately (out of scope for
the cop itself), which is why wiring it in above found the tree already
clean.
