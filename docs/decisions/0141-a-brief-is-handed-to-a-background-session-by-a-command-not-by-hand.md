# A brief is handed to a background session by a command, not by hand

**Status:** Accepted. Built: `agents.bluebook` (`AgentRun`), the `Agents` port in `hecks.hecksagon`,
and `Adapters::ClaudeAgents` (`lib/hecks/hecks/adapters/claude_agents.rb`). On a branch, not released.
Date: 2026-10-28.

## Context

Work is handed to background Claude sessions all day: a brief, a directory, sometimes a named custom
agent. It was done by typing `claude --bg` into a terminal, or by an agent spawning another. Nothing
recorded which briefs went out, which directory each worked in, or whether a session was still going,
and the rules (a brief must say something, an agent name must not be mistaken for a flag, a directory
must be there) lived in whoever typed the line. `CLAUDE.md` says agents do everything through a
command and a missing command is a bluebook change.

## Decision

Every piece says which side it is on.

1. **Bluebook: `AgentRun` is the record, and it holds every rule.** `AgentRun.Dispatch` takes `run`,
   `repo`, `brief` and an optional `agent`. It refuses a brief that is blank (a `given`) and an agent
   name that does not start with a letter or digit (a pattern on `AgentName`), so a name cannot carry a
   flag. Policies then look for the directory, start the session and record it, or record why not. The
   lifecycle is `requested`, then `started` or `refused`, then `finished`. A session that reports
   `done` or `stopped` has finished; `busy` and `idle` have not, and that judgement is a policy's, not
   the adapter's. `AgentRun.Check` asks again; `Running` lists runs started and not known to have
   ended, `Declined` those that never started.
2. **Hecksagon: the `Agents` port.** Three asks: `Locate` (is the directory there), `Start` (start the
   session) and `Examine` (what state is it in). Each answers or refuses with a reason, in the style of
   the other operator ports. `AgentRun` takes the persistence the Hecks domain is given; it adds none.
3. **Adapter: `ClaudeAgents` is the only imperative code.** It looks for the directory, runs
   `claude [--agent NAME] --bg -- BRIEF` in it and reads the session id the command prints, and runs
   `claude agents --json --all` for the state. The command is an argument list, never a shell string,
   and the `--` keeps a brief from being taken for a flag. It holds no rule.
4. **The launcher waits.** `agent_run.dispatch` and `agent_run.check` are settled commands, so a dispatch
   ends `started` or `refused` in one call and prints the session id.

```sh
exe/hecks AgentRun.dispatch! run.value=ship repo.value=$PWD brief.value="run the quick gate and report" agent.value=miette
exe/hecks AgentRun.check! to=ship
exe/hecks query agent_run.running
```

## Consequences

- A dispatch is a record: which brief, where, under which agent, which session, how it ended.
- Specs never start a session. The adapter spec and the runtime spec put a stand-in `claude` first on
  `PATH`; the behaviors cover only the refusals, since a directory that exists would reach the real
  command.
- `Running` only remembers across commands when the copy persists the Hecks domain (the push train
  does); in Memory it lists the runs of one process.
- A session that `claude agents` no longer lists makes `Check` refuse; the run stays `started` until a
  check answers. A later change could treat an unlisted session as ended.

## Rejected alternatives

- **A script that wraps `claude --bg`.** It would carry the rules and leave no record.
- **Checking the directory in the bluebook.** The bluebook names no file; the port is asked.
- **Letting the adapter decide when a session has ended.** Which states mean ended is a rule about the
  domain, so it is the bluebook's.

## Addendum: finished sessions are tidied by a command (2026-10-28)

A finished run's background session is removed by `AgentRun.Tidy`, not by a `claude rm` loop.

