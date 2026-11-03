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

## Session isolation: git worktrees

A session that needs its own checkout uses `git worktree add`, and retires it with
`git worktree remove`. Any git operation an agent needs is allowed, through plain git or through a
`hecks` command that performs it; use the command when one exists, since it carries the repo's own checks.

**Discarding a branch.** `exe/hecks Landing.retire! --confirm` removes a worktree whose work is on `main`.
`exe/hecks Landing.discard! reason.value=… --confirm` removes one whose commits `main` lacks, and an
agent runs it only when the owner explicitly asks for that branch, never on its own work: the standing
rule is to report unpushed or uncommitted work, not delete it. It refuses uncommitted files, and its
report names the tip sha.

**Always pull `main` before you push.** Fetch and rebase onto `origin/main` right
before every push, and again if the pre-push gate ran long enough for `main` to
move. Many sessions push to `main`; a stale push is rejected or buries their work.

**Pull `main` first, before you cut a branch.** `LinkedTree.pull_main!` fetches `origin` and brings local `main`
up to date: a fast-forward when it is behind, a rebase of its unpushed commits when both moved; it never
forces or discards, and refuses by name (`cannot pull main: the checkout has uncommitted changes`) a dirty or
mid-rebase checkout. `LinkedTree.add!` runs it before cutting the branch and `landing.finish!` before its
rebase; `landing.land!` refuses a branch behind `origin/main`. A harness-made worktree (`EnterWorktree`)
is cut from `origin/main`, not local `main`: check `git merge-base --is-ancestor origin/main HEAD` and rebase.

Push `main` by boarding the train (`send_train.board! --confirm`), other branches with `git push`. The pre-push hook (`.githooks/pre-push`: rspec, fuzzing,
model_check, rubocop, CI attestation) runs on every push, so do not bypass it.
A red main stands a **red flag** (`RedFlag`, `lib/hecks/hecks/redflag/redflag.bluebook`): a CI run of main that completes red raises it (`Integration.CiFailed`, or `exe/hecks RedFlag.sync! run.value=<id>`), and one that completes green lowers it. While it stands, `Landing` and `SendTrain` refuse by name (`main is red: flag <id>`) everything except the fix of a red-* Work item (exe/hecks tickets Work.undone lists them): a branch named for the Work item lands and its tip is the one commit the train boards. A session listens with `exe/hecks Operation.follow domain.value=Hecks aggregate.value=RedFlag from_now=true wait=600` (RedFlagRaised, RedFlagRunNoted, RedFlagCheckedIn, RedFlagCleared), says it helps with `exe/hecks RedFlag.check_in! run.value=<id> session.value=<name> taking.value=<Work item or cause>`, and resumes on RedFlagCleared; `exe/hecks RedFlag.status` prints the flag, the red time and who is helping. Everything else lands locally with landing.land! once the flag is down.

## Briefing a session

A brief is an outcome, not a list of stop signs. `Coder::Brief.compose!` (`lib/hecks/coder/coder.bluebook`)
builds it from a Work item: the title and detail as the outcome, its `area` (omitted when the item has
none), and the standing rules, which live in that bluebook and are not restated in agent prompts. Map the
whole picture, act on everything in the area, stop only for a risk of losing data, an owner-only action, or
a change outside the area, and report what was stuck first.

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
directory and names it (`checkout:`, a world with a temporary `event_log` path).

Several files cost one launcher boot, not one each:
`exe/hecks test_suite_run.run_spec_files! "files.value=spec/a_spec.rb spec/b_spec.rb" --wait` reports each
file's counts and a total, and fails naming the files that failed. `isolation.value=process` (the default)
gives each file a new process; `isolation.value=shared` runs all in one, fastest, and may expose order
dependence. `exe/hecks test_suite_run.run_impacted_specs! --wait` runs the specs the push rehearsal's
map names for your branch against local `main` (`base.value=`, `cap.value=`, `dry.value=true` lists
them without running).

