# An AwsBox box ships every container log to CloudWatch

**Status:** Proposed. Built: the `logs` and `log_retention_days` settings, the `awslogs` compose entries, the `BoxLogGroup` resource and
role policy in `box.yaml`, and the log group check in `deploy-box.sh`. Date: 2026-10-16.

## Context

Every service in the box's `compose.json` logged with Docker's `json-file` driver (10 MB, 3 files), so a container's log lived on the
box and was deleted with the container when a roll replaced it. ADR 0085 added a capture of each log to `/var/log/hecks-captures`
before a roll, which keeps 14 files on one disk. A project that relied on its containers' logs as evidence (the lines a shadow run
writes before an enforcement is switched on) lost them across rolls, and nothing left the box.

## Decision

1. **Every service ships to CloudWatch Logs by default.** `render-compose.sh` gives each service, the proxy and the tunnel sidecar the
   `awslogs` driver with `awslogs-region` (the stack's region), `awslogs-group` (`/<box stack name>`, such as `/hecks-widget-shop-box`),
   `awslogs-create-group: "false"` and `tag` set to the service name, so each service has one stream named by the service and a rolled
   container continues it.
2. **The stack owns the group.** `box.yaml` creates `BoxLogGroup` with a fixed `RetentionInDays` and adds a `write-logs` policy to the
   box role: `logs:CreateLogStream`, `logs:PutLogEvents` and `logs:DescribeLogStreams` on that group's ARN only. A production group is
   retained when the stack is deleted; a rehearsal group is deleted with its stack.
3. **Declared in the world.** `logs "cloudwatch"` (the default) or `logs "local"`, which renders exactly the previous `json-file`
   output and adds no group, policy or check. `log_retention_days` defaults to 30 and must be one of CloudWatch's own retention values
   (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653); "never expire" is not
   allowed, so the log bill is bounded by a declaration.
4. **A roll refuses a stack without the group.** The `awslogs` driver fails a container's start when it cannot write its stream, so
   `deploy-box.sh` first asks CloudFormation for `BoxLogGroup` and exits 44 if the box stack lacks it (`SKIP_LOG_GROUP_CHECK=1` skips
   the check). The group and the role policy are in the same template, so the group's presence means the policy was deployed with it.
5. **`docker logs` keeps working.** Docker's dual-logging cache (Docker 20.10 and later) keeps a local copy for reads with any driver, so
   `docker logs`, `docker compose logs` (the tunnel probe uses it) and the pre-roll capture are unchanged. The box installs Docker from
   the Amazon Linux 2023 package, which is newer than 20.10.
6. **No bluebook change.** Where a box's logs go is a fact about the deployed stack, not the domain; the two settings are read by
   `Box::Settings` like the other `deployed_to("AwsBox")` settings and checked there.

## Consequences

- A project that regenerates gets new `box.yaml`, `render-compose.sh` and `deploy-box.sh`. **Order matters:** run `make stacks` (creates
  the group and the policy) before the next `make deploy`. A roll with the new `render-compose.sh` onto an old stack exits 44.
  The check cannot see an IAM policy changed by hand; a stack edited outside the template can still fail at container start.
- Streams are per service, not per container. Two containers of one service running together would share a stream; the box runs one.
- The logs are in the stack's region and account; reading them needs `logs:GetLogEvents` or Insights, which the operator has, and the
  box role does not.
- A project that wants to keep today's behaviour declares `logs "local"`.
