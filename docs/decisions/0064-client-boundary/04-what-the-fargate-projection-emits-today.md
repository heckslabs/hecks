# 04: What the Fargate projection emits today

**Status:** Resolved (research, 2026-09-26) · **Type:** research (AFK) · **Blocked by:** none · **Claimed by:** research subagent
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Before deciding who generates a client's deploy and smoke tooling (ticket 10), establish the gap between what Hecks generates and what a client site actually runs.

- **Read** `lib/hecks/projections/deploy/fargate.rb`, `shared.rb`, `bin/project_deploy` and the `.world` deploy block grammar, and what a generated deploy directory contains.
- **Compare** it with the client site's hand-written stack: a multi-container service (website, CMS, domain), load balancer, CDN, alarms, a domain image built with the compiled wasm and IR as sidecars, per-branch preview stacks, and the deploy, smoke and expected-era scripts.
- **Report** what is emitted today, what is missing, the parameters the missing parts would need from a `.world` block (region, owner stack, database stack, prefix, service list, image repositories, smoke workflow file, session cookie name), and where the generator's structure would have to grow.
- **Assess feasibility** of generating the client's current stack such that a CloudFormation change set against the live stack is empty. Describe how to check it. Reading existing stacks is fine; creating or executing a change set is not without the owner's approval.

Read-only. Client-specific constants (names, hostnames, addresses, identifiers) are left out of this record.

## Findings

Run on 2026-09-26 against `origin/main` at `c5467a68` and the client site's live stack, using read-only calls only. No change set, drift detection or other write was created or executed.

**What Hecks emits today.** `Fargate.call` in `lib/hecks/projections/deploy/fargate.rb` returns `template.yaml`, `Dockerfile`, `Makefile`, and `bastion.yaml` (except for a Shared database). `bin/project_deploy` writes them to `deploy/<infra_name>/` or `--out=`. The template holds exactly one container per domain: an image repository, cluster, log group, session secret, execution and task roles, task definition, one target group, a load balancer open only to the CDN's prefix list, one HTTP listener, the ECS service, and one CDN distribution with the default certificate and a single behavior. The only always-present parameter is `ImageTag`. The Makefile cross-compiles the host, runs `bin/project_wasm`, builds and pushes the image, runs `aws cloudformation deploy`, and offers `mint-era` through a bastion (a no-op for Shared).

**Grammar.** `deployed_to("AwsFargate") { ... }` validates `region`, `cpu`, `memory`, `port`, `database` (Postgres, Aurora, Shared) and `web` (None, Rust). `desired_count`, `stack_name`, `stack_prefix`, `owner`, `owner_stack` and `schema` are read as raw settings. A `GOOGLE_CLIENT_ID` line in `.env.local` adds the OAuth parameter, policy and environment.

**Test run.** The stock banking world declares Lambda, so a Fargate variant with the client's settings was generated into a scratch directory in the job's `tmp`. It showed: the Makefile bakes in absolute paths for the Hecks checkout and the domain; logical ids and resource names are derived from the infra name and prefixed, where the client uses short fixed ids; the stack name is `<stack_prefix>-<stack_name>`; and the repository, cluster, family and container names are all the infra name, where the client uses one name per service.

**What the client's live stack has that is not generated.** 36 resources, one task with three containers (website, CMS, domain), three image repositories and target groups, and four path-routing rules on one load balancer. A retained CDN distribution with three aliases, a managed certificate, a second storage origin, about 14 cache behaviors and an origin-secret header. A media bucket, CMS and session secrets and many name-pattern IAM grants. A notification topic, four load-balancer alarms, a CDN monitoring alarm, a synthetic-check alarm and a warmer function with its schedule. Service tuning (exec, health-check grace period, deregistration delay) and one image-tag parameter per container. The domain image also carries a bluebooks manifest. Per-branch preview stacks use a separate 634-line template and a 369-line script. The deploy script clones the live task definition, swaps one image, then syncs one stack parameter. The smoke script waits for the roll to settle and dispatches a workflow.

**Gap (generator side).**

| Capability | Emitted today | Parameters it would need from the world block |
| --- | --- | --- |
| Multi-container task and service | No (exactly one container) | list of containers: name, repository, port, health path, environment, secrets |
| Path routing across target groups | No (one default listener) | path lists per container, priorities |
| Per-service repositories and image-tag parameters | Partly (one repository, one tag) | repository names, tag parameters |
| Fixed logical ids and resource names | No (derived from infra name) | a logical-id map or naming scheme |
| CDN aliases, certificate, many behaviors, origin secret, second origin, retain policy | No | domain names, certificate, behaviors, origin secret |
| Alarms, notifications, synthetic warmer | No | alert address, alarm list, warmer paths |
| Buckets, CMS secrets, extra IAM grants | No | buckets, secrets, grants |
| Service tuning | No | service and target-group options |
| Domain environment beyond OAuth | Partly | environment map, session cookie name |
| Domain sidecars (wasm, IR) | Yes, but the install path differs | a path parameter |
| Per-branch previews | No | a preview block |
| Deploy scripts, pinned-tag Makefile | Partly (`make deploy`) | version pin, owner and database stacks |
| Smoke, era check, post-deploy workflow | No | smoke workflow, repository, expected era (this is ticket 10's question) |

**Feasibility of an empty change set.** Not achievable by tuning the current generator. It needs a generalization that can pin every logical id, name and property. Today's output would use different logical ids, so CloudFormation would delete and recreate: the media bucket's contents would be lost, image repositories that hold images cannot be deleted, regenerated secrets would log every user out, and the retained distribution would be orphaned and then hit an alias conflict.

- **Readable and checked:** the live template matches the committed template apart from em-dash rendering (the working tree lacks only one newer environment variable); stack status, capabilities and parameter keys; the resource list; and the ECS service and the stack's task definition are on the same revision, so no out-of-band task-definition drift.
- **Not checked:** stack drift detection; live load-balancer rules, CDN configuration and IAM policies against the template. One listener rule cited in the preview template is absent from the live template; if the rule is live it is unmanaged, which is worth confirming.
- **Safe check:** generate to a scratch directory; parse both templates with a CloudFormation-tag-aware loader; compare resources by logical id and properties, and Parameters and Outputs, ignoring comments; supply live values with `UsePreviousValue` for `NoEcho` parameters; only then, with the owner's explicit approval, create a change set and inspect it without executing it.
- **Risks:** live parameter values (image tags, the origin secret) differ from defaults and must come from the stack; ordering, defaults and CloudFormation's own property rewriting can make an equal template look changed; the retained distribution and the pinned secret names must match exactly; regeneration must use the same Hecks tag as the running image; and the deploy script changes the live task definition out of band, so a generated flow must keep that model or the parameters drift.

## Decision

Not applicable. Findings recorded; ticket 10 is now unblocked.