**The full spec suite runs only in CI** (the Vocabulary `rspec` check is `runs_in: "ci"`). Locally run the
quick gate and named specs: `run_suite!` is refused by name, and `run_spec_files!` and `run_impacted_specs!`
take at most the `spec_files_limit` of the `test_scope` setting in `hecks.world` per call (`hecks config`
prints it); CI is detected from the environment.

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

## Use the hecks binary

Repo tasks run through the `hecks` binary (`exe/hecks` in a checkout), not
ad-hoc Ruby, shell one-offs, or hand-written scripts. It is a launcher
whose commands and queries are projected from the bluebooks, so it is the
current list of what this repo can do.

- `exe/hecks` lists the public commands and queries (`exe/hecks --all` adds the internal ones); `exe/hecks <command> --help`
  says what one wants and how it refuses.
- `exe/hecks <command>! name=value …` does something;
  `exe/hecks <query> name=value …` reads something, written bare (`query` is the old spelling,
  kept as an alias until 8.0.0, and needed only where a command shares the query's name).
- A command is named by its aggregate and verb, as the bluebook spells them: `SendTrain.board!`,
  `Hecks::SendTrain.board!` and `Hecks::SendTrain.Board` all reach it, and so does the older
  snake-case `send_train.board!`. The listing and `--help` print `SendTrain.board!`; the heading
  over a group of commands is the aggregate, so each line under it completes the call.
- Before writing a script, look for the command that already does it
  (projections, regeneration, style checks, model_check, smoke tests).
  If none exists, add the command to the bluebook rather than a script.
- Add `--wait` when you need the result before the next step.

## The push train runs in Memory

The push train (`~/.claude/hecks-train`, a detached checkout) runs in Memory like every other tooling
domain: it needs no database, no local files and no mint. What must outlive a process comes from git:
the line is a lock in the repository's git directory, and a commit the remote already holds is
answered `carried`. Its mint step reports `Memory holds no eras, no mint needed`.

- Dev work needs no environment variable: Hecks is in Memory unless a local hecksagon's root
  `persisted_by "PostgresEra"` opts it in (the attached bluebooks inherit it). Do not add local
  files to a development checkout, and never to the train's copy.
  `exe/hecks config domain.value=<dir>` prints each setting, its value and which source supplied it.
- The shape ledger (`lib/hecks/hecks/shapes.json`) holds only bluebooks whose committed persistence
  (local overlays left out) is an era adapter, and framework members such as Governance that clients
  persist. Tooling is Memory by its committed world and needs no ledger entry, edge or `--confirm`.
  For a held bluebook, a shape change needs a translation edge under its `translations/`:
  `exe/hecks conformance_run.check_shape_ledger! --wait` (no database) names it, `--confirm --additive`
  settles a change that only adds, and `--confirm` alone moves the ledger once an edge covers the move.
  Renamed or reshaped data needs rules: `exe/hecks era.scaffold_translation domain.value=<dir>`
  writes them from the database the domain's own world names, and `era.audit_translation` checks them.
- Whether a copy may migrate its database is the `mint_eras` setting in its world
  (`persisted_by("PostgresEra") do ... mint_eras true end`, also from an overlay); `hecks config`
  reports it. An unset world refuses (`EraResolver::MINT_BY_DEFAULT` is `false`).
- A tooling ledger may opt out of eras with `disposable_ledger true` in the same block
  (`LineageManager::DisposableLedger`): an additive shape change is applied in place, any other
  moves the aggregate's rows to a dated archive table (listed in `hecks_ledger_archives`) and starts
  it empty, and a boot never refuses as unminted or superseded. Never declare it for client data.
- A boot over a store that holds eras reads a shape no era holds only when a recorded edge or a
  provably additive move covers it; a breaking move no edge covers refuses by name (`no translation
  edge covers it`), writing nothing. This is the interim until the commit-time gate (ADR 0168).
- After a push, the launcher's refresh moves its checkout only when it is detached and has no
  changed or untracked file; the report names the file that stops it.

## Minting an era of the QA ledger: quiet QA first

The QA loop writes to the ledger all the time, so its watermark moves between a rehearsal and the mint.
A mint window starts with `exe/hecks qa_quiesce.hold! reason.value="..." --wait` and ends with
`exe/hecks qa_quiesce.release! --wait`; `qa_quiesce.status` reports the owner, reason and age. While the
marker (`~/.claude/hecks-dev/quiesce`, stale after two hours) is fresh every `sweep.tick` step prints
`quiesced: skipped <step>` and the tick exits 0. Name yourself with `owner.value=` (or
`HECKS_QUIESCE_OWNER`); another owner's marker is not removed without `force.value=true`. The mint does
not require the flag.

## Landings, era inspection and the QA dispatcher

Each command's `--help` says what it takes; this names where they live. **Landing and the queue:**
`landing.finish!` (rebase onto local `main`, quick gate, land, tidy), `landing.land!` and `landing.train!`
(`lib/hecks/hecks/deliver/deliver.bluebook`) take a place in one first-come, first-served line; the
world's `landing "Queue"` (`hecks.world`) sets how long a ticket may go without a heartbeat and how long
a landing waits. `push_rehearsal.rehearse!` runs the stages of its scope (`RehearsalScope` rows in the Vocabulary
bluebook: `quick`, the default and the push gate, and opt-in `deep` which adds the specs the changes touch) on local `main` and `push_rehearsal.due` says whether a push is due
(`rehearse/rehearse.bluebook`); `test_suite_run.run_spec_files!` and `run_impacted_specs!` run named or
impacted specs through the launcher. Branch worktrees through `LinkedTree.add!`, which pulls `main` first.
**Era inspection:** `era.boot_resolution`, `era.mint_plan` (every guard a mint runs, read-only),
`era.event_trace`, `era.sqlite_status` and `era.projection_audit` read without writing; `Era.RenameDomain`
(`era.rename_domain!`) moves a renamed domain's history. The world words are `disposable_ledger`,
`stored_as` (the table an aggregate's rows keep after a rename), `formerly` (a domain's former name) and
`minting` (the command an unminted boot may write). **QA and dispatch:** `qa_quiesce.hold!`, `release!`
and `status` quiet QA for a mint; `Dispatch.Fill` starts sessions for planned Work items and
`Dispatch.Settle` finishes the rows of sessions that ended (`delegate/delegate.bluebook`); a landed
branch finishes the Work item of the same name (or the same name without a leading `qa/`). The Tickets
world's `work_limit`, `frozen_shapes` and `session_environment` bound and equip those sessions. The
CI checks `command_names` and `workflow_pagination` keep the names in docs, workflows and guides
resolvable and lists paged; the spec suite holds the meta-domain covered.

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

The branches are data: the `Lane` rows of the Vocabulary bluebook
(`lib/hecks/language/bluebook/vocabulary.bluebook`), with the checks a
commit must pass as `RequiredCheck` rows beside them.

- **The candidate gate (ADR 0181), off until the coordinator turns it on.** While `git config
  hecks.candidateGate` is true (`exe/hecks Candidate.enable! --confirm`; `Candidate.disable!`
  turns it off), `send_train.board!` pushes local `main`'s tip to `refs/heads/candidate`, not to
  `main`, CI runs there, and `main` moves only by a fast-forward onto a candidate every check
  passed on: `candidate.yml` makes it on GitHub and `Candidate.promote! --confirm` from a
  checkout. One candidate is in flight at a time (a second boarding is refused by name). A red
  candidate never touches `main`: `Candidate.observe!` reads it and `Candidate.reject! --confirm`
  keeps its commits on `rejected/<sha>`, resets local `main` to `origin/main` and files one
  `red-<cause>` Work item per failing cause. `Candidate.status` prints the gate and the candidate.
  A push of `main` outside a promotion is refused (`main moves only by promotion of a green
  candidate`); the owner's `HECKS_OWNER_PUSH` still passes.
- **`main` has no guard.** Agents land work on it with `hecks landing.land! --confirm`
  (fast-forward or merge commit, never squashed) and then
  `hecks send_train.board! --confirm`; do not open a pull request for it. A push of `main` runs
  the gate's `quick` stage and nothing else, seconds long: shape ledger, RuboCop (which also reads
  every changed Ruby file for syntax errors), comment style, secret output, adapter words.
  `hecks gate_run.gate! stage=quick --wait` runs it by hand and is worth running before every
  commit. Everything slower (fuzzing, the engine and model checks, command names, workflow
  pagination, the spec suite, the push-chain specs) runs after the push, in CI and the nightly run,
  and blocks promotion to `stable`, never the push; a red one files a Work item. `hecks send_train.board!
  --confirm full_gate.value=true` runs the whole `pre_push` stage when you ask for it. Never
  force-push `main`, and never use `--admin`.
  **The push is isolated.** `send_train.board!` pushes the boarded commit, by its id, from a throwaway detached
  worktree at that commit, so the pre-push hook and the quick gate check exactly what goes out and landings onto
  local `main` meanwhile are never held and never touch the push; commits that land during it stay local and are
  named in the report. Pushes serialize on the train's one lock; a remote that moved is fetched and retried, and a
  commit not built on it is refused by name ("board again"). **A plain `git push` of `main` is refused by the pre-push hook:** the train's own
  push carries `-c hecks.trainCarry=<commit>`, which the hook reads, so any agent pushes `main` by boarding the train. The owner's
  one-off override is `HECKS_OWNER_PUSH=<reason>` (ADR 0132): the hook prints the reason, an empty value does not count, and
  agents never set it or use `--no-verify`. Branch and tag pushes are untouched.
  Push small: a rehearsed push per landed slice, or at least per day, is the norm. A rehearsal
  (`push_rehearsal.rehearse!`; `scope.value=quick` for a landing's) runs the quick stage against local
  `main` and pushes nothing; a deep one (`scope.value=deep`, opt-in) adds the specs the push's changed
  files touch (`impacted_spec_limit`, two at a time, `impacted_spec_width`; a file that fails is run again
  alone and one that then passes is reported as flaky under parallel load, not failed; a spec already
  red on `origin/main` is reported, not failed). Its result is the `PushRehearsal` record, and
  `hecks push_rehearsal.due` says how far `main` is ahead of `origin/main`, how old the oldest
  unpushed commit is and how the last quick rehearsal ended. Nothing pushes by itself.
  The size that counts as too big is the QualityControl world's `push_nudge` setting (`commits`, `hours`,
  `urgent_commits`): past it the line and the train's report say `PUSH NOW`, and neither ever refuses a push.
