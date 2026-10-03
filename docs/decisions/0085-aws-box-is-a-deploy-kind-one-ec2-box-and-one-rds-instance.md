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
3. The projection (`projects_as :aws_box`) emits eight files: `rds.yaml`, `box.yaml`, `Caddyfile`, `services.json`, `render-compose.sh`, `fetch-secrets.sh`, `deploy-box.sh` and a `Makefile`.
4. The box is described by `services.json`, not by an ECS task definition. The generated `deploy-box.sh` renders a Compose file from it, rolls it over SSM and health-checks the proxy.
5. Golden files for a minimal, a full and a tunnel world live in `spec/fixtures/deploy_box_golden/`.
6. The `tunnel` setting has two forms. `tunnel true` opens the outbound port for a tunnel the project runs itself. `tunnel({ to: "<container>", token_secret: "<name>" })` also runs `cloudflared` as a service in the box's Compose project, forwarding to that container's port, with its token read from the named secret (which the box role may read) and a check after the roll that a connection registered. Its image defaults to `cloudflare/cloudflared:latest` and can be set with `image`.

## Consequences

- A project that fits the shape gets the cheaper stack from a world file, with the same refusal-before-render behavior as Fargate.
- The box is a single point of failure. Snapshots, auto-recover alarms and a rebuild from the stack are the mitigation, not redundancy.
- A Fargate project does not move by changing one word: the data moves by dump and restore, and the cutover is a project-specific runbook the generator does not write.
- The Deploy chapter gains a command and an OIDC scope.

## Alternatives considered

- **A `box` switch on `AwsFargate`.** Shares the settings parser, but the two stacks share almost no template; the switch would be most of the file.
- **Keep it in the client's platform repository.** Works for one client, and every next one copies it.

## Open items

- Migration and cutover tooling from an existing Fargate stack.
- A source for the Compose file other than `services.json` (a task definition, for projects that already have one).
- Pinning the proxy and tunnel images by digest. The tunnel image defaults to `latest` today.
