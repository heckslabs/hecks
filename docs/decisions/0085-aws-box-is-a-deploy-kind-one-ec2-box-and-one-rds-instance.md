# `AwsBox` is a deploy kind: one EC2 box and one RDS instance

**Status:** Proposed. Date: 2026-10-02. A domain that runs a few containers and a Postgres database does not need a load balancer, a container service and a database cluster. One client project moved to a single EC2 box behind Caddy and a plain RDS instance by hand; this ADR makes that shape something `hecks deploy project` generates.

## Context

`hecks deploy project` generates `AwsLambda` and `AwsFargate` stacks. Fargate puts the containers behind an ALB, on a service that is billed per task and has its own database cluster. For a small client project that was most of the bill. The Lifeadelics project replaced it with:

- one RDS Postgres instance (its own stack, so it can be reviewed and rehearsed on its own);
- one EC2 box running the containers with Docker Compose on the host network, with Caddy in front;
- a CDN as the only public origin: Caddy refuses any request that lacks the origin header and secret;
- secrets resolved on the box at deploy time, never written into a template or into SSM text;
- daily EBS snapshots and auto-recover alarms in place of a service scheduler.

That reference is merged in the Lifeadelics repository (`deploy-aws/rds`, `deploy-aws/box`). Nothing in it is specific to that client except the container list, the routes and the secret names.

## Decision

1. Add a deploy kind, `deployed_to("AwsBox")`, as a sibling of `AwsFargate`. Its settings: `containers` (required), `routes`, `default_container`, `origin_header` + `origin_secret`, `secret_prefixes`, `tunnel`, `swap_gb`, `backup_days`, `snapshots_keep`, `database_name`, `engine_version`, `stack_prefix`, `stack_name`, plus the sizes `instance_type`, `volume_gb`, `database_class` and `storage_gb`.
2. The sizes are validated by a `Deploy::BoxTarget.Declare` command in the Deploy bluebook (so they are in the journal and the OIDC manifest like the other targets). Every other setting is checked by `Box::Settings` before a template is written; every string that reaches a template or script is matched against a conservative pattern.
3. The projection (`projects_as :aws_box`) emits eight files: `rds.yaml`, `box.yaml`, `Caddyfile`, `services.json`, `render-compose.sh`, `fetch-secrets.sh`, `deploy-box.sh` and a `Makefile`, and three more when the world declares a `migration` (decision 9).
4. The box is described by `services.json`, not by an ECS task definition. The generated `deploy-box.sh` renders a Compose file from it, rolls it over SSM and health-checks the proxy.
5. Golden files for a minimal, a full and a tunnel world live in `spec/fixtures/deploy_box_golden/`.
6. The `tunnel` setting has two forms. `tunnel true` opens the outbound port for a tunnel the project runs itself. `tunnel({ to: "<container>", token_secret: "<name>" })` also runs `cloudflared` as a service in the box's Compose project, forwarding to that container's port, with its token read from the named secret (which the box role may read) and a check after the roll that a connection registered.
7. Both default images, the proxy and the tunnel, are a version tag plus the digest of the multi-architecture index, so a rebuilt box pulls the same bytes. A world can set `proxy_image`, and the tunnel hash takes `image`; either may be any image reference the generator can splice safely.
8. A world can name an ECS task definition family with `task_definition "<family>"`. The box's Compose file is then rendered at deploy time from that task definition, by the operator's credentials: each declared container takes its image, environment and secrets from the task's container of the same name, `DB_HOST` and `DB_SECRET_ARN` are replaced with the RDS stack's values, and a declared container the task lacks is refused. The world still declares each container's name and port for the proxy. A container that also sets `env`, `secrets` or `repository` is refused, and the box stack makes no ECR repositories, since the task's images already have some. `deploy-box.sh` takes an optional task definition (default: the family's latest active revision), so a project moves off Fargate by pointing the box at the task it already runs.
9. A world that moves from an existing database declares `migration({ schemas: [...], database:, source_database: })`. The projection then also emits `restore-to-rds.sh`, `verify-copy.sh` and `MIGRATION.md`. The restore pipes `pg_dump` into `pg_restore` for each schema through a bastion that can reach both servers, takes the user and password from each server's secret, tolerates the one restore error a Hecks schema's materialized views raise (`hecks_tr_extract` called with an empty search path), refreshes those views with the schema on the path, and ends by running the verify, which compares structure and the exact row count of every table. The bastion, hosts and secrets are arguments, not settings, so one set of scripts serves a rehearsal, the cutover and a rollback copy. The runbook lists the steps in order, with the rollback caveat that writes taken by both databases cannot be merged.

## Consequences

- A project that fits the shape gets the cheaper stack from a world file, with the same refusal-before-render behavior as Fargate.
- The box is a single point of failure. Snapshots, auto-recover alarms and a rebuild from the stack are the mitigation, not redundancy.
- A Fargate project does not move by changing one word: the data moves by dump and restore, and the cutover is a project-specific runbook the generator does not write.
- The Deploy chapter gains a command and an OIDC scope.

## Alternatives considered

- **A `box` switch on `AwsFargate`.** Shares the settings parser, but the two stacks share almost no template; the switch would be most of the file.
- **Keep it in the client's platform repository.** Works for one client, and every next one copies it.

## Open items

- The migration tooling copies schemas between Postgres servers and nothing else. It does not create the bastion, switch the CDN's origin or copy a database a project keeps beside its own (an analytics database, say); those stay in the runbook as steps for a person.
- The pinned default images (version and digest) go stale. Nothing yet bumps them; a bump is a change to `Box::Settings` and the goldens.
