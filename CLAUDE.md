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

**A command knows where it stands.** Every command resolves the checkout from the directory it
runs in: the primary checkout of that repository (`git rev-parse --git-common-dir`), or the worktree
holding the branch it acts on (`main` is the primary's). Pass no `checkout=`, `repo=` or `domain=`
path for Landing, LinkedTree, `SendTrain.board!`, `AgentRun.dispatch!` or `Operation.follow`; a path
you do pass overrides the resolution. A linked worktree loads the primary's local overlay, so it
reads and writes the same stores; where it cannot, a write the primary persists is sent to the primary
or refused by name, never put in Memory. `run_impacted_specs!` compares with `origin/main`.

**Discarding a branch.** `exe/hecks Landing.retire! --confirm` removes a worktree whose work is on `main`.
`exe/hecks Landing.discard! reason.value=… --confirm` removes one whose commits `main` lacks, and an
agent runs it only when the owner explicitly asks for that branch, never on its own work: the standing
rule is to report unpushed or uncommitted work, not delete it. It refuses uncommitted files, and its
report names the tip sha.

**Always pull `main` before you push.** Fetch and rebase onto `origin/main` right
before every push, and again if the pre-push gate ran long enough for `main` to
move. Many sessions push to `main`; a stale push is rejected or buries their work.

**Pull `main` first, before you cut a branch.** `LinkedTree.add!` runs `LinkedTree.pull_main!` (a
fast-forward, or a rebase of local `main`'s unpushed commits; it never forces or discards and refuses a
dirty checkout by name) before it cuts the branch. A harness-made worktree (`EnterWorktree`) is cut from
`origin/main`, not local `main`: check `git merge-base --is-ancestor origin/main HEAD` and rebase.

**Push `main` only by boarding the train** (`send_train.board! --confirm`), other branches with
`git push`. The pre-push hook (`.githooks/pre-push`) runs on every push and refuses a plain push of
`main`; never bypass it. Agents never use `--no-verify` and never set `HECKS_OWNER_PUSH`, which is
the owner's alone. Do not open a pull request for `main` by hand.

**A red `main` stands a red flag.** While it stands, `Landing` and `SendTrain` refuse by name
(`main is red: flag <id>`) everything except the fix of a red-* Work item; `exe/hecks RedFlag.status`
says whether one stands. How to listen, check in and resume: `docs/agents/landing-and-dispatch.md`.

## Briefing a session

A brief is an outcome, not a list of stop signs. `Coder::Brief.compose!` (`lib/hecks/coder/coder.bluebook`)
builds it from a Work item: the title and detail as the outcome, its `area` (omitted when the item has
none), and the standing rules, which live in that bluebook and are not restated in agent prompts. Map the
whole picture, act on everything in the area, stop only for a risk of losing data, an owner-only action, or
a change outside the area, and report what was stuck first.

## Running specs

Run specs through the launcher, never `bundle exec rspec` or a wrapper script around it:

```sh
exe/hecks test_suite_run.run_spec_example! \
  file.value=spec/doc_banners_spec.rb "example.value= " --wait
exe/hecks test_suite_run.run_spec_files! "files.value=spec/a_spec.rb spec/b_spec.rb" --wait
exe/hecks test_suite_run.run_impacted_specs! --wait
```

`example.value` filters on the full example description; a single space matches every example.
`run_spec_files!` costs one boot for many files; `isolation.value=shared` runs them in one process,
`process` (the default) gives each its own. `run_impacted_specs!` runs the specs your branch's
changes map to (`cap.value=`, `dry.value=true`). Specs run in Memory and need no database.

- **The full spec suite runs only in CI.** `run_suite!` is refused locally; run the quick gate and
  named specs. The landing runs the quick gate and the impacted specs again and refuses on red.
- **A spec never touches the owner's live state.** `spec/support/live_state_guard.rb` and
  `live_ledger_guard.rb` fail a spec that reaches the live event tap, red flag or ledgers; a spec
  that needs a repository, a flag or a tap builds its own under a temporary directory.

## Comments, RuboCop and generated output

Comments in this repository's Ruby (`lib/`, `spec/`, `examples/`) match `docs/COMMENT_STYLE_GUIDE.md`:
no all-caps lead-ins (use `**bold**`), no design history ("used to", "previously", PR numbers),
YARD tags on public methods, a class comment says what it is, lines under 100 characters. Check with
`exe/hecks style_run.check_comments! paths=<path> --wait`.

RuboCop runs at its defaults (`docs/decisions/0091-rubocop-defaults-with-deliberate-overrides.md`)
over the whole repository, specs too, and one offense blocks the push. A method is at most 10 lines
(ABC 17, cyclomatic 7, 5 parameters), a class at most 100 lines: extract helpers, never
`# rubocop:disable` or a raised limit. A spec example is at most 5 lines with one expectation
(`:aggregate_failures` for more), at most 5 `let`s per group, `have_received` over a bare message
expectation. Double quotes everywhere, table-aligned hashes, 130 columns. Run
`bundle exec rubocop <files>` (`-a` fixes style, not metrics).

**Never hand-edit generated output.** A file with a `# Generated ... do not edit` or
`// GENERATED by ...` banner, and a golden fixture (`spec/fixtures/*_golden/`), comes from a
generator: fix the generator or its source and regenerate. After a bluebook or generator change run
`exe/hecks regeneration_run.regenerate_corpus! --confirm --wait`, then `--check`.

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
  If none exists, a script is fine as a follow-up: a role's session is refused its first script
  until it has run a hecks command (run the script again if none fits), and every script is
  recorded. A script needed twice becomes a command in the bluebook
  (`exe/hecks agents Script.candidates` lists them).
- Add `--wait` when you need the result before the next step.

## Releases are the owner's

A version bump ships only with a `Release-Approved-By: <name>` line in its commit message. Write it
only when the owner has said to release; never bump a version or cut a release on your own, and
never push to `stable`, which is only promoted. Releases and deploys come from `stable`, never `main`.

## Read on demand

Each of these holds detail only some sessions need. Read the one that matches your work first.

- `docs/agents/landing-and-dispatch.md`: landing a branch, the red flag, era inspection, QA and
  dispatch, stalls.
- `docs/agents/lanes-and-releases.md`: the push train, rehearsals, `main` and `stable`, promotion,
  `edge`, releases, changing a lane or a required check.
- `docs/agents/persistence-and-eras.md`: Memory and local overlays, worktree borrowing, the shape
  ledger, translation edges, `mint_eras`, `disposable_ledger`, quieting QA for a mint.
- `docs/agents/ci-speed.md`: keeping CI under three minutes, where a spec or job runs, caches,
  shards, measuring a run.
- `docs/agents/specs-and-style.md`: the spec runner, the live-state guards, comment style, RuboCop
  and generated output, in full.
