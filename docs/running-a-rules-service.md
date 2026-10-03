# Running a rules service: from a bluebook to a deployed API

**Status: a procedure, checked in parts.** Written against `main` at
`512f9c43`. Every step ends with a status line. **Verified here** means the
step was run for real on that commit: a local checkout, the Rust host
built from it, a scratch Postgres database, `curl`. **Not verified here**
means it was not run, and the text says what it is derived from (a
generated file, or a line of code). Nothing in this document was run
against a cloud account. Treat every "not verified here" step as a
hypothesis to test in a throwaway account first.

This document is the procedure ADR 0071 calls for: a team outside the
project defines a bluebook, deploys the Rust host to its own account, and
calls it from a client that is not Ruby, using only the docs. The
[known gaps](#known-gaps) section lists what still stands between this
procedure and that exit test. Read it before you start.

- [What you are building](#what-you-are-building)
- [0. Prerequisites](#0-prerequisites)
- [1. Choose a deploy target](#1-choose-a-deploy-target)
- [2. Define a bluebook](#2-define-a-bluebook)
- [3. Project the deploy target](#3-project-the-deploy-target)
- [4. Build the host](#4-build-the-host)
- [5. Configure the environment](#5-configure-the-environment)
- [6. Run it locally](#6-run-it-locally)
- [7. Authentication and roles](#7-authentication-and-roles)
- [8. Call it from a non-Ruby client](#8-call-it-from-a-non-ruby-client)
- [9. Deploy to your own account](#9-deploy-to-your-own-account)
- [Known gaps](#known-gaps)
- [What was checked, and how](#what-was-checked-and-how)

## What you are building

A *rules service* is a domain whose rules (the `given`, `invariant` and
lifecycle checks of a bluebook) answer over HTTP or a JSON payload to a
client that knows nothing about Ruby. Four pieces are involved:

1. **A bluebook** (`.bluebook`, `.hecksagon`, `.world`) that you write.
2. **Two build artifacts** made from it by `hecks build_wasm`: a
   `<name>.wasm` module holding the compiled rules and a `<name>.ir.json`
   description of the domain.
3. **The host**, `rust/host`, one binary named `bootstrap`. It loads the
   `.wasm` module inside wasmtime, keeps a journal of every accepted
   command in Postgres, and replays it to answer each request. The rules
   run inside the sandbox; the host holds the database connection.
4. **A deploy recipe** made by `hecks deploy project`: a CloudFormation
   template, a Makefile, and (for Fargate) a Dockerfile, all generated
   from the `deployed_to(...)` block of your `.world` file.

The host is one program with two ways to be reached, chosen at boot by
`HECKS_SERVE_MODE`: as an AWS Lambda custom runtime (unset), or as a
long-lived HTTP server (`HECKS_SERVE_MODE=1`). Everything from step 6
onward runs the second mode locally, because a Lambda cannot run outside
AWS. Both modes go through the same request handler
(`rust/host/src/server.rs`, `dispatch_body`).

## 0. Prerequisites

Every tool this document uses is a `hecks` verb that runs from a checkout
of the repository. So the path starts from a clone. The [README](../README.md) quickstart gives the
repository URL:

```sh
git clone <repository URL from the README>
cd hecks
bundle install
```

You also need:

| For | What |
| --- | --- |
| Ruby tools (`hecks docs`, `hecks deploy project`, `hecks build_wasm`) | Ruby and Bundler, as `bundle install` above |
| Building the host | `rustup`. `rust-toolchain.toml` pins Rust 1.98.0 and rustup installs it on first use. Add the WebAssembly target once: `rustup target add wasm32-wasip1` |
| Running locally | A Postgres you can create a database in, reachable over TCP on `localhost` (see [step 5](#5-configure-the-environment) for why not a socket) |
| Deploying to Lambda | An AWS account and credentials, the `aws` and `sam` CLIs, and `cargo-lambda` |
| Deploying to Fargate | An AWS account and credentials, the `aws` CLI, Docker, `rustup target add aarch64-unknown-linux-gnu`, and on macOS the GNU cross-linker `aarch64-linux-gnu-gcc` |

Status: the Rust toolchain items are verified here (the pinned toolchain, the
`wasm32-wasip1` and `aarch64-unknown-linux-gnu` targets and the cross-linker
were present and used). A fresh `git clone` followed by `bundle install` was
not run; the checks used an existing checkout. The Lambda and Fargate tool
lists are read from the generated Makefiles (`build-<Function>` checks for
`cargo-lambda`; `build` checks for `aarch64-linux-gnu-gcc`), not from a fresh
machine.

## 1. Choose a deploy target

`hecks deploy project` knows two targets, selected by the adapter your
`.world` file names in `deployed_to(...)`: `"AwsLambda"` and
`"AwsFargate"`. They differ in the one way that matters for a service other
people call, which is how a caller is authenticated.

| | `AwsLambda` | `AwsFargate` |
| --- | --- | --- |
| What runs | The host as a Lambda function (`provided.al2023`, arm64) | The host as an HTTP server in a container on Fargate |
| How a client reaches it | The Lambda Invoke API with an AWS-signed request. The generated Function URL has `AuthType: AWS_IAM` | Plain HTTP to a CloudFront hostname, behind an Application Load Balancer |
| What authenticates the JSON invoke path | AWS IAM | **Nothing.** Before 2.8.0 any caller could use it; from 2.8.0 only a same-host caller can, and that caller is unauthenticated. See [step 7](#7-authentication-and-roles) |
| Build and ship | `sam build`, `sam deploy` | Cross-compile, `docker build`, push to ECR, `aws cloudformation deploy` |

Either target can serve a standalone rules service that outsiders call, and
you choose; they differ in how a caller authenticates. **On `AwsLambda`**, the
request that can carry a `role` is only reachable through an IAM-authenticated
call. **On `AwsFargate`**, from 2.8.0 the host honors that request only from
the same host, so an outside caller uses the session-cookie API (step 7);
before 2.8.0 it was reachable by anyone who could reach the hostname. The
Function URL that Lambda
generates cannot carry that request at all, since a Function URL always
wraps the HTTP body inside an event that the host treats as a web request
(a comment in `lambda.rb` next to `AuthType` explains this, and
`server.rs`, `dispatch_body` shows the branch).

That preference has a cost you should know about before you spend an
afternoon on it: neither generated stack has been taken from an empty
account to a working service by this procedure, and each has a problem
predicted from its own files. The Lambda stack's function may not be able to
read its database password at cold start (known gap 2). The Fargate stack
probably fails on its first image push (known gap 3), and before 2.8.0 it had
no authentication in front of the invoke path (step 7).

Status: the two generated templates were read and compared (verified here).
Nothing was invoked on either target (not verified here).

## 2. Define a bluebook

Make a directory that is **not** inside the clone, laid out the way
`hecks deploy project` looks for it: `<domain>/bluebook/<name>.bluebook`, and
`.hecksagon` and `.world` beside it, all sharing one basename.

```sh
export DOMAIN="$HOME/services/underwriting"
mkdir -p "$DOMAIN/bluebook"
```

`$DOMAIN/bluebook/underwriting.bluebook`, a domain with one aggregate, two
roles and one real rule (a loan above a limit cannot be approved):

```ruby
Hecks.bluebook "Underwriting" do
  vision "Decide whether a loan application may be approved."
  supporting

  aggregate "Application" do
    description "A loan application that is submitted and then approved or declined."

    identified_by :reference

    attribute :reference, Reference
    attribute :amount,    Money

    value_object "Reference" do
      attribute :value, String, pattern: '[^ \t\n\r]'
    end

    value_object "Money" do
      attribute :cents, Integer
      invariant("an amount is never negative") { cents >= 0 }
    end

    lifecycle :status, default: "pending" do
      transition "Approve" => "approved", from: "pending"
      transition "Decline" => "declined", from: "pending"
    end

    command "Submit" do
      role "Applicant"
      goal "Ask for a loan"

      attribute :reference, Reference
      attribute :amount,    Money

      emits "Submitted"
    end

    command "Approve" do
      role "Underwriter"
      goal "Approve an application within the lending limit"

      reference_to Application

      given("a loan above the limit is not approved") { amount.cents <= 5000000 }

      emits "Approved"
    end

    command "Decline" do
      role "Underwriter"
      goal "Decline an application"

      reference_to Application

      emits "Declined"
    end
  end
end
```

`$DOMAIN/bluebook/underwriting.hecksagon`, the wiring. `Governance` is
attached because the commands declare roles, and a domain that declares a
role with nothing to govern it is refused at boot. The aggregate is bound
to `Postgres`, one of the two adapters the host can serve (see the note
after the files):

```ruby
Hecks.hecksagon "Underwriting" do
  uses_framework "Governance"
  Underwriting::Application.persisted_by("Postgres")
end

Hecks.hecksagon "Governance" do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

`$DOMAIN/bluebook/underwriting.world`, the per-deployment values. The
`persisted_by` block is what the Ruby tools (`hecks docs`, `hecks run`) connect
to; the host ignores it and reads `DATABASE_URL` instead. `deployed_to` is
what `hecks deploy project` reads (step 3). This one selects Fargate because
that is the shape the local run in step 6 exercises; step 3 shows the
Lambda variant:

```ruby
Hecks.world "Underwriting" do
  realm "Guides"

  persisted_by("Postgres") do
    database "postgres://localhost/underwriting_local"
  end

  deployed_to("AwsFargate") do
    region "us-east-1"
    cpu 256
    memory 512
    port 8080
    database "Postgres"
  end
end
```

Things that went wrong while checking this, so they need not go wrong for
you:

- **An unbound aggregate refuses to boot.** Leaving `Application` out of
  the `.hecksagon` fails with `Underwriting::Application has no
  persisted_by bind. ... say Application.persisted_by("Memory") to keep it
  in memory on purpose.` Binding it to `Memory` is fine for the Ruby tools
  but the host cannot serve it: `SUPPORTED_PERSISTENCE_ADAPTERS` in
  `rust/host/src/ir.rs` is `Postgres` and `PostgresEra`, and the host
  refuses to boot a domain that binds any of your aggregates to anything
  else. (The Governance aggregates above are bound to `Memory` and the host
  booted fine; only the aggregates in your own domain's IR are checked.)
- **A world with no `database` cannot boot in Ruby.** `hecks run` fails with
  `its world declares no "database"` if the `persisted_by("Postgres")` block
  is missing.
- **The Rust rules reader does not take `_` in integer literals.** The
  first draft of the `given` above said `5_000_000`. The compiled host
  answered every `Approve` with a `Fault` refusal, `cannot resolve
  "5_000_000" -- no such attribute or argument`. Write `5000000`. How the
  Ruby runtime reads that spelling was not checked, so treat it as a possible
  Ruby/Rust divergence. Either way it shows why you should run the compiled
  host, not only the Ruby tools, before you trust a rule.
- **Two stores, not one.** The host reads and writes its own journal tables
  (`hecks_lambda_journal` and friends). Ruby's `Postgres` adapter writes
  `application` and other tables of its own. Running the same domain from
  Ruby against the same database does not show the host's records, and the
  reverse. The host is the source of truth for a deployed service.

Check that the declaration boots and read back what it says:

```sh
psql -h 127.0.0.1 -d postgres -c "CREATE DATABASE underwriting_local"
hecks docs "$DOMAIN/bluebook"
hecks run "$DOMAIN" --help
```

`hecks docs` prints each verb's arguments, who may issue it, and every
refusal it can produce. `hecks run <domain> --help` lists the verbs.

Status: all three files, the two boot errors and the `_` literal problem
are verified here. `hecks docs` and `hecks run --help` were run against them.
The refusal for a role with no governing chapter is quoted from the
comment in `lib/hecks/runtime/command_rules/authorization.rb` and was not
triggered here.

## 3. Project the deploy target

```sh
hecks deploy project "$DOMAIN" --out="$HOME/services/underwriting-deploy"
```

`hecks deploy project --help` prints the option list. The full usage
line is `hecks deploy project <domain> [--tenant=<slug>] [--schema=<name>]
[--out=<dir>] [--environment=<name>]`.

- `<domain>` is the directory from step 2. The script finds
  `<domain>/bluebook/<basename>.world`, or the single `*.world` file in that
  directory if the basename does not match.
- `--out=<dir>` says where to write. Without it the output goes to
  `deploy/<name>/` inside the clone (`<name>` is the `stack_name` setting if
  the `.world` has one, else the directory's basename). Prefer `--out` so the
  clone stays clean.
- `--environment=<name>` layers `<domain>/bluebook/environments/<name>.world`
  over the base `.world`. Use it to keep real stack names out of the base
  file. A missing overlay is an error, not a silent no-op.
- `--tenant=<slug>` generates a per-tenant stack of the same domain. You do
  not need it for a first service.

For the Fargate `.world` above the run printed:

```text
wrote .../template.yaml
wrote .../bastion.yaml
wrote .../Dockerfile
wrote .../Makefile

deploy from ... -- one command, nothing to type, nothing to remember:
    make deploy
```

The Lambda target writes `template.yaml`, `bastion.yaml`, `Makefile` and
`samconfig.toml` instead. To generate it, replace the `deployed_to` block
with:

```ruby
  deployed_to("AwsLambda") do
    region "us-east-1"
    memory 512
    timeout 10
    database "Postgres"
  end
```

What the generated stack creates in your account (read from the generated
`template.yaml`; billable resources are the ones to notice):

- A private VPC with subnets, and one RDS Postgres instance: `db.t4g.micro`,
  20 GB, encrypted, `PubliclyAccessible: false`, credentials generated into
  Secrets Manager, and `DeletionPolicy: Snapshot` (deleting the stack leaves
  a final snapshot behind).
- **Lambda:** one function named `hecks-<name>` with an IAM-authenticated
  Function URL, in subnets that have no route out of the VPC: no NAT
  gateway and no VPC endpoint (see known gap 2).
- **Fargate:** an ECR repository, an ECS cluster and service, an internet
  facing Application Load Balancer restricted to CloudFront's address range,
  a CloudFront distribution that forwards every method and never caches, a
  NAT gateway, a generated session secret in Secrets Manager, and a log
  group.

Notes on the output:

- The stack name is `hecks-<name>` (`stack_prefix` and `stack_name` in the
  `deployed_to` block change it).
- The generated Makefile hard-codes the absolute path of your clone and of
  `$DOMAIN`. Generate on the machine that will deploy, and regenerate if
  either path moves.
- `region` is required. Leaving it out fails with
  `... deployed_to("AwsLambda") is invalid: Region.value expects String, got nil`.
- Other settings: `database` takes `"Postgres"` (the default), `"Aurora"` or
  `"Shared"` (borrow another stack's instance, which also needs `owner`).
  `web` takes `"None"` or `"Rust"`; `"Rust"` turns on the public web UI and
  makes the Lambda Function URL public, which a rules service does not want.
  Fargate also takes `cpu`, `memory`, `port` and `desired_count`.

Status: verified here for both targets: the commands ran to completion, the
file lists, the `region` error, and the template contents quoted above were
read from the generated files. Nothing was deployed (not verified here).

## 4. Build the host

The generated Makefiles run these steps for you. Run them by hand first,
for the local target, to see each one work:

```sh
rustup target add wasm32-wasip1
hecks build_wasm "$DOMAIN"
(cd rust/host && cargo build --release --bin bootstrap)
```

- `hecks build_wasm "$DOMAIN"` regenerates Rust from your bluebook in a
  scratch copy under `tmp/`, compiles it to WebAssembly, and writes
  `rust/dist/underwriting.wasm` and `rust/dist/underwriting.ir.json`. The
  name comes from the directory's basename. Tracked files in the clone are
  left alone, and `rust/dist` is git-ignored.
- `cargo build --release --bin bootstrap` builds the host into
  `rust/host/target/release/bootstrap`. The binary is called `bootstrap`
  because that is the name the Lambda custom runtime requires; it is the
  same binary for both targets.

On the machine used here the wasm build took under a minute and a cold host
build took several minutes (dependencies include wasmtime and the AWS SDK).
A rebuild after changing only the bluebook needs `hecks build_wasm` again and
not the host build.

The deploy Makefile does the equivalent for the cloud. For Fargate its
`build` target cross-compiles the host for `aarch64-unknown-linux-gnu`,
copies `underwriting-host`, `underwriting.wasm` and `underwriting.ir.json`
next to the Dockerfile, and `docker-build` bakes them into a
`debian:bookworm-slim` image.

Status: `hecks build_wasm` and the native host build are verified here. So
is the Fargate `build` target: `make build` in the generated directory ran to
completion and left `underwriting-host` (an arm64 Linux binary),
`underwriting.wasm` and `underwriting.ir.json` beside the Dockerfile, and
`docker build --platform linux/arm64` on that directory produced an image
(deleted afterwards). The container was not started, and pushing it was not
attempted. Every Lambda build step (`sam build`, `cargo lambda`) is not
verified here.

## 5. Configure the environment

The host is configured only through environment variables. A wrong or
missing one fails at boot with a message that names it, or, for the session
secret, at the first request that needs it.

**Required to boot**

| Variable | What it is |
| --- | --- |
| `HECKS_DOMAIN` | The domain's declared name, exactly as in `Hecks.bluebook "Underwriting"` (case matters). Not the directory name. |
| `HECKS_IR_PATH` | Path to `<name>.ir.json` from step 4. |
| `HECKS_WASM_PATH` | Path to `<name>.wasm` from step 4. It defaults to `banking.wasm`, a demo name: always set it. |
| `DATABASE_URL` | `postgres://user:password@host:port/dbname`. Or, instead, `DB_SECRET_ARN` (a Secrets Manager secret holding `{"password": ...}`) with `DB_HOST` and `DB_NAME`; the generated stacks use this form. |

**Serving**

| Variable | What it is |
| --- | --- |
| `HECKS_SERVE_MODE` | `1` runs the HTTP server. Unset, the binary runs as a Lambda custom runtime and waits for a Runtime API that does not exist outside AWS. |
| `PORT` | Listen port on `0.0.0.0`. Default 8080. |
| `HECKS_SCHEMA` | Optional. If set, the host creates that Postgres schema if needed and sets `search_path` to it, so several domains can share one database. |
| `HECKS_BUILD` | Optional. Reported by `GET /version`; defaults to the crate version. |

**Authentication (step 7)**

| Variable | What it is |
| --- | --- |
| `SESSION_SECRET` | The HMAC key for the `session` cookie and for the account cookie. Required for any request the host treats as a web request (see step 7); such a request panics without it. Or `SESSION_SECRET_ARN`, a secret holding `{"session_secret": ...}`, which the host reads at boot and copies into `SESSION_SECRET`. |
| `HECKS_SESSION_COOKIE` | Name of the account cookie. Default `hecks_session`. Letters, digits, `_`, `-` and `.` only, or the host refuses to boot. |
| `HECKS_ROLE_ENFORCEMENT` | What the host does about the role a command declares, for a request on the internal protocol (`POST /dispatch` from a peer on this host). `off` (default): a request that states no role is unchecked. `shadow`: an unidentified request is dispatched as role `Anonymous`; if that would be refused it is logged as `would_refuse_role` and let through, while a request that states a role is checked as under `off` (a wrong role is still refused, and logged). `enforce`: an unidentified request is refused. The host's own dispatches (signups, newsletter, registrations, presentation saves, provisioning) name no caller and are never subject to this setting. A request may carry `actor_id` instead of a role: the command's role must then be assigned to that actor in Governance. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`, `SITE_URL` | Google sign-in. Or `GOOGLE_OAUTH_SECRET_ID`, a secret holding `{"client_id": ..., "client_secret": ...}`. Not usable by itself; see step 7. |

`HECKS_CHECKOUT_DOMAIN`, `RESEND_SECRET_ID` and `PAYMENTS_ACCOUNT_SECRET_ID`
switch on registration, email and payment routes that are outside the scope
of a rules service. Leave them unset.

Things the code does that are worth knowing:

- **The database host decides TLS.** A host of `localhost`, `127.0.0.1` or
  `::1` connects without TLS. Any other host requires TLS and trusts only
  the AWS RDS certificate bundle compiled into the binary
  (`rust/host/rds-ca-bundle.pem`). So the host is built for RDS and for
  loopback. A remote Postgres from another provider would need its
  certificate authority added and the host rebuilt; that was not tried.
- **A Unix socket is not supported.** Only TCP hosts are recognised, so a
  Postgres that listens only on a socket path will not do; use `localhost`.
- **The era system stays off for plain `Postgres`.** The host only mints and
  checks eras when your IR lists lineage-capable aggregates (aggregates
  bound to `PostgresEra`) or when `GOOGLE_CLIENT_ID` is set. With every
  aggregate on `Postgres`, as above, none of that runs at boot. `PostgresEra`
  needs an ordinary, non-superuser database role and a translation step when
  the shape changes; it is outside this document.
- **The task definition also sets `HECKS_ERA`.** The host no longer reads it.

Boot errors seen here, verbatim:

```text
Error: "either DB_SECRET_ARN (+ DB_HOST/DB_NAME) or DATABASE_URL is required"
Error: "HECKS_DOMAIN is required"
Error: "HECKS_IR_PATH is not set or unreadable -- this binary needs its own domain's ir.json sidecar"
```

Status: the variables and the three boot errors were verified here by
running the binary. The `DB_SECRET_ARN`, `SESSION_SECRET_ARN`,
`GOOGLE_OAUTH_SECRET_ID` and TLS-to-RDS paths are read from `main.rs` and
were not run (not verified here). The `HECKS_SERVE_MODE`-unset behaviour is
read from the comment in `main.rs` and was not run.

## 6. Run it locally

The database `underwriting_local` was created in step 2. Start the host from
the clone's root:

```sh
export SESSION_SECRET="$(openssl rand -hex 32)"
HECKS_SERVE_MODE=1 PORT=8080 HECKS_DOMAIN=Underwriting \
DATABASE_URL=postgres://localhost/underwriting_local \
HECKS_WASM_PATH="$PWD/rust/dist/underwriting.wasm" \
HECKS_IR_PATH="$PWD/rust/dist/underwriting.ir.json" \
rust/host/target/release/bootstrap
```

The host logs one JSON object per line to stdout. A healthy boot looks like:

```text
{"level":"info","msg":"boot_phase","phase":"db_connect","event":"start","tls":false}
{"level":"info","msg":"boot_phase","phase":"ensure_schema","event":"end","elapsed_ms":15}
{"level":"info","msg":"boot","mode":"serve","domain":"Underwriting","era":"df0271","boot_ms":203}
{"level":"info","msg":"boot_phase","phase":"serve_start","event":"start","port":8080}
```

On a first boot the host creates its own tables (`hecks_lambda_journal`,
`hecks_lambda_snapshot`, `hecks_lambda_sagas`, `hecks_outbox` and others) in
the database. Nothing else needs to be set up.

In a second terminal:

```sh
curl -i http://127.0.0.1:8080/
curl http://127.0.0.1:8080/version
```

The first answers `200` with an empty body. It is the load balancer's
health check and touches neither the database nor the rules. The second
answers `{"era":"df0271","ir_hash":"df0271f2...","build":"0.1.0"}`. Neither
needs credentials.

Now dispatch a command. The path can be anything except `/`, which only
accepts `GET`; a `POST /` answers `405`:

```sh
curl -s -X POST http://127.0.0.1:8080/invoke \
  -d '{"verb":"Underwriting::Application.Submit",
       "with":{"reference":{"value":"A-1"},"amount":{"cents":9000000}},
       "role":"Applicant"}'
```

The answer is the kernel's outcome, abbreviated here:

```text
{"instances":{"Underwriting::Application#A-1":{"reference":{"value":"A-1"},
  "amount":{"cents":9000000},"status":"pending"}},
 "events":[{"name":"Submitted","aggregate":"Underwriting::Application","id":"A-1", ...}],
 "refusals":[], ...}
```

Now the rules. Approve it as an underwriter. The amount is above the limit,
so the domain says no. The HTTP status is still `200`: a refusal is an
answer, and it is in `refusals`:

```sh
curl -s -X POST http://127.0.0.1:8080/invoke \
  -d '{"verb":"Underwriting::Application.Approve","to":"A-1","with":{},"role":"Underwriter"}'
```

```text
"refusals":[{"verb":"Underwriting::Application.Approve",
  "error":"Approve refused -- a loan above the limit is not approved","kind":"GivenNotMet"}]
```

Submit a smaller one and approve it, then try to decline what is already
approved:

```sh
curl -s -X POST http://127.0.0.1:8080/invoke \
  -d '{"verb":"Underwriting::Application.Submit","with":{"reference":{"value":"A-2"},"amount":{"cents":250000}},"role":"Applicant"}'
curl -s -X POST http://127.0.0.1:8080/invoke \
  -d '{"verb":"Underwriting::Application.Approve","to":"A-2","with":{},"role":"Underwriter"}'
curl -s -X POST http://127.0.0.1:8080/invoke \
  -d '{"verb":"Underwriting::Application.Decline","to":"A-2","with":{},"role":"Underwriter"}'
```

The second returns `"events":[{"name":"Approved", ...}]` and status
`approved`; the third is refused with `kind` `LifecycleRefused`: `Decline
refused -- status is "approved", and Decline moves it only from "pending"`.

Read all current state:

```sh
curl -s -X POST http://127.0.0.1:8080/invoke -d '{"read":true}'
```

State is durable. Stopping the host and starting it again with the same
`DATABASE_URL` returned the same records, because the host replays the
journal on each request.

Status: verified here, every command above, against a scratch database that
was dropped afterwards. The checks set the same variables with `env` rather
than `export`, and used a different port. The response text is trimmed for
space.

## 7. Authentication and roles

Read this whole section before you expose the service. There are three
separate ways in, they are protected differently, and the one a rules
service is mostly called through is the least protected by the host itself.

| Surface | What it looks like | What the host checks |
| --- | --- | --- |
| **Invoke** | `POST` a JSON body containing `verb` or `read` to any path except `/` | **No credential.** `role` is read from the body and compared as a string to the command's declared role. From 2.8.0 the host honors this shape only from a peer on the same host; a body from any other peer is an ordinary web request (7.1). |
| **Session-cookie API** | `GET`/`POST` `/api/...` and `/<Domain>/<Aggregate>...` | A `session` cookie signed with `SESSION_SECRET`. |
| **Account cookie** | `/accounts/me`, `/members`, `/auth/google...` | An account cookie (`hecks_session`) signed with `SESSION_SECRET`, and a membership chapter that this repository does not ship. |

### 7.1 The invoke path takes its role from the request body

`rust/host/src/server.rs`, `dispatch_body`, line 102:

```rust
let role = body.get("role").and_then(|v| v.as_str()).map(|s| s.to_string());
```

and nothing verifies it. ADR 0072 records this as the same self-asserted
identity gap as the MCP door's, to be settled together with a real token.
What was observed here:

- **A caller with no `role` is not checked at all.** `Approve` with no
  `role` key was accepted and the record became `approved`. A role-gated
  command with no caller role is simply unchecked.
- **A caller that names the wrong role is refused**, with `kind`
  `Unauthorized`: `Approve refused -- role: Underwriter, and the caller
  stated Applicant`.
- **A caller that names the right role is accepted**, whoever they are.
- **`actor_id` in the body is ignored.** The host never passes an actor to
  the kernel. An `actor_id` naming a person with no grants, sent with the
  `Underwriter` role, approved an application.
- **Governance grants are not consulted.** The host never asks whether the
  caller holds the role. On the Ruby runtime an identified caller is checked
  against live `RoleAssignment` records; on this path there is no identified
  caller, so the check is the plain string comparison above.

So on the invoke path a `role` is a label the caller writes, not a proof.
The only thing standing between an outsider and your rules is whether they
can reach the endpoint at all:

- **On Lambda**, the invoke shape can only arrive through the Lambda Invoke
  API, which requires AWS credentials and an IAM permission
  (`lambda:InvokeFunction` on the function). Access control is IAM policy:
  who may invoke, not what role they claim.
- **On Fargate, before 2.8.0**, the raw invoke shape was reachable by anyone
  who could send an HTTP request to the CloudFront hostname. The Application
  Load Balancer accepts only CloudFront's address range, but the CloudFront
  distribution itself is open and forwards every method, and the host read
  any body containing `verb` or `read` as a command from any peer. The
  generated stack added no authentication in front of the invoke path.
- **On Fargate, from 2.8.0**, the host reads a body as the invoke shape only
  when the peer is on the same host (`127.0.0.1`, `::1`, or an IPv4-mapped
  loopback), which is how a sidecar in the same task reaches it. From any
  other peer, including everything the load balancer forwards, the same body
  is an ordinary request for the path it hit, answered by the web layer's own
  routes and gate. This is covered by unit tests and was run against a local
  host; it has not been verified on a deployed stack, so after moving a
  stack to 2.8.0 send one `POST` of `{"verb":"NoSuchVerb"}` to a path the
  load balancer forwards and confirm it no longer answers with a verb error
  (do not use `{"read":true}` on a live service, which returns data). A same-host
  caller still names its own role, so the sidecar case remains self-asserted.
  Which target you deploy is your choice, and the projection for each is
  generated. What differs is how an outside client calls it: on Lambda, through
  the IAM-signed Invoke API; on Fargate, through the session-cookie API (7.2),
  because from 2.8.0 the invoke shape is same-host only.
  Do not deploy a Fargate host older than 2.8.0 for a service whose rules
  matter without your own access control in front of it (a WAF rule, an
  authenticating proxy, or a private network).

### 7.2 The `session` cookie, and how an operator gets one

The routes under `/api/` and `/<Domain>/<Aggregate>` require a cookie named
`session`. Without it, an API-shaped path answers `401` with
`{"error":"Unauthenticated","message":"sign in first"}` and a page path
redirects to `/login`.

The cookie is `<payload>.<signature>`:

- `<payload>` is base64url without padding (alphabet `A-Z a-z 0-9 - _`) of a
  JSON object with the four fields `identity_id`, `email`, `name`, `role`.
- `<signature>` is the lowercase hex HMAC-SHA256 of the `<payload>` string,
  keyed with `SESSION_SECRET`.

The host verifies the signature and nothing else. There is no expiry field;
a cookie stays valid until the secret changes.

**Nothing in the host ever issues this cookie.** `session_cookie` in
`rust/host/src/auth.rs` is called only from tests, and the Google sign-in
callback sets the account cookie instead. So the only way to hold a valid
`session` cookie today is to mint one yourself with the secret. That makes
the secret an operator credential: whoever has it can act as anyone.
Guard it the way you would guard a root password, and change it to
invalidate every cookie.

Minting one needs only `openssl`, so a non-Ruby operator can do it:

```sh
payload=$(printf '%s' '{"identity_id":"ops-1","email":"ops@example.com","name":"Ops","role":"Admin"}' \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=')
sig=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$SESSION_SECRET" -hex | sed 's/^.* //')
COOKIE="session=$payload.$sig"
```

The `role` in a session is not compared with any command's role. A session
whose role was `Admin` approved an `Underwriter` command through `/api`,
because those routes dispatch with no caller role. The session decides
whether you may use the surface at all, and nothing more.

A tampered cookie answers `401`.

### 7.3 Google sign-in and the first administrator

The host has a Google sign-in flow (`/auth/google` and its callback). It is
not usable from this repository alone, for three reasons.

1. **It needs a membership chapter that is not shipped.** The flow resolves
   who may sign in through a chapter that declares `provides "membership"`,
   and one that declares `provides "identity"` (the shipped `Identity`
   framework chapter fits) and `provides "authorization"` (Governance).
   Nothing in this repository declares `provides "membership"`; the gem's
   framework chapters are Compliance, ConsoleSettings, Governance, Identity
   and Privacy. Without one, `/accounts/me` and `/members` answer `500` with
   `this domain attaches no chapter that provides "membership" -- cannot
   resolve who may sign in`. You would have to write that chapter yourself.
2. **It signs in to the wrong cookie for the JSON API.** A successful
   sign-in mints the account cookie (`hecks_session`) and redirects to
   `/admin.html`. The `/api/` routes read the `session` cookie, not that
   one. Sending an account cookie to `/api/me` answers `401`.
3. **The first administrator cannot be created through the host.**
   `/members` and the grant routes require the caller to already be an
   active `Admin` or `Owner` in the membership records. A comment in
   `auth.rs` points at a `bin/grant_first_admin` script, but no such script
   exists in `bin/`. The first membership row has to be written some other
   way; the comments in `auth.rs` say membership lives in the era-managed
   head tables and is written by the Ruby runtime, so the likely route is
   the Ruby runtime dispatching the membership chapter's `Admit` and
   `GrantAccess` against the same database. That was not tried.

The Governance part of the first-administrator question is settled by ADR
0025: an identified caller (one that binds an `actor_id`) dispatching
`Governance::RoleAssignment.Assign` must already hold a live `Governance
administrator` assignment, so the very first grant has to come from a caller
that binds no `actor_id` and is checked by string comparison. It is a
bootstrap step, not a hole. On the host that first grant is the invoke path
naming the role, sent from the same host: from 2.8.0 the host ignores that
shape from any other peer, so on a deployed service run it from inside the
task or container, not from outside. The run below is against a local host,
which is the same-host case. Verified here:

```sh
curl -s -X POST http://127.0.0.1:8080/invoke -d '{"verb":"Governance::RoleAssignment.Assign",
  "with":{"actor_id":{"value":"alice"},"role_name":{"value":"Underwriter"},
          "scope":{"value":"Underwriting"},"starts_at":{"value":"2026-09-27T00:00:00Z"}},
  "role":"Governance administrator"}'
```

answered with a `RoleAssigned` event; the same call with `"role":"Underwriter"`
was refused, `Assign refused -- role: Governance administrator, and the
caller stated Underwriter`. The grant is recorded, and the host never
consults it (7.1). It matters only to a Ruby caller that binds an
`actor_id`.

### 7.4 A workable recipe for the first service

1. Deploy the **Lambda** target, after reading known gap 2.
2. Give each calling system an IAM identity that may `lambda:InvokeFunction`
   on `hecks-<name>` and nothing else. That is your authentication.
3. Use `role` in the payload as a routing label that keeps a well-behaved
   caller inside its own commands, and do not rely on it against a hostile
   one.
4. Keep `SESSION_SECRET` for operator use with the `/api/` routes if you want
   them, and mint operator cookies as in 7.2.

Status: everything in 7.1 and 7.2 was verified here by running the host and
`curl` (including the minted cookie, the tampered-cookie `401`, and the
account-cookie `401` on `/api/me`). The Google flow itself (the redirect, the
token exchange, the ID-token check) was **not** run: it needs a Google
client and a membership chapter. Its behaviour is read from `auth.rs` and
`web.rs`. That the generated Lambda stack is IAM-only is read from the
template's `AuthType: AWS_IAM`; the Fargate exposure is read from the
template and from the local run of the same handler, and neither was tested
deployed.

## 8. Call it from a non-Ruby client

Everything here is plain HTTP and JSON. Examples use `curl`.

### The invoke API

Where it can be called from depends on the target you chose (both projections
are generated). On Lambda, an outside client uses the IAM-signed Invoke API
below. On Fargate, from 2.8.0, this shape works only from the same host (a
sidecar, or a shell inside the task), because the host does not act on it from
any other peer (7.1); an outside client of a Fargate service uses the
session-cookie API instead. The `curl` examples in this step that target
`127.0.0.1` are the same-host case.

`POST` to any path except `/`, body a JSON object:

| Body | Meaning |
| --- | --- |
| `{"read": true}` | The whole current state: `instances`, keyed `"<Domain>::<Aggregate>#<id>"`. |
| `{"verb": "<Domain>::<Aggregate>.<Command>", "with": {...}, "role": "..."}` | A command that creates a record. `with` holds the command's facts, in the same shape `hecks docs` prints (value objects as `{"value": ...}` objects). |
| `{"verb": "...", "to": "<id>", "with": {...}, "role": "..."}` | A command on an existing record; `to` is its id. |
| `{"verb": "...", "args": {...}}` | The older shape, still accepted. Combining it with `to` or `with` answers `500` with `{"error":"cannot combine to/with with legacy args"}`. |

`role` is optional (7.1). The response is always the kernel's outcome
document, with these keys that matter to a client:

| Key | Meaning |
| --- | --- |
| `refusals` | Empty when the command was accepted. Each entry has `verb`, `error` (text) and `kind`: `GivenNotMet`, `Unauthorized`, `LifecycleRefused`, `TypeMismatch` (also used for an unknown command), `Fault`, and others. |
| `events` | The events this call produced, each with `name`, `aggregate`, `id`, `payload`, `occurred_at`. |
| `instances` | The full state of every record after the call. |

Status codes on this path: `200` for every outcome, refused or not, so a
client must inspect `refusals`; `400` with plain text `invalid JSON body:
...` for a body that is not JSON; `500` with `{"error": "..."}` when the
host itself fails (a bad combination of keys, a database error). A JSON
body that has neither `verb` nor `read` is not an invoke: the host treats it
as a web request and answers `302` to `/login` (or `401` for an `/api/`
path). An unknown verb is a `200` with a `TypeMismatch` refusal.

Status: verified here.

### The session-cookie API

With a `session` cookie (7.2) in `$COOKIE`:

| Request | Answer |
| --- | --- |
| `GET /api/me` | The session's own fields. |
| `GET /api/schema` | Each aggregate, its lifecycle states and queries. |
| `GET /api/<collection>` | Every record as a JSON array, each with an `id`. The collection key is the aggregate name, snake-cased and pluralised: `applications`. |
| `GET /api/<collection>?query=<Name>&<arg>=<value>` | The rows of a named query the aggregate declares. |
| `GET /api/<collection>/<id>` | One record. |
| `POST /api/<collection>` | The aggregate's creating command; the JSON body is its facts. Answers `200` with the record. |
| `POST /api/<collection>/<id>/<command>` | A command on a record; `<command>` is the snake-cased command name (`approve`). Body is the facts, `{}` for none. |

```sh
curl -s -H "Cookie: $COOKIE" http://127.0.0.1:8080/api/applications/A-2
curl -s -X POST -H "Cookie: $COOKIE" http://127.0.0.1:8080/api/applications \
  -d '{"reference":{"value":"A-3"},"amount":{"cents":100000}}'
curl -s -X POST -H "Cookie: $COOKIE" http://127.0.0.1:8080/api/applications/A-3/approve -d '{}'
```

Errors here use HTTP status: `401` `{"error":"Unauthenticated", ...}`; `404`
`{"error":"NotFound","message":"no Application found for id \"ZZ\""}` or
`no such collection: nope`; `422` for a domain refusal, with the refusal
class as `error`:
`{"error":"GivenNotMet","message":"Approve refused -- a loan above the limit is not approved"}`;
`400` `MalformedBody` for a body that is not a JSON object. No `role` is sent
and none is checked on these routes (7.2).

`GET /<Domain>/<Aggregate>.json` and `GET /<Domain>/<Aggregate>/<id>.json`
also answer, with pretty-printed JSON. **Commands cannot be posted to
`/<Domain>/<Aggregate>/<Command>.json` from a plain client:** the host parses
every request body as JSON before it routes, and that route reads
form-encoded fields, so `reference.value=A-4&amount.cents=5000` is rejected
with `400 invalid JSON body`. Use `/api/`.

Status: verified here for `/api/me`, `/api/schema`, both `GET` forms, both
`POST` forms, and the error answers listed. The `?query=` form is read from
`api.rs` and was not run (this domain declares no queries), and so are
`/api/ui-schema` and `/api/presentation`; those two serve a console UI and
depend on optional console-settings data.

### Calling a deployed Lambda from a non-Ruby client

The invoke payload is the same JSON as above, sent to the Lambda Invoke API
with AWS credentials. With the AWS CLI:

```sh
aws lambda invoke --function-name hecks-underwriting --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"read":true}' out.json && cat out.json
```

With any AWS SDK, or with `curl` 7.75 or later signing the request itself:

```sh
curl --aws-sigv4 "aws:amz:us-east-1:lambda" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  -H "x-amz-security-token: $AWS_SESSION_TOKEN" \
  -X POST --data '{"read":true}' \
  https://lambda.us-east-1.amazonaws.com/2015-03-31/functions/hecks-underwriting/invocations
```

Status: not verified here. It is derived from the generated template (the
function is named `hecks-<name>`), the host's handler (the payload is passed
straight to the handler as JSON, `main.rs`) and AWS's documented Invoke API.

## 9. Deploy to your own account

Set your region and credentials first. The Makefiles pass `--region` to some
`aws` calls and not to others (the `mint-era` recipe describes the stack
without it), so also export `AWS_REGION` to the same region the `.world`
names.

### Lambda

```sh
cd "$HOME/services/underwriting-deploy"      # the --out directory from step 3
make deploy
```

In order, from the generated Makefile: `sam build` (which calls
`cargo lambda` to cross-compile the host for arm64), a parity check of the
compiled rules against a corpus if you wrote one (it skips itself with a
message if `spec/corpus/<name>.json` does not exist), `sam deploy` (creates
the stack), then `make mint-era`. `mint-era` stands up a temporary bastion
stack, opens an SSM tunnel to the new database, runs one Ruby boot against it
and tears the bastion down.

### Fargate

```sh
cd "$HOME/services/underwriting-deploy"
make deploy
```

In order: `build` (cross-compile, described in step 4), `docker-build`,
`ecr-login` and `docker-push`, `aws cloudformation deploy`, then `make
mint-era`.

### After it deploys

- The stack's `Outputs` list the addresses and identifiers:
  `aws cloudformation describe-stacks --stack-name hecks-underwriting
  --query "Stacks[0].Outputs"`. Lambda reports `FunctionUrl`; Fargate reports
  `ServiceUrl` (the load balancer) and `CloudFrontDomain`.
- On Fargate, `GET https://<CloudFrontDomain>/version` should answer with the
  era, IR hash and build, the same document as locally.
- To mint operator cookies against the deployed Fargate service, read the
  generated session secret from Secrets Manager (a JSON object with a
  `session_secret` key) and follow 7.2.
- To remove everything, delete the stack. The database is left behind as a
  final snapshot (`DeletionPolicy: Snapshot`); delete that too if you want no
  residue. A non-empty ECR repository may block stack deletion.

Status: **not verified here, any of it.** No `make deploy` was run, on either
target, and no `aws`, `sam` or `docker push` command was run. It is derived
from the generated Makefiles and templates. Read [known gaps](#known-gaps)
before running it, in particular gaps 2, 3 and 5.

## Known gaps

What stands between this procedure and the ADR 0071 exit test, in the order
an outside team would meet it.

1. **The path starts from a clone.** ADR 0066 decides that the gem ships a
   `hecks` executable and that dev tooling stays in the repository; until
   that is built, `hecks deploy project` and `hecks build_wasm` need a checkout.
   A clone also brings the whole Rust tree and its build time.
2. **The self-contained Lambda function may not be able to read its
   database password.** `main.rs` fetches the password from Secrets Manager
   at cold start, over the AWS SDK. The generated Lambda template puts the
   function in subnets with no route out of the VPC, and defines no NAT
   gateway and no VPC endpoint for Secrets Manager. Unless something else
   makes Secrets Manager reachable from those subnets, the cold start would
   time out. The comment at the top of the template says the function needs
   no outbound access at all, which the password fetch contradicts. Not
   verified here. A fix, also not verified: add an interface VPC endpoint for
   Secrets Manager to the template by hand (re-running `hecks deploy project`
   into the same directory overwrites hand edits). The Fargate template has a
   NAT gateway and does not have this problem.
3. **Fargate's first deploy is likely to fail at the image push.** The
   Makefile's `deploy` target builds and pushes the image to the ECR
   repository before it runs `aws cloudformation deploy`, and the
   repository is created by that stack. ECR does not create a repository on
   push. Not verified here. A workaround, also not verified: generate with
   `desired_count 0` in the `deployed_to` block (verified to produce
   `DesiredCount: 0`), run `aws cloudformation deploy` by hand first so the
   repository exists, push, then set `desired_count 1` and deploy again. The
   Lambda target does not have this ordering problem.
4. **Fargate exposed the invoke path with no credential before 2.8.0**
   (7.1). Fixed from 2.8.0, not yet verified on a deployed stack; on an older
   host it is still open, and Lambda avoids it (once gap 2 is dealt with).
5. **`make deploy` ends in `mint-era`, which is written for era-managed
   domains.** The recipe's Ruby command was run by hand (not through `make`,
   and without the tunnel) against a scratch database, for a domain with a
   plain `Postgres` binding. It got as far as PostgresEra's era write-fence
   check and refused because the local role was a superuser; an ordinary role
   is required. On RDS the master user's behaviour was not tried, and whether a
   plain `Postgres` domain needs the step at all was not established: the
   host itself does not (step 5). If `mint-era` fails after the stack is
   created, the stack is already up; the step is a separate target
   (`make mint-era`).
6. **No shipped way to sign in interactively** (7.3): no membership chapter,
   no first administrator, and the account cookie does not open `/api/`.
7. **Roles on the invoke path are self-asserted** (7.1), and `actor_id` is
   ignored. Closing this is deferred to ADR 0072's token work.
8. **`_` in integer literals** fails in the host (step 2), and whether Ruby
   accepts it was not checked. Run the compiled host against your rules
   before deploying, not only `hecks run`.
9. **The Ruby tools and the host keep separate stores** (step 2), so
   `hecks run` against your database does not show what the service holds.
10. **`/<Domain>/<Aggregate>/<Command>.json` cannot be posted to from a plain
    client** (step 8).
11. **The host's comments and its behaviour disagree in two places.**
    `server.rs` describes `POST /` as reaching dispatch; it answers `405`.
    A web-shaped request with no `SESSION_SECRET` set panics the request task
    instead of returning an error (the connection closes with no response;
    `curl` reports an empty reply, exit 52), though the server stays up.

## What was checked, and how

Commit `512f9c43`, macOS on arm64, Ruby 3.3, Rust 1.98.0, PostgreSQL 14
reached over TCP on `localhost`. All database work used scratch databases
created for the check and dropped afterwards. No cloud account was touched:
no `aws`, `sam` or `docker push` command was run.

| Step | Checked | How |
| --- | --- | --- |
| 2. Bluebook files | Yes | `hecks docs`, `hecks run --help`; two boot errors reproduced |
| 3. `hecks deploy project` | Yes, both targets | Run to completion into a scratch `--out`; generated files read; `--help`, missing-world and missing-region errors reproduced; `desired_count 0` regenerated |
| 4. `hecks build_wasm`, host build | Yes | Run; binary started |
| 4. Fargate `build` recipe and image | Yes | `make build` to completion, then `docker build --platform linux/arm64` on the output directory; container not started, nothing pushed |
| 5. Environment variables | Partly | Three boot errors reproduced; secret-manager, TLS and Lambda-mode paths read from code only |
| 6. Local run | Yes | Every `curl` in step 6 |
| 7.1 Roles on invoke | Yes | Right, wrong, absent role; `actor_id`; Governance grant |
| 7.2 Session cookie | Yes | Minted with `openssl`; used against `/api/`; tampered cookie refused |
| 7.3 Google flow, first admin | No | Read from code; no Google client, no membership chapter |
| 8. Invoke and `/api/` | Yes | `curl`; `?query=` and console routes not run |
| 8. Lambda invoke from `curl` | No | Derived |
| 9. All deploy commands | No | Derived from generated files |

Related: [the decision this serves and its open questions](wayfinder/review-followup/tickets/10-adoption-wedge.md),
[the rehydrate-and-replay host](implemented/decisions/0018-rehydrate-replay-lambda-host.md),
[the Fargate serve mode](implemented/decisions/0060-fargate-serve-mode-keeps-the-single-mutex-guarded-connection.md),
[the role and Governance rule](decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md),
and [the MCP authentication ADR](decisions/0062-mcp-servers-need-real-authentication-before-any-network-transport.md).
