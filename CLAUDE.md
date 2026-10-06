# CLAUDE.md

## Session isolation: jj workspaces, not git worktrees

Root is a colocated jj+git repo. Use `jj workspace add <path>` for a new
session's checkout instead of `git worktree add`; retire with
`jj workspace forget <name>` and remove the directory.

Push with `git push`, not `jj git push` — jj bypasses git hooks, so
`.githooks/pre-push` (rspec, fuzzing, model_check, rubocop, CI
attestation) wouldn't run. Colocation keeps bookmarks synced to git
branches, so plain `git push` still works.

## Running specs

Run a spec file through the launcher, which is the sanctioned path (see "Use the
hecks binary" below):

```sh
HECKS_ENVIRONMENT=memory exe/hecks test_suite_run.run_spec_example! \
  file.value=spec/doc_banners_spec.rb "example.value= " --wait
```

`example.value` filters on the full example description; a single space matches
every example. The report ends with the example and failure counts. Without
`HECKS_ENVIRONMENT=memory` it needs a local Postgres `hecks` database. The memory
environment changes some behavior: two guide examples that retry a payment
(`commands.md`, `policies-and-process-managers.md`) fail under it.

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

Check a tree with `exe/hecks style_run.check_comments paths=<path> --wait` before
calling comment work done.

## Use the hecks binary

Repo tasks run through the `hecks` binary (`exe/hecks` in a checkout), not
ad-hoc Ruby, shell one-offs, or hand-written scripts. It is a launcher
whose commands and queries are projected from the bluebooks, so it is the
current list of what this repo can do.

- `exe/hecks` lists every command and query; `exe/hecks <command> --help`
  says what one wants and how it refuses.
- `exe/hecks <command>! name=value …` does something;
  `exe/hecks query <query> name=value …` reads something.
- Before writing a script, look for the command that already does it
  (projections, regeneration, style checks, model_check, smoke tests).
  If none exists, add the command to the bluebook rather than a script.
- Add `--wait` when you need the result before the next step.

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

## Two lanes: `main` takes pushes, `stable` is promoted

The branches are data: the `Lane` rows of the Vocabulary chapter
(`lib/hecks/language/bluebook/vocabulary.bluebook`), with the checks a
commit must pass as `RequiredCheck` rows beside them.

- **`main` has no guard.** Push to it directly, or open a pull request and
  merge it with `gh pr merge <pr> --squash` once it is ready and not a
  draft (a sandboxed agent runs `hecks-merge <pr>`). No check is required
  to land, so run the pre-push gate yourself before you push anything that
  is not trivial: `HECKS_PRE_PUSH_GATE=1 git push` runs it on `main`. Never
  force-push `main`, and never use `--admin`.
- **`stable` is only ever promoted.** CI runs the full job set on every push
  to `main`; when every `RequiredCheck` passed on a commit, `promote.yml`
  fast-forwards `stable` onto it through
  `exe/hecks promotion_run.promote lane=stable --confirm --wait`. Never push
  to `stable` yourself: its ruleset takes only a commit every required check
  already passed, and refuses deleting or rewinding it. Rehearse a move
  without `--confirm`: it names the
  move and makes none, and it says which check is red or still running.
- **Releases, `edge` and deploys come from `stable`, never `main`.** Commit
  the version bump (`lib/hecks/version.rb`, `CHANGELOG.md`, the README
  lines, `packages/hecks-client`) to `main`, wait for `stable` to contain
  it, then publish from a clean `stable`.
- **A red `main` blocks promotion, not pushes.** Fix forward or revert on
  `main`; `stable` does not move until a commit is green. Do not
  cherry-pick onto `stable` unless the user says production is down.
- **Change a lane or a required check by editing its row**, then run
  `exe/hecks regeneration_run.project_lanes --wait` to rewrite
  `.github/rulesets/` and `.github/workflows/promote.yml`. Applying the
  rulesets to GitHub is a separate, confirmed step
  (`regeneration_run.project_lanes --live --confirm`); never hand-edit the
  generated files.

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
- `exe/hecks regeneration_run.regenerate_corpus --check` (and the other regen scripts
  `.github/workflows/ci-checks.yml`'s `checks_codegen_drift` job runs)
  catch drift between a generator and its committed output.
