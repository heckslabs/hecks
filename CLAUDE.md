# CLAUDE.md

## Bluebook or hecksagon? Ask it first

In the Hecks world there are only two kinds of thing. Before you design,
place, or review anything, say which one it is, and consider the bluebook
first, then the hecksagon.

- **Bluebook (`*.bluebook`, `Hecks.bluebook`)** is the domain, declared:
  aggregates, commands, events, policies, vocabulary. It names no
  database, clock, network, or file.
- **Hecksagon (`*.hecksagon`, `Hecks.hecksagon`)** is the wiring, declared:
  `persisted_by "Memory"`, `attaches "Governance"`, the adapters a domain
  plugs into. `lib/hecks/framework/bluebook/framework.hecksagon` is a small
  example.

Both are declarative. There is no imperative code in the bluebook world,
and you do not write any there. Imperative code exists only outside it:
the implementations behind a hecksagon's ports (`lib/hecks/adapters/`,
where an `.adapter` file declares `port "clock"` and the matching `.rb`
reads `Time.now`), and the generators and the Rust kernel that project
bluebooks into other outputs. Time, randomness, storage, and webhooks live
there, never in a bluebook.

Rules of thumb:

- If it says what the domain is or does, it is bluebook. If it says what the
  domain is connected to, it is hecksagon. If it cannot be said in either,
  it is not Hecks code: it is an adapter behind a port or a generator, and
  needs a reason.
- Persistence defaults to memory. A domain uses the Memory adapter unless
  its hecksagon explicitly wires another (Heki, Sqlite, Postgres); do not
  add a persistence adapter by default.
- `Hecks::Framework` members (Governance, Identity, Privacy, Compliance)
  are bluebooks; persistence for them is a separate hecksagon.
- Projections turn a bluebook's IR into other outputs (Rust, diagrams,
  glossary, site routes, help). Add a new output as a projection, not as
  hand-written code beside the domain.
- Ruby and Rust both run bluebooks; `check_conformance` compares them.
- Agents do everything through a command (see "Use the hecks binary"). If
  no command does what you need, that gap is a bluebook change, not a
  one-off script.

## Session isolation: jj workspaces, not git worktrees

Root is a colocated jj+git repo. Use `jj workspace add <path>` for a new
session's checkout instead of `git worktree add`; retire with
`jj workspace forget <name>` and remove the directory.

**Always pull `main` before you push.** Fetch and rebase onto `origin/main` right
before every push, and again if the pre-push gate ran long enough for `main` to
move. Many sessions push to `main`; a stale push is rejected or buries their work.

Push with `git push`, not `jj git push` — jj bypasses git hooks, so
`.githooks/pre-push` (rspec, fuzzing, model_check, rubocop, CI
attestation) wouldn't run. Colocation keeps bookmarks synced to git
branches, so plain `git push` still works.

## Running specs

