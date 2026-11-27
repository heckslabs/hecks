# The pipeline runs on a cloud box, and the laptop only directs

**Status:** Proposed. Date: 2026-11-27. Asked for by the owner ("We should queue up running the pipeline on the
cloud", then "Whole pipeline", "Moving it to the cloud means duet can run everything" and "The pipeline itself
should run on the board too"). It is the Work item `coders-run-in-the-cloud-adr` of the epic "The pipeline
reaches beyond this laptop and this repo", and it orders that epic's items `a-shared-ledger-every-machine-reads-and-claims-from`,
`a-second-machine-pulls-from-the-shared-queue` and `quick-gate-runs-on-ci`. Builds on
[0136](0136-hecks-defaults-to-memory-and-a-local-hecksagon-opts-in.md),
[0202](0202-a-write-from-a-worktree-to-a-shared-ledger-runs-in-the-main-checkout.md),
[0205](0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md),
[0213](0213-the-run-ledger-stays-on-sqlite.md), [0220](0220-a-run-and-a-day-have-a-spend-bound-declared-as-data.md)
and [0237](0237-rolls-follow-stable-by-policy-guarded-per-service.md). Revised the same day, when the owner moved the
whole pipeline to Switchyard; this record moves there with the pipeline.

## Context

Everything the pipeline does happens on the owner's laptop, and the board is the only way in from outside it.
Read from `main` at 8a8a269 on 2026-11-27:

- **Processes.** Four launchd jobs under `gui/<uid>`: the beat (`dev.hecks.train-beat`, every 60 s under a zsh
  `flock`, `beat_schedule.rb`), `claude daemon run` (`claude_daemon_schedule.rb`), the control process
  (`control_process_schedule.rb`) and the watchdog (`guarding/launch_agent.rb`). Beside them: ticker chains
  (`ticking.rb`), the board and its supervisor (`board_supervisor.rb`) and the webhook listener
  (`github_listening.rb`), the last two on 127.0.0.1.
- **Coders.** `Dispatching::Launcher` runs `exe/hecks` steps (`LinkedTree.pull_main!`, `Work.start!`,
  `Brief.compose!`, `AgentRun.dispatch!`), and `ClaudeAgents#start` runs `claude --agent <role> --settings
  <json> --bg -- <brief>`. A run's liveness is read from `claude agents --json` and `~/.claude/jobs/<id>/state.json`.
- **Stores.** Seven SQLite files under `~/.claude/hecks-dev` (`agent_run.db` at 1.33 GB, `tickets.db`,
  `agents.db`, `pipeline.db`, `catcher.db`, `record_index.db`, `lineage.db`), bound by the local overlay.
- **Claims.** `Work.Start` reads the item's state before it stores, so it takes the read-then-store path, and
  its isolation is the in-process `AggregateLock`. Two processes can both see an item planned and both start
  it. Only insert-only keys (`AgentRun.dispatch!`) are atomic across processes. The beat, the landing claim,
  the landing queue and the train lock are file locks on the local disk.
- **The board.** It reads local refs and never fetches (`pipeline_git.rb`), so it lags GitHub until the owner
  pulls. It reads the job state files, the journal (`events.jsonl`), the live stores and `gh`, and takes one
  write, `POST /api/act`, which runs a launcher step.
- **Paths.** About 30 `Dir.home` sites name `~/.claude/hecks-dev` (25 in code), `~/.claude/jobs`,
  `~/.claude/hecks-train`, `~/.claude/projects`, `~/Library/LaunchAgents` and `~/Projects/...`; four honour an
  override variable.
- **macOS only.** `launchctl`, `zsystem flock`, `osascript`, `/usr/bin/footprint`, `vm_stat`, `sysctl
  vm.swapusage`, `kern.memorystatus_vm_pressure_level` and `hw.perflevel*`, which feed the fill's headroom.
  Some readings already fall back to `/proc`.

What Hecks already has for the move:

- **A box projection.** `deployed_to("AwsBox")` resolves to `BoxTarget` (`deploy.bluebook`), and
  `hecks deploy recipe.project` projects an EC2 box, an RDS Postgres instance, Caddy, compose files, an SSM roll
  (`deploy-box.sh`) with a restore anchor, and secret fetching. Client services already deploy this way.
- **A Postgres adapter with cross-process claims.** It declares `atomic_put`, `optimistic_concurrency`
  (`WHERE hecks_version = $n`) and `dispatch_claims`, with its own outbox, journal, events and sagas.
  `ci-postgres-io.yml` runs its io specs. Nothing runs Tickets, AgentRun or Delivery on it yet.
- **CI that already judges a pushed branch.** `EarlyCi` pushes `ci/<branch>`, opens a draft pull request and
  waits for CI. `ci-checks.yml` runs `gate_run.gate! stage=ci`, and the pre-push attestation lets CI skip what
  the push already proved.
- **Scopes per verb.** `deploy/oidc.json` names one scope per verb (`deploy:box_roll.run`), the shape a door for
  other callers needs.

## Decision

1. **One box runs the whole pipeline: the beat, dispatch, coders, gates, the train, the board and its
   watchers.** The box is projected from a world of the pipeline's own with `deployed_to("AwsBox")`, as client
   services are. No infrastructure is written by hand. The first size is 4 vCPU and 16 GB on arm64
   (`t4g.xlarge`) with a 200 GB volume, and the fill's headroom readings decide when it is too small. The box
   runs Switchyard on a pinned Hecks, not Hecks itself: the owner decided on 2026-11-27 that the whole pipeline
   leaves Hecks for Switchyard ("We can move off the whole pipeline to switch yard"), so the cloud work is built
   with Switchyard as its home. Hecks keeps what any project uses (the `AwsBox` projection and the Postgres
   adapter), and Switchyard uses them as a client does.
2. **The ledger moves to Postgres, on the RDS instance the same projection makes.** This is the shared ledger
   every machine reads and claims from. It revisits 0213, which kept SQLite because one machine and one lock
   line did not pay for the move. A second machine is what pays for it, because SQLite cannot be shared over a
   network. 0213 §4 to §7 list what the move needs first: Postgres twins of `LedgerKeeping`, the outbox purge,
   `sqlite_status` and the resident store reads, a pooler or a single writer, and a replay of the journal into
   era tables in a quiet window.
3. **A claim is atomic across processes before a second process may dispatch.** `Work.Start` takes the
   optimistic path, so of two processes that both read an item planned, one starts it and the other is refused
   by name. Specs prove it on SQLite and on Postgres with concurrent writers, and the corpus proof still holds.
4. **A run's liveness comes from the ledger, not from the machine it runs on.** A run records the machine
   that started it and beats into the ledger. A machine settles, reaps and resumes only its own runs, and
   judges another machine's run lost only when its beats stop. This is
   `a-second-machine-pulls-from-the-shared-queue`.
5. **Coders run on the box as Claude Code, the same loop as on the laptop.** The model credential is the
   owner's own: an API key for the owner's API credits, or a subscription token. The owner puts it into the
   box's secret store himself, and no session, brief or file holds it. The day's spend bound (0220) is set
   below the credit left, so the pipeline stops dispatching before the credit runs out rather than failing
   mid-run.
6. **The quick gate runs on the box before a push, and CI judges the landing.** `EarlyCi` becomes the path
   every coder takes, and the CI verdict on the pushed branch is what `Landing` reads. Nothing runs a gate on
   the laptop. This is `quick-gate-runs-on-ci`.
7. **The board runs on the box beside the pipeline it shows.** It reads the box's ledger and fetches `origin`
   on its own beat, so the commit it names is the one GitHub has. Its pages stay on the owner's tailnet: the
   box joins it, and the board listens on no public address.
8. **Other callers reach the pipeline through one door with scoped, revocable tokens.** Claude Duet sessions
   run in the cloud, cannot join a tailnet and cannot use the owner's browser, so the pipeline answers them at
   one public address. That address serves only the board's JSON (`/api/state` and the reads under `/api`) and
   `POST /api/act`, never the pages, and refuses any request without a bearer token. A token carries scopes in
   the shape `oidc.json` already uses (`pipeline:read`, `pipeline:act:<step>`). The ledger keeps only its hash.
   The owner issues and revokes tokens on the board's settings page, and the journal records every act with the
   token that asked for it. The public address is a Tailscale Funnel on the box by default, so the box needs no
   public IP.
9. **During the move the laptop and the box share one board.** Each machine dispatches from its own ledger,
   and each board lists the other as a project (`/plan/<name>`, from `board-chooses-a-project`), so both
   halves are seen and driven from either board. The cutover is one quiet window (`qa_quiesce.hold!`): back
   up the SQLite files, replay the journal into Postgres, start the box's beat, and stop the laptop's.
10. **After the cutover the laptop only directs.** The owner answers agents and switches settings on the board,
    files epics by mail (the mail spool beat moves to the box), and runs launcher commands against the box
    through the door. Nothing of the pipeline runs on the laptop.
11. **Fixture domains prove the move keeps the pipeline's behavior.** The Pipeline, PipelineBoard, Gate and
    CiPipeline bluebooks get fixture domains in Switchyard's corpus, so their runtime is exercised, not only
    their specs. Each fixture runs on SQLite, as the laptop does, and on Postgres, as the box will, and the two
    runs must agree before a step that changes storage, claims or liveness lands, and before the cutover.

## Order of work

Each step is a Work item on the epic, lands in Switchyard through the merge queue with its specs and the corpus
proof, and leaves the laptop pipeline working. The split that creates Switchyard (0205) comes first and is planned
on its own. Until it lands, a step that is only framework work (a Linux reading, the Postgres adapter, the box
projection) lands in Hecks, and the rest waits for Switchyard.

0. **The fixture domains** (decision 11), as soon as Switchyard exists, so every later step is measured against
   them. *New item.*

1. **One root for the pipeline's state.** Every `Dir.home` site reads one setting (`pipeline_home`, defaulting
   to `~/.claude`), and every macOS reading has a Linux one (`/proc/meminfo` and `/proc/pressure` for `vm_stat`
   and `sysctl`, `flock(1)` for `zsystem flock`). The four schedules project systemd units beside their launchd
   plists. *New item.*
