# The pipeline is its own project, Switchyard, on a pinned Hecks

**Status:** Proposed. The owner raised the split on 2026-11-13 ("we could move the pipeline into its own project")
while asking how a pipeline fix can be applied locally and judged at once. Decision 4 was built the same day (see
"As built"); nothing else is. Date: 2026-11-13.
Builds on [0201](0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md), whose
fingerprint decides when running code is replaced, and on
[0202](0202-a-write-from-a-worktree-to-a-shared-ledger-runs-in-the-main-checkout.md), whose forwarding is why a
worktree cannot try a pipeline fix.

## Context

The pipeline is the part of this repository that moves work to `main` and beyond: agent runs and their dispatch,
landings, the push train, integration with CI, the board, the red flag and the stall watch. It is written in Hecks and
lives inside the Hecks domain (`lib/hecks/hecks/deliver`, `delegate`, `redflag`, `stall_watch`, `rehearse`, `quiesce`)
and in bluebooks the domain attaches (Pipeline, PipelineBoard, Agents, Coder, Fixer, Triage), with their adapters under
`lib/hecks/hecks/adapters` and `lib/hecks/pipeline_board`.

A fix to the pipeline is slow to judge, for three reasons read from the code on 2026-11-13.

- **A fix reaches `main` only through the pipeline it fixes.** It is written by a coder run and lands through
  `Landing`. On the morning of 2026-11-13 a landing took between one and four minutes and about half were refused.
  When the fault is in dispatch or landing, the fix waits on the fault.
- **A worktree cannot try the fix.** The pipeline's records are bound to SQLite by the main checkout's local files, so
  a write from a worktree is forwarded to the main checkout (ADR 0202) and runs the main checkout's code. The fixed
  code in the worktree is exercised by its specs and by nothing live.
- **The pipeline and the framework replace each other's running code.** Reloading itself is quick and already built:
  a resident retires when the fingerprint of `lib/` moves, the board restarts on a code change
  (`PipelineBoard::BoardRestart`), an advance ends when the code under it changed (`MainIntegration::CodeWatch`) and
  the train's copy is brought to each boarded commit. Both codebases sit under one `lib/`, so a landing in either moves
  the fingerprint of both, and a framework change that breaks boot also stops the thing that would land its repair.

How the two sides depend on each other, from the bluebooks, the hecksagon and the `require` lines:

- The pipeline's Ruby needs little of the framework's: boot, the dispatcher and asking, the runtime's errors, the
  Memory and SQLite stores, the event tap, the launcher and the MCP door. Most of its other requires go to helpers that
  only the pipeline uses (`console_capture`, `shell`, `git`, `git_worktrees`, `started_work`).
- The framework's Ruby needs almost nothing of the pipeline's. The requires found: the MCP roles reading the Agents
  routing guard, the impacted-spec reading using the rehearsal's spec map and the machine sampling, and the mint
  reading using QualityControl's.
- One edge in the bluebooks is hard. The saga that takes a branch to `main` steps through `StyleRun`,
  `ConformanceRun.CheckShapeLedger` and `GateRun.Gate` by name, which are this repository's own checks.
- The pipeline's settings sit in `hecks.world` beside the framework's (`landing`, `boarding_hold`, `reaping`,
  `agent_roles`, `board_restart`, `event_log`).

There is prior art for a project that stands on Hecks from outside. miette_tools, shorts and miette2 each depend on
`gem "hecks", path: ENV.fetch("HECKS_CHECKOUT", ...)`, attach gem bluebooks by name and keep their own stores. The
push train already runs from a copy of its own (`~/.claude/hecks-train`), moved on purpose.

There is also prior art for a bluebook one project carries and another uses. The `embryonaut_bluebooks` registry holds
packages (`<package>/bluebook/`, each with its own version, changelog and release tag). A project pins one into
`vendor/embryonaut_bluebooks/` with `hecks vendor`, a lock records the commit and digest, and
`attaches "<package>", from: :vendor` loads it. A package may answer a query with its own code, a wasm module beside
the bluebook that Hecks binds with no wiring in the project (`calendar` is the first).