Run a spec file through the launcher, which is the sanctioned path (see "Use the
hecks binary" below):

```sh
exe/hecks test_suite_run.run_spec_example! \
  file.value=spec/doc_banners_spec.rb "example.value= " --wait
```

`example.value` filters on the full example description; a single space matches
every example. The report ends with the example and failure counts. Hecks runs in Memory
unless a local hecksagon opts it into PostgresEra (ADR 0134), so the run needs no database and no
environment variable. Memory changes some behavior: two guide examples that retry a payment
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
calling comment work done. A hook runs the same check on each Ruby file you edit and reports a
violation in that turn (`.claude/hooks/comment_style_on_edit.sh`), and the gate's `comment_style`
check covers `lib/hecks` and `spec`.

## Use the hecks binary

Repo tasks run through the `hecks` binary (`exe/hecks` in a checkout), not
ad-hoc Ruby, shell one-offs, or hand-written scripts. It is a launcher
whose commands and queries are projected from the bluebooks, so it is the
current list of what this repo can do.

- `exe/hecks` lists the public commands and queries (`exe/hecks --all` adds the internal ones); `exe/hecks <command> --help`
  says what one wants and how it refuses.
- `exe/hecks <command>! name=value …` does something;
  `exe/hecks query <query> name=value …` reads something.
- A command is named by its aggregate and verb, as the bluebook spells them: `PushTrain.board!`,
  `Hecks::PushTrain.board!` and `Hecks::PushTrain.Board` all reach it, and so does the older
  snake-case `push_train.board!`. The listing and `--help` print `PushTrain.board!`; the heading
  over a group of commands is the aggregate, so each line under it completes the call.
- Before writing a script, look for the command that already does it
  (projections, regeneration, style checks, model_check, smoke tests).
  If none exists, add the command to the bluebook rather than a script.
- Add `--wait` when you need the result before the next step.

## The push train records to its own database

The push train (`~/.claude/hecks-train`, a detached checkout) writes its runs to a database its
own gitignored local files (`hecks.local.hecksagon` and `hecks.local.world`, or the older
`environments/local.*`) name (`hecks_train`). The older `hecks_records` is an archive: do not boot a
checkout against it.

- Dev work needs no environment variable: Hecks is in Memory unless a local hecksagon's root
  `persisted_by "PostgresEra"` opts it in (the attached chapters inherit it), and only the train's
  copy does. Do not add local files to a development checkout or point them at the train's
  database: a checkout that boots a newer shape against a records database mints an era the
  train's launcher then refuses, and the pushes stop.
  `exe/hecks config domain.value=<dir>` prints each setting, its value and which source supplied it.
- A change to the shape of a persisted chapter needs a translation edge under that chapter's
  `translations/`, and the committed ledger `lib/hecks/hecks/shapes.json` moves with it.
  `exe/hecks conformance_run.check_shape_ledger --wait` (a gate check, no database) fails with the
  edge to commit; `--confirm --additive` writes that empty edge and moves the ledger for a change
  that only adds, and `--confirm` alone moves it once an edge covers the move. Data that is
  renamed or reshaped needs rules: `exe/hecks query era.scaffold_translation domain.value=<dir>`
  writes them from the database the domain's own world names (a client domain names it in its
  world, the Hecks domain in a `hecks.local.world`), and `era.audit_translation` checks them.
- Whether a copy may migrate its database is the `mint_eras` setting in its world
  (`persisted_by("PostgresEra") do ... mint_eras true end`, also from an overlay); `hecks config`
  reports it. An unset world refuses (`EraResolver::MINT_BY_DEFAULT` is `false`); the train
  copy's local world declares `mint_eras true`.
- After a push, the launcher's refresh moves its checkout only when it is detached and has no
  changed or untracked file; the report names the file that stops it.

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
  draft. No check is required
  to land, so run the pre-push gate yourself before you push anything that
  is not trivial: `hecks gate_run.gate stage=quick --wait` runs the seconds-long checks (shape
  ledger, rubocop, comment style) and is worth running before every commit. A push of `main` runs
  those first, then only the `unguarded_push` stage of
  `lib/hecks/gate/stages.yml`, and `hecks push_train.board! full_gate.value=true` runs the
  whole `pre_push` stage. Never
  force-push `main`, and never use `--admin`.
- **`stable` is only ever promoted.** CI runs the full job set on every push
  to `main`; when every `RequiredCheck` passed on a commit, `promote.yml`
  fast-forwards `stable` onto it through
  `exe/hecks promotion_run.promote lane=stable --confirm --wait`, onto the newest
  commit of `main` that every required check passed on (named `commit=<sha>` it
  judges exactly that commit and no other). Never push
  to `stable` yourself: its ruleset takes only a commit every required check
  already passed, and refuses deleting or rewinding it. Rehearse a move
  without `--confirm`: it names the
  move and makes none, and it says which check is red or still running.
- **What `stable` guarantees.** `main` is integrated state, `stable` is certified
  state, and a commit is certified by the check runs of that exact sha, never by
  "`main` was green about then". Every commit reachable from `stable` was moved
  there by a fast-forward of a commit that every `RequiredCheck` had passed on
  (the ruleset refuses anything else, and refuses rewinding or deleting it). A
  promotion is not tied to the push that started it, so a dropped, late, or
  out-of-order run changes nothing, and a certified commit is never stranded
  behind a red or still-running one. `edge` is brought up to `stable`'s head on
  every confirmed run, even one that finds `stable` already there, and its own
  ruleset (`.github/rulesets/tag-edge.json`) refuses deleting it or pointing it
  at an older commit; moving it forward is allowed.
