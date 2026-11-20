# Specs, comments, RuboCop and generated output in full

Read this when a spec run, a comment check, a RuboCop offense or a generated file surprises you.
`CLAUDE.md` holds the short rules; this holds the detail.

## Running specs

Run a spec file through the launcher, which is the sanctioned path (see "Use the
hecks binary" below):

```sh
exe/hecks test_suite_run.run_spec_example! \
  file.value=spec/doc_banners_spec.rb "example.value= " --wait
```

`example.value` filters on the full example description; a single space matches
every example. The report ends with the example and failure counts. Hecks runs in Memory
unless a local hecksagon opts it into PostgresEra (ADR 0136), so the run needs no database and no
environment variable. Memory changes some behavior: two guide examples that retry a payment
(`commands.md`, `policies-and-process-managers.md`) fail under it.

**A spec never touches the owner's live state.** The Memory overlay switches the runtime's event tap
off, spec_helper points a child's tap at the run's own temporary file (`HECKS_EVENT_TAP`), and
`spec/support/live_state_guard.rb` fails by name a spec that opens the live tap
(`~/.claude/hecks-dev/events.jsonl`), reaches the checkout's own red flag (`.git/hecks-red-flag.json`)
or moves it during an example; `spec/support/live_ledger_guard.rb` does the same for the ticket and
agent-run databases. A spec that needs a repository, a flag or a tap builds its own under a temporary
directory and names it (`checkout:`, a world with a temporary `event_tap` path).

Several files cost one launcher boot, not one each:
`exe/hecks test_suite_run.run_spec_files! "files.value=spec/a_spec.rb spec/b_spec.rb" --wait` reports each
file's counts and a total, and fails naming the files that failed. `isolation.value=process` (the default)
gives each file a new process; `isolation.value=shared` runs all in one, fastest, and may expose order
dependence. `exe/hecks test_suite_run.run_impacted_specs! --wait` runs the specs the push rehearsal's
map names for your branch against local `main` (`base.value=`, `cap.value=`, `dry.value=true` lists
them without running).

**The full spec suite runs only in CI** (the Vocabulary `rspec` check is `runs_in: "ci"`). Locally run the
quick gate and named specs: `run_suite!` is refused by name, and `run_spec_files!` and `run_impacted_specs!`
run every file they are given, with no cap per call; CI is detected from the environment.

**Verify before you land, and the landing verifies again.** Run the specs you touched and the quick gate
before you submit. The landing runs the quick gate and the specs your change impacts, and refuses on red
(`LandingRefused`); the full suite still runs only in CI. Nothing here tells a session to skip tests
before landing.

A session isolated in a git worktree has had `bundle exec` with the spec runner
refused with "too complex to verify that it stays inside the worktree", while
`cargo test`, `bundle exec ruby`, `git` and `gh` ran. A commit message and a
script body that merely named the runner or git were refused too, so the guard
may be matching on the command text. Use the launcher form above, not a wrapper
script around the refused command.

Comments you write in this repository's Ruby (`lib/`, `spec/`,
`examples/`) must match `docs/COMMENT_STYLE_GUIDE.md`. In particular:

- No all-caps lead-ins for emphasis — use `**bold**` instead
  (`docs/COMMENT_STYLE_GUIDE.md` section 5).
- No design history in comments ("used to", "previously", "before this
  change", PR numbers) — state the system as it is now and keep the
  reason (section 4).
- Public methods carry YARD tags (section 1); a class or module
  comment says what it is, not what it contains (section 2).
- Comment lines stay under 100 characters (section 6).

Check a tree with `exe/hecks style_run.check_comments! paths=<path> --wait` before
calling comment work done. The pre-push gate's `comment_style` check covers `lib/hecks` and `spec`,
so a violation is caught before a push, whichever agent wrote the comment.
## RuboCop is strict: it runs at its defaults

`.rubocop.yml` overrides only what `docs/decisions/0091-rubocop-defaults-with-deliberate-overrides.md`
lists, so every other cop runs at the RuboCop default, new cops included. The pre-push gate and CI
run it over the whole repository, specs too, and one offense blocks the push. Write code that
passes the first time:

- **Metrics are on.** A method is at most 10 lines, with ABC size 17, cyclomatic complexity 7 and
  at most 5 parameters; a class or module is at most 100 lines. Do not write one long method and
  a `# rubocop:disable`: extract named helpers or a collaborator class, because the extraction is
  usually the better design. Raising a limit in `.rubocop.yml` needs an ADR 0091 entry; do not do it
  to land a change.
- **Specs are held to it as well.** An example is at most 5 lines and holds one expectation, so a
  multi-step example is tagged `:aggregate_failures` (see `spec/hecks_codebase_adr_rows_spec.rb`)
  and its setup goes into a helper method; at most 5 `let`s per group (a plain method is not
  counted); prefer `receive` and `have_received` over a bare expectation on a message
  (`RSpec/MessageSpies`).
- **Style is set, not chosen.** Double quotes everywhere, including inside interpolation
  (`"#{lane["name"]}"`, never `'name'`), table-aligned hashes, and 130 columns for code.
- **Check before you push:** `bundle exec rubocop <files>` while you work, `bundle exec rubocop`
  for the whole tree, and `bundle exec rubocop -a <files>` for the offenses it can fix itself (it
  fixes style, not metrics). Run it in a clean checkout before you call work done: a `.gitignore`
  entry can hide a file in your tree that a fresh clone will not have.

## Never hand-edit generated output

- A file starting with a `# Generated ... do not edit` (Ruby) or
  `// GENERATED by ...` (Rust) banner is produced by a script. Fix the
  generator or its source, then re-run the generator — never edit the
  output directly, even to shorten a comment.
- The same holds for a golden/pinned test fixture (for example
  `spec/fixtures/*_golden/`): it is compared byte-for-byte against a
  generator's own output, and the generator that produces it is
  usually left untouched by a comment-only pass. Editing the fixture
  on its own makes it drift from what the generator actually emits and
  fails the spec that pins it. If a golden fixture's content is wrong,
  fix the generator (or its heredoc-embedded template text) and
  regenerate; never edit the committed fixture by hand.
- `exe/hecks regeneration_run.regenerate_corpus! --check` (and the other regen scripts
  `.github/workflows/ci-checks.yml`'s `checks_codegen_drift` job runs)
  catch drift between a generator and its committed output.