## Decision

1. **The pipeline moves to a project of its own, named Switchyard.** It is a Hecks project like any client: its own
   repository, bluebook, hecksagon, world, launcher, specs and gate. It works on a checkout it is told, as
   `SendTrain.board! checkout=` does today, so it serves Hecks and the client repositories alike.
2. **What moves.** The whole of `deliver` but the two questions decision 7 keeps (`Revision`, `LinkedTree`,
   `Landing`, `SendTrain`, `Integration`, `TrainPr`, `ReviewRequest`, `EarlyCi`, `BoardingHold`, `BoardingRelease`,
   `PushOutcome`, `Shipment`, and the git questions of `Workspace`); the whole of `delegate`
   (`AgentRun`, `Dispatch`, `Heartbeat`, `Ticker`, `Wake`, `Machine`, the session aggregates, `Question`,
   `AnswerDesk`); `RedFlag`, `StallWatch`, `PushRehearsal` and `QaQuiesce`; the bluebooks Pipeline, PipelineBoard,
   Agents, Coder, Fixer and Triage; the adapters and specs of all of these; the pipeline's lines of `hecks.world`; the
   role files under `.claude/agents`, the orchestrator's hook and the launchd jobs.
3. **What stays in Hecks.** The language, the loader and runtime, the launcher and resident, persistence and
   projections, and the framework's own verbs (build, check, evolve, migrate, operate, find, test, release).
4. **Switchyard asks a repository for its gate through a port.** The landing saga stops naming `StyleRun`,
   `ConformanceRun` and `GateRun`. It asks a `Gate` port to judge a worktree and reacts to the answer or the refusal.
   The adapter for a Hecks checkout runs that checkout's own launcher, so Hecks keeps deciding what its gate holds.
   This is done first, inside this repository, since it is the only edge that stops the move.
5. **Switchyard depends on a pinned Hecks.** Its Gemfile names Hecks by path, as the client projects do, and the path
   is a detached worktree of Hecks that Switchyard moves when a green `main` is worth taking. A landing in Hecks
   therefore changes nothing Switchyard is running, and a broken Hecks `main` cannot stop the pipeline that repairs it.
   The live checkout was the other choice; it would keep every Hecks landing restarting the pipeline, since the
   fingerprint covers the gem's `lib/`.
6. **Tickets stays in Hecks and Switchyard attaches it.** Client projects attach Tickets as their own board, so it is
   a shipped bluebook and not only the pipeline's.
7. **The git verbs move with `Landing`, and Hecks keeps none.** `Revision`, `LinkedTree`, `Landing` and the git
   questions of `Workspace` (`Status`, `Strays`, `Changes`) are one set: a landing names its worktree by id, the four
   share the git adapters, and their records sit in one store. They move together, as a delivery bluebook of
   Switchyard's that a project can attach without the rest of the pipeline. `Workspace.Settings`, `Workspace.Doctor`
   and `Workspace.Where` say how Hecks itself is set up (`hecks config` and `hecks doctor` run them) and stay.
   Hecks runs its own repository through Switchyard, as any client does.
8. **Switchyard is in two layers.** The delivery bluebook of decision 7 is the lower one: commit, open a worktree,
   land. The pipeline is the upper one: agent runs, the train, integration, the board and the watchers. A client that
   wants repository verbs and no pipeline takes the lower layer alone.
9. **The pipeline is a running project; only the delivery bluebook is a package.** A vendored copy is pinned and
   locked, and a change reaches it by a release and a re-vendor. That suits what several projects share and seldom
   change, which the delivery bluebook is. The pipeline has one consumer, this machine, and is what gets mended many
   times a day, so it stays a project whose code runs where it is edited. The delivery package's source lives in
   Switchyard's repository (`delivery/bluebook/`, with its `bluebook.yml` and release tags), which `hecks vendor`
   already takes as a source. Switchyard runs that bluebook from its own tree and never from a pinned copy, so a
   worktree fault is mended as fast as any other; every other project vendors it.