- **Red `main` is read on GitHub.** The `CI` run's status and failure email are the signal; no local
  watch repeats it. The dispatch fill plans `red-*` rows (filed by people and CI jobs) first and starts
  one before other planned work. A red `main` blocks promotion to `stable`, never a push.
- **`stable` is only ever promoted.** CI runs the full job set on every push
  to `main`; when every `RequiredCheck` passed on a commit, `promote.yml`
  fast-forwards `stable` onto it through
  `exe/hecks promotion_run.promote! lane=stable --confirm --wait`, onto the newest
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
  `exe/hecks promotion_run.watch! lane=stable`; when `stable` has stood behind
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
  pushes; `publishing_run.publish!` refuses it too. Write the line only when
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
  `exe/hecks regeneration_run.project_lanes! --wait` to rewrite
  `.github/rulesets/` and `.github/workflows/promote.yml`. Applying the
  rulesets to GitHub is a separate, confirmed step
  (`regeneration_run.project_lanes! --live --confirm`); never hand-edit the
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
- **`rust/src/generated` is committed; no job regenerates it.** The `generated-rust`
  action only checks the tree is in the checkout (its `domains:` input has no effect).
  `checks_codegen_drift` is the one job that sets `regenerate: "true"`, rewrites the whole
  tree and diffs it with the committed one; without that rewrite its `git diff` compares
  the tree with itself, and a stale module goes through green. After you change a bluebook
  or the generator, run `exe/hecks regeneration_run.regenerate_corpus! --confirm --wait` and
  commit what it changed; a conflict in the tree is settled by regenerating, never by
  editing. The Vocabulary rows are part of the `meta` module's IR, so changing a gate row
  moves it too. A spec that reads the whole tree is tagged `:generated_all`: the shards run
  `--tag ~generated_all`, and the drift job runs it.
