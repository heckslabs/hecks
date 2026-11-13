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

## Decision

1. **The pipeline moves to a project of its own, named Switchyard.** It is a Hecks project like any client: its own
   repository, bluebook, hecksagon, world, launcher, specs and gate. It works on a checkout it is told, as
   `SendTrain.board! checkout=` does today, so it serves Hecks and the client repositories alike.
2. **What moves.** The delivery aggregates past a commit (`Landing`, `SendTrain`, `Integration`, `TrainPr`,
   `ReviewRequest`, `EarlyCi`, `BoardingHold`, `BoardingRelease`, `PushOutcome`, `Shipment`); the whole of `delegate`
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
7. **The commit-side delivery verbs stay in Hecks.** `Workspace`, `Revision` and `LinkedTree` are what a client's
   agents use for repository work without a pipeline. `Landing` moves; a client that wants landings attaches or runs
   Switchyard.
8. **QualityControl stays for now.** It drives fuzzing, the corpus and era mints, which judge the framework, and it
   also feeds Fixer and Coder. Where it is cut is a later decision, taken once Switchyard stands.

Items 6 and 7 are the recommendation; the owner has not chosen yet.

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

## Order of work

1. The `Gate` port, in this repository (decision 4).
2. Switchyard's repository with `delegate`, the moved part of `deliver`, the watchers and their adapters, on the
   pinned Hecks. The old commands stay here until the new ones have run a landing and a boarding.
3. The board and the Agents, Coder, Fixer, Triage and Pipeline bluebooks.
4. The old code and its lines of `hecks.world` leave this repository, in a release that names the break.

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
  (`Registry::SagaAnchor`), and `Shipment` is Memory in every checkout today, so the saga ends with the process that
  shipped. Binding `Hecks::Shipment.persisted_by("SqlitePersistence")` in a checkout's local hecksagon keeps it. That
  file is the machine's own and is not changed here.
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
- **Depend on the released gem.** A pipeline fix that needs a framework change would wait for a release. The pinned
  worktree gives the same isolation and moves in seconds.