10. **QualityControl stays for now.** It drives fuzzing, the corpus and era mints, which judge the framework, and it
    also feeds Fixer and Coder. Where it is cut is a later decision, taken once Switchyard stands.

The owner chose decisions 7 and 9 on 2026-11-13. The first draft kept `Workspace`, `Revision` and `LinkedTree` in
Hecks and moved `Landing`; "Alternatives considered" says why that was dropped. Decision 6 is still the recommendation
and not yet chosen.

## Consequences

- A pipeline fix is committed in Switchyard and is live on the next command: the resident retires on Switchyard's
  own fingerprint, and Switchyard's gate holds only the pipeline's specs.
- A fix can be tried before it is committed. Switchyard keeps its records in its own stores, so a second checkout of
  it with stores of its own can run a whole landing against a scratch repository.
- Hecks loses the pipeline's share of its Ruby and specs, so a framework change no longer runs or waits for them.
- The names change for a caller. Commands that were `exe/hecks Landing.land!` are Switchyard's launcher's, and the
  push hook (`~/.claude/scripts/push-train-hook.rb`) and the briefs that name them are rewritten.
- `HECKS_CHECKOUT` and the pinned worktree replace `~/.claude/hecks-train`: one pinned copy, with one way to move it.
- A change that needs both sides (a new runtime feature the pipeline uses) takes two steps: land it in Hecks, move the
  pin, then use it. That delay is the price of the pipeline no longer breaking when the framework does.
- The records in `~/.claude/hecks-dev` keep their files. Their bluebooks change name from `Hecks` to `Switchyard`, so
  the tables are either renamed once or declared with `stored_as`, as the earlier renames were.
- The context map loses the Hecks to Agents and Hecks to Coder pairs, which become relationships inside Switchyard.
- A worktree fault (a tidy, a retirement, a scratch clearing) is mended in Switchyard like any other pipeline fault.
  With `LinkedTree` left in Hecks it would have gone through Hecks and waited for the pin to move.
- A client that uses the repository verbs gains a second dependency. miette_tools, shorts and miette2 name
  `Workspace.status`, `LinkedTree.add!`, `Revision.make!` and `Landing.land!` in their instructions; each takes
  Switchyard's delivery bluebook and its launcher lines change.
- They take it the way they would take any shared bluebook: the delivery bluebook is a vendored package, pinned by
  version and attached with `from: :vendor`. Nothing new is needed to carry the bluebook and its ports.
- Its adapters are the open point. A package's own code today is a wasm module that answers a query. The delivery
  adapters run git and answer asks that change a repository, which no package does yet. For now the package carries
  the bluebook and ports and the git adapters come from a gem beside it, so a client pins two things. The adapters
  are also fat: the landing line and the merge live in Ruby. Thinned until what is left is the `Git` and `Shell`
  adapters Hecks already has, the package would need no gem; that is a later piece of work and nothing waits on it.
  An earlier draft of this ADR said `attaches` could not reach another project's bluebook at all, which was wrong.
- `attaches` loads a gem bluebook or one under `vendor/`. Switchyard running the delivery bluebook from its own tree
  (decision 9) is neither, so that needs a small addition or the delivery files kept in Switchyard's own domain
  directory. It is settled when Switchyard is stood up.
- `Workspace` is split in two: its git questions leave, and what stays is no longer about a working copy, so the
  aggregate left in Hecks wants a truer name.

## Order of work

1. The `Gate` port, in this repository (decision 4).
2. Switchyard's repository on the pinned Hecks, holding the delivery bluebook as a part that stands apart from the
   rest and run from its own tree. The old commands stay here until the new ones have made a commit, opened a
   worktree and landed a branch.
3. `delegate`, the rest of `deliver`, the watchers and their adapters. The old commands stay until the new ones have
   run a dispatch and a boarding. From here a pipeline fix is made and judged in Switchyard, which is what the split
   is for.
