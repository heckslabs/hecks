# Deploy and smoke scripts become commands on the Deploy chapter

**Status:** Proposed. Date: 2026-10-05. Continues [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) (a script becomes a command with its outside work behind a port) for the scripts a deployed project keeps, and [ADR 0085](0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md) (the `AwsBox` kind that generates most of them). Two slices are built: `smoke_run.run`, and the two rolls, `service_roll.run` and `box_roll.run`. The generated `make deploy` and `make deploy-service` call the rolls, whose policy requests the smoke; the rest is the plan.

## Context

A project deployed to an `AwsBox` runs a mix of shell it cannot see into:

- Seven scripts the projection generates from templates: `deploy-box.sh`, `deploy-service.sh`, `fetch-secrets.sh`, `render-compose.sh`, `restore-to-rds.sh`, `smoke-after-deploy.sh` and `verify-copy.sh`. They are tested against stand-in `aws`, `docker` and `gh` programs, but a run leaves no record: no journal entry, no query for "when did the last smoke fail", no refusal the model checker can see.
- Three hand-written scripts in a client's platform directory, read for this ADR:
  - `bluebooks-diff.sh` prints which bluebook releases a domain deploy changes. It reads the running image's `ai.embryonaut.bluebooks` label out of ECR with the AWS CLI alone (read-only, no `docker pull`: the active task definition's image tag, its manifest, the arm64 entry of an index, the config blob), reads the same label from the local image about to be pushed (or two JSON files given as `--old` and `--new`, no AWS), and compares name, version, shape and digest per bluebook. It marks a new era, and a same-version change in content. It is informational: it always exits 0, because the era check gates a deploy, not this report.
  - `preview.sh` keeps one isolated stack per git branch (`deploy`, `destroy`, `list`, `url`, `name`, `login`). It derives every name from the branch (with a hash when the slug was altered or truncated), refuses `main` and `master`, only touches stacks named `<prefix>-*`, pushes the already-built images, creates the branch's database, deploys a separate preview template, and can mint a signup token that signs the caller in as the preview's first administrator. `deploy` and `destroy` write to AWS; `name`, `url`, `list` do not.
  - `deploy-umami.sh` rolls a second Compose project (Umami and its tunnel) onto the app box beside the app's project, so an app deploy never removes it. It reads one container's image, environment and secret references from an ECS task definition, builds `compose.json` and `secrets.json` on the laptop, sends them over SSM with the generated `fetch-secrets.sh` (secret values never travel; the box resolves them), pulls and starts the project, then runs a check on the box: heartbeat, a bad login answering 401, and a registered tunnel connection.

ADR 0080 settled the shape: a rule becomes a `given`, a side effect sits behind a port, a result is an event. The Deploy chapter already follows it for `CostCheck`, `MakefileCheck` and `TemplateComparison`: a request command, a policy that asks a port, and a pass or flag command that records the answer.

## Decision

1. Each script that runs from a laptop or CI gets an aggregate in the Deploy chapter whose `Run` command takes the script's inputs, asks the `DeployToolchain` port, and records `passed` or `flagged`. The aggregate is named for the thing that ran (a roll, a smoke), so its journal reads as a history of rolls and smokes.
2. **A command takes the project, not a file path.** It finds the generated script itself: beside the project's `Makefile`, else the only one beneath the project; none or several is a refusal that names `script=<path>`, the optional override. A project passes the same directory it generated into.
3. **Where the work stays shell and where it moves.**
   - Scripts that run on the EC2 box (`fetch-secrets.sh`, `render-compose.sh`, and the checks a command sends over SSM) stay shell. The box has no Ruby, and these are small enough that a generated, golden-tested script is the right shape. They are steps inside a command, never commands of their own.
   - Orchestrators that run from a laptop or CI become commands. While a script's logic is only worth running as it is, the adapter runs the generated script with the inputs as the variables it documents and maps its documented exit statuses to a reason; the command and the script share one logic. When a command's specs hold the behaviour, its logic can move into a Ruby adapter and the template can go. Which of the two a command is at any time is not visible to its callers.
