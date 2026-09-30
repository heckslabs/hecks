# Contributing

hecks is a language whose declarations are meant to be checked, and
that sets what a contribution should look like. The interesting bugs here
are rarely "it crashed"; they are "the declaration says one thing and
the runtime quietly did another." Read
[Verification](docs/implemented/guides/verification.md) before you
open a PR that touches the language surface, the IR, or the runtime —
it explains the four tools this project uses instead of trusting a
green suite by itself, and a PR that skips them is a PR someone else
has to re-verify by hand.

## Getting running

```sh
git clone https://github.com/heckslabs/hecks
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

Install the pre-push hook once — it's the local bar a change has to
clear before it leaves your machine, and matching it locally means you
find out here instead of in CI. It is a local check, not a review; see
[How this project is built and reviewed](#how-this-project-is-built-and-reviewed):

```sh
git config core.hooksPath .githooks
```

It runs the parallel suite, `spec/fuzzing`, the query-agreement `io`
spec, the engine-agreement check, `bin/model_check`, `bin/doc_coverage`
and `rubocop`, concurrently, and reports the results in a fixed order. Bypass with `git push --no-verify` only when you mean to,
and say why in the push (or the PR).

### Fast local iteration

The pre-push hook above is the local bar a change has to clear before it
leaves your machine — but it's not the loop you should be running on
every edit. That loop should be scoped to what you're actually
touching:

```sh
bundle exec rspec spec/foo_spec.rb        # one file
bundle exec rspec spec/foo_spec.rb:42     # one example
bundle exec rspec --only-failures         # just what was red last time
bundle exec rspec --next-failure          # the tightest red/fix/re-run loop
```

`--only-failures`/`--next-failure` need `spec_helper.rb`'s
`example_status_persistence_file_path` (already set, writes to
`tmp/rspec_examples.txt` — gitignored, per-checkout state, never
shared). A plain `bundle exec rspec` with no path already excludes
`io: true`/`fuzzing: true` (see above), so a scoped run never pays for
Postgres, a cargo build, or a property-replay sweep you're not
touching.

For a quieter local loop without touching the shared `.rspec` (kept at
`--format documentation` for CI readability), copy
`.rspec-local.example` to `.rspec-local` — RSpec auto-merges it, and
it's gitignored:

```sh
cp .rspec-local.example .rspec-local
```

One thing NOT to fight: a single example in a domain-boot-heavy spec
(one that calls `boot_in_memory` or loads a real Bluebook) measures
noticeably above the "~50ms/example" baseline `spec_helper.rb`'s own
comment cites for the fast, tag-excluded loop — closer to ~200ms,
mostly a fresh `MetaValidator` pass and registry build per example.
That's the isolation the suite is built on, not a bug to route around;
scoping to the file/example you're changing (above) is what actually
keeps the loop tight, not trying to share boot state across examples.

For `PostgresEra`-flavored (`io: true`) work, keep a local Postgres
running persistently rather than starting one per run, and create the
scratch databases once:

```sh
createdb hecks_pizzas   # examples/pizzas/bluebook/pizzas.world wires straight at this by name
CI=true bundle exec rspec spec/adapters/driven/postgres_spec.rb   # or whichever file you're on
```

`bundle exec parallel_rspec spec` (12+ workers on a typical dev
machine, ~40s for the whole non-`io`/`fuzzing` suite) is your "did I
break anything nearby" check before a push — not something to run on
every edit.

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

`bin/run` and `bin/model_check` are also subcommands of the gem's
`hecks` command, along with `docs`, `narrate`, `ir`, `stores`,
`smoke_test`, `project_diagrams`, `project_cli` and `mcp`
(`bin/hecks_mcp_door`). Those `bin/` scripts are thin wrappers over
`lib/hecks/cli/`, so a change to one goes there. The fuzzing, bench,
corpus, codemod, query IR, grammar evolve and doc reference tooling ships in
the gem but loads only when a command asks for it; `require "hecks"` loads
none of it (`spec/gemspec_packaging_spec.rb`). The gem also ships `rust/`,
without `target/`, `rust/tests/` or `rust/src/generated/`; `Build` copies it to
`.hecks/rust/<version>/` in the client project and never writes into the gem.

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
don't need a Rust toolchain to contribute Ruby-only changes — your pull
request's own CI builds and runs the conformance suite, and the merge
queue runs it again against main's current tip before anything lands. If
you do touch anything
that changes what gets generated (`rust/project/*.rb`,
`bin/project_rust`, the kernel's hand-written half under
`rust/src/kernel/`), and you have `cargo` installed, run it yourself
before you find out from CI:

```sh
bundle exec bin/project_rust examples/banking
cd rust && cargo build --release && cargo test --lib
```

## How this project is built and reviewed

This section separates what the repository and GitHub can show you from
what the maintainer says. The counts are a snapshot as of 2026-09-27 and
move with every commit.

### What the repository and GitHub show

- **Most commits are co-authored with an AI coding assistant.** Of 1,434
  commits on `main`, 987 carry a `Co-Authored-By:` trailer, and 425 of the
  425 commits in the last 30 days do, about 14 a day. Check it by counting
  `git log --format=%h`, then again with `--grep='Co-Authored-By:' -i`,
  and add `--since='30 days ago'` to either for the recent window.
- **Every change lands through a pull request and the merge queue.** The
  ruleset `merge-queue-main` is active on `main`, has no bypass actors, and
  has a merge-queue rule and a required-status-checks rule with nine
  checks. Branch protection on `main` lists the same nine. The queue
  re-runs the checks against the pull request merged onto `main`'s current
  tip (`.github/workflows/ci.yml`, header comment).
- **GitHub does not require an approving review.** Branch protection and
  the ruleset's pull-request rule both require zero approving reviews, and
  branch protection requires no code-owner review. There is no CODEOWNERS
  file. The ruleset also sets `require_extra_approval_for_unattributed_changes`;
  the API does not show whether that setting has ever triggered.
- **The recent merged pull requests carry no recorded reviews.** The last
  60 merged (#803 to #865, merged 2026-09-25 to 2026-09-27) have zero
  reviews recorded on GitHub and a single author login. Check it with
  `gh pr list --state merged --limit 60 --json number,reviews,reviewDecision`.

### What the maintainer states

These four statements are the maintainer's own. Nothing in the repository
or on GitHub enforces or records them, and they stay true only while the
maintainer keeps doing them.

1. The maintainer reads every diff before it is merged.
2. Reviews run by an AI assistant (a code-review skill, subagents) are not
   claimed as a review step, because nothing records them.
3. Zero required approvals is intentional for a repository with one
   maintainer.
4. A pull request from an outside author gets the maintainer's personal
   review before it is queued.

### What CI proves mechanically

CI proves the following about a tree, and nothing about who read it. This
is the mechanical bar, and it is separate from the maintainer's reading
above:

- the whole suite, and the fuzzing specs;
- the Postgres and Rust `io` specs, against real databases and a real Rust
  build;
- `bin/model_check`, the engine-agreement check, `bin/doc_coverage` and
  `rubocop`;
- the Ruby/Rust parity specs and the golden IR (`spec/codegen_parity_spec.rb`,
  `spec/parser_parity_spec.rb`, `spec/rust_conformance_spec.rb`,
  `spec/ir_golden_spec.rb`);
- every `ruby`-fenced block in the README and the guides, run as a doctest
  (`spec/guides_spec.rb`).

### What the pre-push hook is and is not

`.githooks/pre-push` can be bypassed with `git push --no-verify`. When it
runs and a signing key is present in the keychain, it writes an HMAC
attestation note keyed by the tree hash, and CI uses that note to skip the
checks the note names. The note is evidence that someone holding the key
ran those checks on that tree. It is not evidence that anyone reviewed the
code.

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

## Releasing

1. Bump `VERSION` in `lib/hecks/version.rb`, update the two
   `Current release:` lines in `README.md` to match (`spec/readme_version_spec.rb`
   fails until they do), and add a `CHANGELOG.md` entry, on a branch, as
   its own PR. Bump the JavaScript client to the same version in that PR
   (`npm version X.Y.Z --no-git-tag-version` in `packages/hecks-client`,
   which also updates its lockfile); `spec/hecks_client_version_spec.rb`
   fails until it matches. Label the entry as the release promise says
   ([What a release number promises](docs/1.0-readiness.md#what-a-release-number-promises)):
   a major carries a `Breaking:` entry, and a minor that changes how a
   running system behaves carries a `Behavior change` entry.
2. Once that PR merges to `main`, check out `main`, pull, and run
   `bin/release --dry-run` to see every check and build pass with nothing
   tagged or published. Then run `bin/release`. It refuses unless the
   checkout is a clean `main` equal to `origin/main`, the gem and
   `packages/hecks-client` are at one version, and `CHANGELOG.md` has a
   heading for it. It asks RubyGems and npm what is already published and
   skips that, so if a run stops partway, run it again. In order, it:
   - creates the annotated tag `vX.Y.Z` on the merge commit and pushes it;
   - runs `bin/release_gem` to build the gem and push it to rubygems.org;
   - waits for CI to publish `@hecks/client`. Pushing the tag starts
     `.github/workflows/publish-client.yml`, which publishes the package
     with npm trusted publishing (no token, no code). `bin/release` says
     so, then checks npm every 15 seconds for up to 10 minutes and reports
     success, or the timeout with the run to look at
     (`gh run list --workflow publish-client.yml`). `--no-wait` skips the
     wait.

   It asks before the tag and before publishing the gem (`--yes` answers
   for you). `--gem-only` skips the npm step; `--npm-only` skips the gem,
   so on its own it just waits for CI's publish again (use it after
   re-running the workflow with `gh workflow run publish-client.yml -f
   tag=vX.Y.Z`).

   The gem's push key comes from 1Password (`op run`, Touch ID-gated;
   `release/gem_push.env`), and its one-time setup is in the header of
   `bin/release_gem`.

   One-time setup for CI publishing, by an owner of the `@hecks` scope on
   npmjs.com, possible only once the package exists: package
   `@hecks/client` > Settings > Trusted Publisher > GitHub Actions >
   organization or user `heckslabs`, repository `hecks`, workflow filename
   `publish-client.yml`, environment blank.

   `--npm-local` is the fallback, and how the first publish is made
   (before a trusted publisher can exist): it publishes `@hecks/client`
   from this machine with a token from 1Password instead of leaving it to
   CI (with `--npm-only` it publishes only the package). The token is the
   "publish token" field on the "npmjs.com" item in the Hecks vault, next
   to the "RubyGems API Key" item (`release/npm_publish.env` names the
   vault, item and field, and can be edited). It must be a granular token
   scoped Read and write to the `@hecks` scope with "Bypass two-factor
   authentication" enabled, and short-lived: the account's second factor
   is a passkey, so a token that requires a one-time code cannot publish
   (npm answers `EOTP`). The header of `bin/release` has the setup. The
   publish passes `--auth-type=web` as an interactive fallback: if npm
   does ask for a passkey or security key, it prints an approval link and
   waits.

   `bin/release` does not create the GitHub Release. Once the tag is
   pushed, create it with the version's own `CHANGELOG.md` section as its
   notes, so the Releases page lists every tag. Mark it Latest only when it
   is the newest version:

   ```sh
   awk -v v="X.Y.Z" 'BEGIN{h="## [" v "]"} index($0,h)==1{p=1;next} /^## \[/{p=0} p' CHANGELOG.md > notes.md
   gh release create vX.Y.Z --title "hecks X.Y.Z" --notes-file notes.md --verify-tag --latest
   ```

   Manual fallback, if `bin/release` cannot be used: tag the merge commit
   (`git tag -a vX.Y.Z <sha>` and push it, which starts the CI publish),
   run `bin/release_gem`, and if CI cannot publish, run
   `npm publish --access public` in `packages/hecks-client`.