- **Two jobs that share a cargo cache name must build the same thing, from the same
  directory, with the same flags.** The first job to save an entry wins, and an entry is
  never replaced under its key, so a second job whose build differs (a `--manifest-path`
  build from the repo root skips `rust/host/.cargo/config.toml`; `cargo test -p x --lib`
  resolves features differently from `cargo test --workspace`) rebuilds every dependency on
  every run. The warm job in `cache-warm.yml` must build each form its consumers build. The
  key (`.github/actions/cargo-cache`) hashes the crate's manifest, path dependencies and the
  toolchain pin; the saved target leaves out `debug/incremental` and the `rust-*` binaries.
- **Split a job that sets the run's length into matrix legs, each its own gate check**:
  the fuzz sweeps run as `shard=I/N` legs (`fuzz_<I>_of_<N>` in the Vocabulary gate rows,
  `fuzz_shards` listing the split) and still report as `checks_fuzz` and
  `checks_fuzz_sqlite`, which are red when any leg is. The cost table
  `spec/fuzzing/fuzz_runtime_baseline.log` must come from CI sweeps, not a laptop: a laptop's
  disk prices banking and deploy in other proportions than a runner's and the legs split
  worse. A file that parallel_tests cannot split (one spec file) sets a shard's length, so
  split the file.