4. Rules about the inputs move to `given`s (a task definition is a family name; exactly one of two options). Rules about the live world (a stack's status, a container's state) stay where the world is read.
5. Every such command is `hecks deploy <aggregate>.run` and is added to `settled` in `hecks.world`, so a flagged run is exit 1 without `--wait`.
6. **A roll and its smoke are two aggregates joined by a policy.** A roll records `rolled` and a policy requests a smoke under the roll's own run key, unless the roll was given `skip_smoke=true`; a smoke can still be run alone. Built: `ServiceRoll` and `BoxRoll` are the two roll aggregates, and `SmokeAfterServiceRoll` and `SmokeAfterBoxRoll` are the policies.
7. **`make deploy` calls the command, and the record is persisted.** For a project that generates the hosting scripts, the `Makefile`'s `deploy` runs `$(HECKS) deploy box_roll.run project="$(CURDIR)" run="$$run" --wait` where it ran `deploy-box.sh`, and `hosting.mk`'s `deploy-service` runs `service_roll.run` where it ran `deploy-service.sh`. The roll's policy requests the smoke, so one deploy leaves a roll and a smoke. The commands run in the normal environment, so the Hecks domain binds to `HECKS_DATABASE` (default `postgres://hecks@localhost/hecks`) and each deploy's `BoxRoll` or `ServiceRoll` and `SmokeRun` are durable and queryable. A project without the hosting scripts has no smoke script for the policy to run, so its `deploy` stays the generated script.
   - **A failed roll is exit 1**, with the script's own status in the message (the table below). The command's `--wait` exit covers the roll only: a smoke that ended `flagged` leaves the roll `rolled`, so the target reads `smoke_run.verdict run=$$run` after the command and fails (exit 1, the smoke's reason on standard error) unless it says `passed`. `SKIP_POST_DEPLOY_SMOKE=1` becomes `skip_smoke=true`: the policy requests no smoke and the target reads none.
   - **One-time setup.** A machine that runs `make deploy`, a laptop or a CI runner, needs that database: `createdb hecks` on a local Postgres, or `HECKS_DATABASE` pointing at one it reaches. The first run creates the tables. A CI job that runs `make deploy` needs a Postgres service and the variable too.
   - **A missing database does not stop the deploy.** The command cannot start without its database, so the target detects the launcher's `cannot open Hecks` failure, prints that error and the setup step, runs the generated script itself (and, for `deploy`, the smoke script after it), and exits non-zero: with the script's own status when it failed, or 24 when everything passed but the record could not be written (make reports it as `Error 24`; make's own status is 2). The database error and the deploy's outcome are stated separately.
   - `smoke-after-deploy` as a target of its own still runs `smoke_run.run`, so a smoke can be run alone.
8. Specs run the generated golden script against the stand-in programs of `spec/support/box_hosting_stubs.rb`, through the launcher. The goldens come from the generator.

### The command table

| Script | Command | Givens | Outcomes | Generated or adapter |
|---|---|---|---|---|
| `smoke-after-deploy.sh` | `smoke_run.run <project>` (built) | `taskdef` is a family or `family:revision` | `passed`; `flagged` with exit 20 (roll did not settle), 21 (no `gh`), 22 (smoke failed), 23 (unknown) | the script stays generated; the adapter runs it |
| `deploy-box.sh` | `box_roll.run <project> [taskdef=\|tags=] [skip_smoke=]` (built) | `taskdef` is a family or `family:revision`; `tags` are `name=tag` words; `skip_smoke` is a switch | `rolled`; `flagged` with exit 40 (no instance), 41 (the roll did not succeed on the box), 42 (the box is not healthy after it); a policy requests the smoke | the script stays generated; the adapter runs it |
| `deploy-service.sh` | `service_roll.run <project> service= [existing_tag=] [local_image=] [skip_smoke=]` (built) | `service` is a container name (the script refuses one the world lacks); `existing_tag` redeploys a tag already in ECR | `rolled` (with the tag and task definition); `flagged` with exit 2 (unknown service), 30 (existing tag not in ECR), 31 (fresh tag already in ECR), 32 (the box's Compose file unreadable), 33 (no instance), 34 (the stack has no such parameter), 35 (the stack update failed or did not settle), 36 (another parameter changed), 37 (the task definition lacks the pushed image), 38 (no such container in the task definition), 40 to 42 (the box roll's); a policy requests the smoke | the script stays generated; the adapter runs it with `SMOKE_BY_COMMAND=1` |
| `fetch-secrets.sh`, `render-compose.sh` | none: steps inside the rolls | | | stay shell, run on the box |
| `restore-to-rds.sh` | `data_copy.restore <project>` | `source`, `target` and `bastion` named | `restored`; `flagged` | generated |
| `verify-copy.sh` | `data_copy.verify <project>` | same | `matching`; `drifted` with the tables that differ | generated; a policy on `restored` requests it |
| `bluebooks-diff.sh` | `bluebook_diff.run <project>` with optional `old=`, `new=` | `old` and `new` are given together or not at all | `unchanged`, `changed` (each bluebook added, removed, re-versioned, new era, or same version with different content), `unavailable` (a lookup failed, with its reason). Never a failure | the comparison is pure and moves to Ruby; the ECR and local-image reads sit behind a port, read-only |
| `preview.sh name`, `url`, `list` | `preview_run.name`, `.url`, `.list` | the branch is not `main` or `master` and has usable characters | the derived names; the stacks that exist | name derivation is pure and moves to Ruby; `url` and `list` read AWS |
| `preview.sh deploy`, `destroy`, `login` | `preview_run.deploy`, `.destroy`, `.login` | same; only stacks under the preview prefix are touched; images exist locally | `deployed`, `destroyed`, `signed_in` (with the line to paste); `flagged` | writes to AWS, so a later slice, behind a port a spec replaces |
| `deploy-umami.sh` | `companion_roll.run <project> taskdef=` | the task definition has the container; the box exists | `rolled` with the containers' status and the box check's result; `flagged` | stays an orchestrator over SSM; the box check is a script sent to the box |

### Built in this change

Slice 1: `SmokeRun` (`smoke_run.run <project> [script=] [taskdef=] [skip=true] [async=true] [dry_run=true]`), the `Smoke` ask on the `DeployToolchain` port, its adapter method, and the generated Makefile calling it.

Slice 2, the rolls: `ServiceRoll` (`service_roll.run`) and `BoxRoll` (`box_roll.run`), the `RollService` and `RollBox` asks and their adapter methods, and a policy on each `Completed` event that requests a `SmokeRun` (the same `run` key, the roll's task definition when it named one). Both wrap the generated script. The scripts changed in three ways, all regenerated into the goldens: `deploy-box.sh` and `deploy-service.sh` end with distinct statuses (table above) instead of 1; `deploy-service.sh` ends after the roll, printing `rolled taskdef=<td> tag=<tag>`, when `SMOKE_BY_COMMAND=1` (the command sets it, the policy runs the smoke); and the Makefile and `hosting.mk` recipes call the commands (decision 7). Specs run the golden scripts against the stand-in programs, and the recipes against a stand-in `hecks`.

Still scripts, unchanged: running the scripts by hand, which still smokes at the end of `deploy-service.sh`.

## Consequences

- A smoke becomes a record in the run's journal, and `smoke_run.flagged` lists the ones that failed; the MCP door can run it. A roll is a record too: `box_roll.flagged` and `service_roll.flagged` list the rolls that failed, with the script's status in the reason.
- A deploy that writes to AWS is now one `hecks deploy` command from the MCP door as well; a door that exposes it should treat `service_roll.run` and `box_roll.run` like any other command that changes a live system.
- `make deploy` now needs a `hecks` and a Hecks database on the machine that deploys (decision 7). Which machines and workflows need one is a deployment fact: this repository's workflows do not run `make deploy`.
- A project must regenerate its recipe to pick up the new Makefile and scripts; until then it keeps calling the scripts, and `make deploy` leaves no record.
- A script whose logic moves into Ruby needs stand-ins for `aws` and `gh` at the adapter boundary, not on `PATH`.

## Out of scope

- Deploying anything from this change: the roll commands write to AWS when a person runs them, and this change's specs only ever run them against stand-in programs.
- Changing the on-box scripts, or the generated scripts beyond their exit statuses and the `SMOKE_BY_COMMAND` end.
- Building the restore, verify, diff, preview and companion rows; this ADR only fixes their shape.
- The Fargate and Lambda kinds' scripts; they follow when a project asks.
- Scheduling a smoke or a cost check (ADR 0081 lists scheduled commands as unbuilt).
- Cutover steps a person performs (bastion creation, CDN origin switch), which stay in the migration runbook.

## Open items

- A persistent journal for deploy commands: decided, persisted (decision 7). Retention of old `SmokeRun`, `BoxRoll` and `ServiceRoll` rows is not decided.
- The roll's exit status says nothing of the smoke it requested; the Makefile reads the smoke's verdict. Whether the roll aggregate should also record the smoke's outcome (a later transition driven by a policy on `SmokePassed` and `SmokeFlagged`) is not decided.
- Whether `preview_run` belongs to the Deploy chapter or to a Fargate-specific one, since the preview stack is a separate template from the live one.