- **A late `stable` files a finding.** `lane-watch.yml` runs every hour and asks
  `exe/hecks promotion_run.watch lane=stable`; when `stable` has stood behind
  `main` for longer than its `Lane` row's `alert_after` hours (4), the run fails
  and files one GitHub issue a day, saying which required check is red or still
  running. Fix `main` forward or revert on it; the issue is yours to close. A failed
  watch also dispatches `promote.yml`, so a dropped promotion is retried within the
  hour (`gh workflow run promote.yml` does the same by hand).
- **Releases, `edge` and deploys come from `stable`, never `main`.** Commit
  the version bump (`lib/hecks/version.rb`, `CHANGELOG.md`, the README
  lines, `packages/hecks-client`) to `main`, wait for `stable` to contain
  it, then publish from a clean `stable`. `release.yml` enforces it: it runs
  after Promote, releases the commit on `stable` that set the version, and
  refuses any commit `stable` does not contain, a by-hand run included.
- **A release is the owner's decision.** A bump that lands on `main` ships
  only if the commit that set the version has a `Release-Approved-By: <name>`
  line in its message (the `release_trailer` of the `stable` `Lane` row;
  `lib/hecks/release/approval.rb` decides). Without it `release.yml` releases
  nothing after a promotion, and refuses a by-hand run before it tags or
  pushes; `publishing_run.publish` refuses it too. Write the line only when
  the user has said to release; never add it on your own, and never bump the
  version for a fix that can ride `edge` (the tag at `stable`'s head, which a
  client can pin as "latest certified"). An existing tag counts as approved,
  so `gh workflow run release.yml -f tag=vX.Y.Z` still finishes a half-cut
  release; the owner may approve a bump already on `stable` with `-f
  approved_by=<name>`. Name the pending release while changes accumulate
  by writing `## [Unreleased] - planned X.Y.Z` on the CHANGELOG heading
  (`spec/changelog_planned_release_spec.rb` pins the shape); naming it does not
  approve it.
- **A red `main` blocks promotion, not pushes.** Fix forward or revert on
  `main`; `stable` does not move until a commit is green. Do not
  cherry-pick onto `stable` unless the user says production is down.
- **Change a lane or a required check by editing its row**, then run
  `exe/hecks regeneration_run.project_lanes --wait` to rewrite
  `.github/rulesets/` and `.github/workflows/promote.yml`. Applying the
  rulesets to GitHub is a separate, confirmed step
  (`regeneration_run.project_lanes --live --confirm`); never hand-edit the
  generated files.

## Keep CI under three minutes

CI on `main` ran in about 160s with every job run for real; by 2026-10-23 it took
10 minutes or more. Nothing was skipped wrongly: work had landed in jobs where it
runs cold. Before adding a spec or a step, check where it runs:

- **A spec that runs `cargo` goes in a Rust job that holds that crate's cache**, never
  in a Postgres io shard (`IO_PARALLEL_EXCLUDE_PATTERN` in
  `.github/workflows/ci-postgres-io-parallel.yml`). A shard has no Rust cache, so one
  `cargo build` there costs minutes. A host harness spec belongs in
  `rspec_rust_host_lineage`, and a `cargo test` of the host in `rspec_rust_host_cargo`,
  whose `target-test` build is warm.
- **Don't regenerate the corpus a second time in a job.** The `generated-rust`
  action already restores or regenerates `rust/src/generated` and `rust/Cargo.toml`;
  compare against that.
- **Refresh the runtime baselines when you add io spec files**:
  `exe/hecks test_suite_run.refresh_runtime_baseline from_run=<a green CI run id> --confirm --wait`,
  then `test_suite_run.write_io_parallel_spec_list`. Shards group by these logs, and a
  file missing from them lands wherever it lands.
- **Look at the job times after your push** (`gh run view <id> --json jobs`). A job
  that grew by a minute is the regression; say so rather than leave it.

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