2. **Atomic claims** (decision 3). *New item, the first half of `a-shared-ledger-every-machine-reads-and-claims-from`.*
3. **The ledger on Postgres** (decision 2), with the 0213 prerequisites. *The second half of that item.*
4. **Liveness from the ledger** (decision 4). *`a-second-machine-pulls-from-the-shared-queue`.*
5. **CI judges the landing** (decision 6). *`quick-gate-runs-on-ci`.*
6. **The box world and its projection, with the secret names, the tailnet join and the board's fetch beat**
   (decisions 1, 5 and 7). Projected and checked, not deployed. *New item.*
7. **The door** (decision 8). *New item.*
8. **Deploy and cut over** (decisions 9 and 10), on the owner's yes, since it creates an account's resources,
   spends money and changes the tailnet.

## Consequences

- **Running cost, before model use.** About $98 a month for the box on demand (`t4g.xlarge` at about $0.134 an
  hour in us-west-2) and about $23 a month for `db.t4g.small` Postgres, plus volumes and backups: roughly
  $130 to $140 a month. Third-party price lists, read 2026-11-27; the owner's AWS bill is the measure. A
  one-year reservation lowers the box to about $0.092 an hour.
- **Model cost.** The compute meter will measure it. As a working estimate, a landed item costs a few dollars
  of model use, so $200 of credit covers on the order of 50 to 150 items, against the 75 a day the board showed
  over the 13 days to 2026-11-25. The spend bound decides how fast the credit is used.
- **The laptop is freed** of about 40 resident processes and the 1.33 GB ledger.
- **A broken box stops the pipeline as a broken laptop does today**, and a second box (decision 4) is what
  removes that.
- **Every caller but the owner's own browser goes through tokens**, so access is listed in one place and ends
  when the owner revokes it.

## Alternatives considered

- **Move only the board and copy the laptop's ledger to it.** The owner chose the whole pipeline. A copied
  board is only as current as the laptop that feeds it, and it gives no other caller a way to act.
- **A rented virtual server without a projection.** It is cheaper per month at some providers, but nothing in
  Hecks projects it, so its setup would be written by hand and drift from what the bluebooks say.
- **Containers without a persistent disk (Fargate, Lambda).** Worktrees, the train's copy and long Claude Code
  sessions need a disk that outlives one request.
- **Coders as hosted agent sessions in place of Claude Code on the box.** It would change the loop the
  pipeline's roles, hooks and briefs are written for. It stays open once the pipeline runs on the box.

## Open for the owner

- The AWS account and region the box is projected into.
- API credits or a subscription token for the coders, and the day's spend bound.
- A Tailscale Funnel or a public address for the door.
