# Deploy and smoke scripts become commands on the Deploy chapter

**Status:** Proposed. Date: 2026-10-05. Continues [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) (a script becomes a command with its outside work behind a port) for the scripts a deployed project keeps, and [ADR 0085](0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md) (the `AwsBox` kind that generates most of them). One slice is built, `smoke_run.run`; the rest is the plan.

## Context

A project deployed to an `AwsBox` runs a mix of shell it cannot see into:

- Seven scripts the projection generates from templates (`deploy-box.sh`, `deploy-service.sh`, `fetch-secrets.sh`, `render-compose.sh`, `restore-to-rds.sh`, `smoke-after-deploy.sh`, `verify-copy.sh`). They are correct and tested against stand-in `aws`, `docker` and `gh` programs, but a run leaves no record: no journal entry, no query for "when did the last smoke fail", no refusal the model checker can see.
- Hand-written scripts in the project's platform directory: a bluebook-diff script, a preview script, and an analytics-service deploy script. These are not generated, so they drift from the rest.

ADR 0080 settled the shape: a rule becomes a `given`, a side effect sits behind a port, a result is an event. The Deploy chapter already follows it for `CostCheck`, `MakefileCheck` and `TemplateComparison`: a request command, a policy that asks a port, and a pass or flag command that records the answer.

## Decision

1. Each script gets an aggregate in the Deploy chapter whose `Run` command takes the script's inputs, asks the `DeployToolchain` port, and records `passed` or `flagged`. The aggregate is named for the thing that ran (a roll, a smoke), so its journal reads as a history of rolls and smokes.
2. **Generated stays generated, for now.** The projection keeps writing the shell. The adapter runs the generated file with the inputs as the environment variables it already documents, and maps its documented exit statuses to the reason a refusal gives. Nothing about `make deploy` changes, so a project adopts a command at its own pace. Moving the logic out of shell and into Ruby adapters (and then deleting the template) is a later step per command, taken only when the command's specs hold the behaviour.
3. Rules the script checks by hand move to `given`s when they are about the inputs (a task definition is a family name, an exclusive pair of options) and stay in the script when they are about the live world (a stack's status, a container's state).
4. Every command is `hecks deploy <aggregate>.run` and is added to `settled` in `hecks.world`, so a flagged run is exit 1 without `--wait`.
5. Specs run the generated golden script against the stand-in programs of `spec/support/box_hosting_stubs.rb`, through the launcher.

### The command table

| Script | Command | Givens | Outcomes | Generated or adapter |
|---|---|---|---|---|
| `smoke-after-deploy.sh` | `smoke_run.run` (built) | `taskdef` is a family or `family:revision` | `passed`; `flagged` with status 20 (roll did not settle), 21 (no `gh`), 22 (smoke failed), 23 (unknown) | script stays generated; adapter runs it |
| `deploy-box.sh` | `box_roll.run` | `taskdef` named, or the family's latest | `rolled`; `flagged` (stack failed, health check failed) | generated |
| `deploy-service.sh` | `service_roll.run` | `service` is one of the world's containers; `tag` unused unless `existing_tag` | `rolled` (with the tag and revision); `flagged` (tag already in ECR, update failed, image missing from the task definition) | generated; a roll may chain a smoke by policy on `Rolled` |
| `fetch-secrets.sh`, `render-compose.sh` | none: steps inside `box_roll.run` | | | stay generated, run on the box |
| `restore-to-rds.sh` | `data_copy.restore` | `source` and `target` named; `bastion` named | `restored`; `flagged` | generated |
| `verify-copy.sh` | `data_copy.verify` | same | `matching`; `drifted` with the tables that differ | generated; `restore` chains it by policy |
| bluebook-diff script | `bluebook_diff.run` | a project and a registry named | `matching`; `drifted` | hand-written; becomes adapter code (no AWS) |
| preview script | `preview_run.run` | a branch named | `previewed` (with the URL); `flagged` | hand-written; becomes adapter code |
| analytics-service deploy script | `service_roll.run` on a world with one container, or its own kind if its shape differs | | | decided when its script is read in full |

The three hand-written scripts live in a client's repository and were described, not read, for this ADR; their rows are the shape to expect and are confirmed when each is moved.

### Built in this change

`SmokeRun` (`smoke_run.run <smoke-after-deploy.sh> [taskdef=] [skip=true] [async=true] [dry_run=true]`), the `Smoke` ask on the `DeployToolchain` port, and its adapter method. It is the lowest-risk first row: it only reads AWS, it is already covered by stand-in programs, and it has a documented exit-status contract.

## Consequences

- A smoke or a roll becomes a record: `smoke_run.flagged` lists every smoke that failed, and the MCP door can run it.
- The command wraps the script rather than replacing it, so there are two entry points until a project switches its Makefile over. The Makefile can keep calling the script; a project that wants the record calls the command.
- A script whose logic moves into Ruby needs its own stand-ins for `aws` and `gh` at the adapter boundary, not at `PATH`.

## Out of scope

- Writing to AWS or GitHub from a command in this change, and deploying anything.
- Deleting or changing any generated template or golden file.
- The Fargate and Lambda kinds' scripts; they follow when a project asks.
- Scheduling a smoke or a cost check (ADR 0081 lists scheduled commands as unbuilt).
- Cutover steps a person performs (bastion creation, CDN origin switch), which stay in the migration runbook.

## Open items

- Whether a roll and its smoke are one aggregate with two phases or two aggregates joined by a policy. This ADR prefers two, so a smoke can be run alone.
- Whether `run` should take the project and find the script, instead of a path; the path is used now because the generated directory's name is the project's choice.