- **The rspec and Postgres io shards are balanced per run, not from a committed baseline.** A
  `shard_plan` job (`postgres_io_shard_plan` in the Postgres workflow) runs the CiSpeed bluebook's
  `ShardPlan.Request` through `Operation.run!`: it reads the per-file timings the shard legs uploaded
  as artifacts on the newest successful `main` run, splits the files once with the shared
  `Hecks::Tools::ShardPlanner` (longest processing time first) and publishes the plan; every leg
  reads that plan. When no timing can be read (no previous run, expired artifacts, an API error)
  the `PlanBySizeWhenTimingsUnavailable` policy plans by file size and the run does not fail. The
  plan job's summary and the `shard-plan-trace-*` artifact list each event and the policy that
  reacted. When you add io spec files run `test_suite_run.write_io_parallel_spec_list!`; a file with
  no timing is priced at the median. The specs that need `rust/parser` stay
  in `IO_PARALLEL_EXCLUDE_PATTERN`, or the Postgres shards skip them and the skip backstop
  fails; the file-list check runs only on pull requests, so a stale list shows on a PR first.
- **A fast green on `main` may be a skipped green.** A push of an attested tree skips the
  heavy jobs. `nightly-main.yml` runs all of `ci.yml` once a day with attestation ignored
  (`check-attestation` answers "not attested" for it) and opens one issue a day naming the
  failed jobs; read its latest run, not a push run, to know whether the suites pass.
- **Look at the job times after your push** (`gh run view <id> --json jobs`). A job
  that grew by a minute is the regression; say so rather than leave it.
- **Measure the right run.** The wall is `run_started_at` to `updated_at` of the attempt
  (`gh api repos/<owner>/<repo>/actions/runs/<id>/attempts/<n>`). Take attempt 1 of a run on
  a tree no earlier run had: a rerun, or a run on a tree already attested (the PR's own tree
  after a squash merge; any rerun after the pre-push hook's note lands), skips the heavy jobs
  and reads fast. A change to a cache key, to `rust/src` or to `ci-rust-io.yml` makes the next
  run cold once. `main`'s runs and the cache-warm job share the runner pool, so a busy pool
  adds queueing; a single cache download can also stall, so one slow job is not a regression
  until it repeats.

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
