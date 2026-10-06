# `Vercel` is a deploy kind: the domain's host as one function

**Status:** Proposed. Date: 2026-10-06. `hecks deploy project` generates AWS stacks. A project whose front end already lives on Vercel can run its domain there too, as one function reading a Postgres database it does not own.

## Context

`AwsLambda`, `AwsFargate` and `AwsBox` all create the database and the compute. Vercel creates neither a database nor a long-lived process: a request runs a function, and the database is a marketplace product or an instance the project already has. So the Vercel kind generates configuration and a deploy script, not infrastructure.

## Decision

1. Add a deploy kind, `deployed_to("Vercel")`, as a sibling of `AwsBox`. Settings: `region` (a Vercel id, default `iad1`), `memory` (MB, default 1024), `max_duration` (seconds, default 30), `stack_name` (the project name), `scope` (the team), `crons`, `env`.
2. **Bluebook side:** `Deploy::VercelTarget.Declare` validates region, memory and duration, so they are in the journal and the OIDC manifest like the other targets. `Vercel::Settings` checks every other setting against a conservative pattern before anything is written.
3. The projection (`projects_as :vercel`) emits four files: `vercel.json` (the function's size, the region, one rewrite that sends every path to `api/host`, crons), `.vercelignore`, `deploy-vercel.sh` and a `Makefile`.
4. **Hecksagon side:** persistence is Postgres by URL. The host reads `DATABASE_URL`; the deploy script always sets it, plus any names in `env`. A world that declares no database gets none: the projection never creates one.
5. Secrets are named, never held. `deploy-vercel.sh` reads each variable from the caller's environment (`op run -- make deploy`) and pipes it to `vercel env add --sensitive` on stdin, so no value is on a command line or in a file.

## Consequences

- A project that fits gets its Vercel configuration from a world file, with the same refusal-before-render behavior as the AWS kinds.
- Nothing is rehearsed or rolled back by the generator; Vercel keeps every deployment and promotes by alias.

## Alternatives considered

- **Frontend only (rewrites to an existing origin).** Cheaper, but then nothing from the domain runs on Vercel; left for a later mode.
- **A Build Output API directory.** Binds the generator to a prebuilt layout; `vercel.json` plus the Rust runtime's own build is what Vercel documents.

## Open items

- The host has no Vercel entry point yet. Vercel's Rust runtime (beta) takes a binary at `api/host.rs` built on `vercel_runtime`, not `lambda_runtime`; `rust/host` has to gain one (and a `[[bin]] name = "host"`) before a generated project deploys. Until then the generated files are correct but nothing answers at `/api/host`.
- Nothing yet deploys a generated project to a real Vercel account; the projection is unit-tested only.