- **Bluebook.** `Tidy` is allowed from `finished` and refuses unless the session's last known
  condition is `done` (a `working`, `blocked` or `stopped` session is kept). It emits
  `TidyRequested`; policies then ask the port to `Review` the session, and on `taken_over == false`
  to `Remove` it. `Tidied` moves the run to the terminal status `tidied` and records `tidied_at`.
  `Retain` records why a session was kept (a person took it over, or `claude rm` refused) and leaves
  the run `finished`. Nothing in the journal is erased.
- **Hecksagon.** Two new asks on `Agents`: `Review` (answers `taken_over` and a `note`) and `Remove`
  (answers `removed_at`). The ask is `Review`, not `Inspect`, because the adapter method of the same
  name would shadow `Object#inspect`. `Examine` is unchanged: its answer drives `Finish`.
- **Adapter.** `ClaudeAgents#remove` runs `claude rm <session>` as an argument list.
  `ClaudeAgents#review` finds the full session id in `claude agents --json --all` and asks
  `ClaudeTranscript` whether `~/.claude/projects/*/<id>.jsonl` holds a user message besides the brief
  that is not a tool result. A missing or unreadable transcript counts as taken over.
- **Shape.** A new status, attribute and value object: an additive edge `translations/2-e7114b.bluebook`
  and a moved `shapes.json`. The persisted `AgentRun` store keeps reading.

```sh
exe/hecks AgentRun.tidy! to=<run> --wait
exe/hecks query agent_run.tidyable          # finished runs, oldest first
```

Not expressed: a batch form. `Tidyable` lists the candidates, but a command that runs `Tidy` over a
query's rows has no DSL form, and a policy-free one-call "tidy all" is not possible; tidy each run
named by `tidyable`. `Tidyable` lists every finished run because a query `where` here matches a
status, not the inner value of the `condition` value object; `Tidy` itself keeps the non-`done` ones.

## Addendum: a session's lifecycle and a push's outcome are events (2026-11-02)

A coordinator watching the journal of `agent_run.db` learns when a session works, waits, ends or
fails, and when the train pushed, without polling `~/.claude/jobs` or `git ls-remote`.

- **Session lifecycle.** `AgentRun.Check` reads the job's own state (`~/.claude/jobs/<session>/state.json`)
  through the `Agents` port's `ReadJob`, which replaces `Examine`. The answer, `JobRead`, carries the
  job's `state` and `detail` beside the run's held `condition` as `previous`; policies record a change
  as one of four events, each carrying `condition`, `detail` and the run's directory with its trailing
  slash (`checkout`): `SessionWorking` (`Work`), `SessionBlocked` (`Block`, with the question it waits
  on), `SessionFinished` (`Finish`, done or stopped) and `SessionFailed` (`Fail`, which also moves the
  run to `finished`). A state equal to `previous` records nothing.
- **Dispatch.** `Locate` also says whether the directory's `claude` lists the named agent (the adapter
  reads the list `claude` prints when asked for an agent it lacks); `listed == false` declines the run
  before any session starts, and with no agent named the session runs the default. After `Begin`,
  `AwaitJob` reads the job once the session has had a few seconds to fail, so a session that died at
  once is recorded `SessionFailed`, never left `started`. Locate answers both facts in one ask so the
  reactions after a start stay within the reaction depth limit.
- **Sweep.** `SessionSweep.CheckAll` (`agent_run.check_all!`) checks every `Running` run through a
  `for_each` policy, for a driver to call.
- **Pushes.** The train runs in Memory in its own checkout, so its `SendTrain` events stay there. On
  `BranchPushed`, `CarriedByEarlierPush` and `PushFaulted` the `PushRecords` port runs the boarded
  checkout's own launcher with `PushOutcome.record!`, and that checkout's overlay decides the store.
  `PushRecorded` carries the run, `checkout`, `branch`, `outcome`, `pushed`, `commits` and `report`; it
  is its own aggregate so recording a push fires none of a push's reactions. A recording that fails is
  refused and leaves the push as it ended. A checkout records it in `agent_run.db` once its local
  overlay persists `Hecks::PushOutcome` with `SqlitePersistence`.