4. The board and the Agents, Coder, Fixer, Triage and Pipeline bluebooks.
5. The old code and its lines of `hecks.world` leave this repository, in a release that names the break.
6. The delivery bluebook is released as a package, with its git adapters in a gem beside it, and the client projects
   vendor it. This comes last: it is the lesser gain, and nothing before it depends on it.

## As built

Decision 4, on 2026-11-13.

- `Shipment` has a `Gate` port with one ask, `Judge`, answered `JudgementAnswered` and refused `JudgementRefused`.
  `Adapters::CheckoutGate` runs `exe/hecks gate_run.gate! stage=quick --wait` in the checkout the shipment names and
  reads whether the launcher ended well and reported a completed run.
- `GateAndBoard` hears the port's two events and no check's. Its stages are `judging`, `landing` and `boarding`.
  `Shipment.Rejudge` asks the gate again for a parked shipment, and is what `hecks resume` runs for `judging`.
- `hecks resume` was mended on the way. It wrote the saga's saved arguments as typed value objects and handed every
  one to the stage's command, so a resume of a real saga was refused. `CliRunner::ResumeLine` now writes the arguments
  the command declares, as bare values, and names the run as the receiver of a command on a record already made.
- A resume from a later launcher call needs the saga kept. `GateAndBoard` is stored with `Shipment`
  (`Registry::SagaAnchor`), and `Shipment` is Memory unless a checkout's local hecksagon binds it
  (`Hecks::Shipment.persisted_by("SqlitePersistence")`); the owner's main checkout binds it since 2026-11-13.
- The launcher never ran a resume. It answered `resume <run>` with the usage line, and once that was mended it ran the
  resume twice in one call (`CliRunner.stream` resolved the line before `CliRunner.call` did). Both are mended, and a
  shipment parked by one launcher process was resumed by another against a SQLite store.
- The comment fix left the shipment. A gate judges and edits nothing, so a branch with a fixable comment offense now
  stops at its gate. `StyleRun.FixComments` is still there to run by hand.
- A refused gate parks the saga and files no finding of its own. The gate runs in the checkout's own process, so its
  `GateFaulted` is reported there and not in the process that shipped.
- `GitLanding::Finisher`, `GitLanding::Train` and `MainIntegration::Checks` take the command line from
  `CheckoutGate`. They still run it themselves inside their own steps; moving a landing's gate behind the port means
  splitting the `FinishBranch` ask, which is left for the move.
- `GitTrain::Settlement` still names two checks of this repository's `ci` stage (`vocabulary_drift`, `ci_gates`).
  That is a second edge of the same kind, found while building, and it is not cut yet.

## Alternatives considered

- **Leave it in place and make landings faster.** It shortens the first of the three delays and leaves the other two:
  a worktree still cannot try a fix, and each side still replaces the other's running code.
- **A lighter gate for pipeline-only changes.** A path rule would decide which gate a change gets, inside the saga
  that is being changed. It keeps the shared fingerprint and the shared `main`.
- **Let a worktree run the pipeline against the shared ledgers.** ADR 0202 turned this down: it would send a
  worktree's specs and gates to the live stores.
- **Keep `Workspace`, `Revision` and `LinkedTree` in Hecks and move only `Landing`.** This was the first draft, on
  the view that a client uses the first three without a pipeline. The clients' own instructions name `Landing.land!`
  beside them, so the line matched no one's use. It also cut one cluster in two and left worktree faults, a common
  kind of pipeline fault, to be mended through Hecks.
- **Make the whole pipeline a set of vendored packages.** The registry would carry it and no project would run it
  from source. Every fix would then go through a release and a re-vendor, which is the delay the split is meant to
  remove, and the packages would have one consumer.
- **Have Switchyard vendor its own delivery package.** One rule for every consumer, but a worktree fault would wait
  for a release before the pipeline saw the fix.
- **Depend on the released gem.** A pipeline fix that needs a framework change would wait for a release. The pinned
  worktree gives the same isolation and moves in seconds.
