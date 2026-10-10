# Wiring

A domain that boots in memory and refuses correctly —
[getting-started.md](getting-started.md) or [commands.md](commands.md) covers that ground. That domain does
not yet know where its records will actually live when someone other
than the developer is running it, and it should not: a bluebook that named its
own database would be a bluebook that lied the day the provider changed.
This page is where that knowledge lives instead — the
`.hecksagon` and the `.world` — and it is where the decisions
a shipped feature cannot leave unmade get made: which adapter holds each
aggregate, what an outside fact has to look like before this domain
will listen to it, and which values differ from one deployment to the
next. The domain says WHAT: the wiring says
WHERE, and neither file is allowed to say the other's part.

## The folder convention

A domain's own `bluebook/` folder holds exactly three files with three
different jobs — `.bluebook` (what the domain IS), `.hecksagon` (how
THIS deployment wires it), `.world` (what values THIS deployment
uses) — and nothing else:

```ruby skip
examples/pizzas/
  bluebook/
    pizzas.bluebook        the domain
    pizzas.hecksagon       the wiring
    pizzas.world           the per-deployment values
  data/
```

Ports and adapters ship with the library instead, beside their own
implementation, never inside a domain's folder:

```ruby skip
lib/hecks/ports/            the PORT — the how-verb and the signal
lib/hecks/adapters/driven/
  sqlite.adapter                 the DECLARATION
  sqlite.rb                      the IMPLEMENTATION
  memory.* heki.* postgres.* folder.* prism.*
```

A project bringing its own port or adapter puts them in a `ports/` or
`adapters/` folder above its domains, found by walking up — the
library's own load runs first, so a project's can only add, never
replace.

Everything below is what actually goes inside the second and third of
those three files.

## The declaration

This page wires `examples/pizzas/bluebook/pizzas.bluebook` — the same
domain [getting-started.md](getting-started.md) declares in full and
[commands.md](commands.md) exercises command by command, not repeated
here. Two pieces of it matter for what follows: the aggregate's own
name, and the policy sitting beside it that a driving port below ends
up triggering.

```ruby skip
aggregate "Order" do
  identified_by :name
  # ...
end

# A PAYMENT ARRIVING IS AN EXTERNAL FACT, NOT A DECISION THIS DOMAIN MAKES —
# the business rules stay on Purchase itself, reached only through this.
policy "OnPizzaPaymentReceived" do
  on "PizzaPaymentReceived"
  trigger Order::Purchase
end
```

Nothing in that file says Postgres, Memory, or anything else that
could answer `persisted_by`. That absence is not an oversight — it is
the entire reason a `.hecksagon` exists.

## Wiring it

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))

Hecks.hecksagon("Pizzas") do
  attaches "Governance"
  Pizzas::Order.persisted_by("Memory")

  # An event this hecksagon takes from OUTSIDE Pizzas' own bluebook —
  # see "subscribe", below.
  subscribe "IngredientShipmentReceived"

  # THE DRIVING PORT — called by a payment processor's webhook, never by
  # the domain itself. This is pizzas.hecksagon's own real
  # PaymentGateway/Receive (examples/pizzas/bluebook/pizzas.hecksagon),
  # reproduced here so this page can wire it against Memory rather than
  # the Postgres binding that file actually ships with.
  Pizzas::Order.port "PaymentGateway" do
    operation "Receive" do
      attribute :name, Hecks::Bluebook::Reference.new("Order")
      attribute :customer_name, CustomerName
      attribute :amount, Price
      emits "PizzaPaymentReceived"
    end
  end
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby boot
Hecks.world("Pizzas") do
  realm "Examples"
  persisted_by("Memory")
end
```

Two files, three jobs done in them: `persisted_by` binds an aggregate
to an adapter; `port`/`operation` declares a boundary the domain will
listen through; `subscribe` names an event taken from elsewhere.
`.world` supplies the values a binding actually needs. Each one is walked through
separately below, live, against what just booted.

## Binding persistence, decided outside the domain

`persisted_by` is the whole syntax: an aggregate, a string naming an
adapter. Swap the string and the domain never learns — there is no
hook, no callback, nothing in `Pizzas::Order`'s own declaration
that could even ask which adapter answered:

```ruby
order = Order.create_pizza!(name: { value: "Margherita" },
                            pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.status   # => "available"

order.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
order.toppings.map(&:to_h)   # => [{ name: "Basil", amount: 3 }]
```

This page binds `Order` to Memory above because that is what it needs
to run without a database behind it. The exact same shape, unchanged,
already ships against a real one: `pizzas.hecksagon` itself binds
`Order` with `Pizzas::Order.persisted_by("PostgresEra")`, one line —
quoted here, not run, since this page does not require a database:

```ruby skip
Pizzas::Order.persisted_by("PostgresEra")
```

That is what "decided outside the domain" means in practice, not in
theory — a real file in this repository proves it.

## Driving ports

A `port` declared in the hecksagon is a second entry point, for facts
that did not originate inside this domain at all — a payment
processor's webhook confirming a charge, not a chef ringing one up on
the menu. Read the inventory off `PaymentGateway`'s `Receive`
operation above, because it is the whole inventory: a `Reference`-typed
`attribute` saying which record the fact is about (`reference_to` is
banned here — `port_operation_builder.rb`'s own refusal — routing goes
in `to:` at dispatch, never redeclared inside the operation body), an
`attribute` or two of ordinary fact, an `emits`. No `given`. No `sets`. Those are not omissions made at
the authoring level — `DomainPortBuilder`/`PortOperationBuilder`
simply define no such methods, so there is nothing to reach for even
by mistake. A port operation TRANSLATES an external fact into this
domain's own event vocabulary; it does not hydrate a record, does not
mutate one, does not save. Whatever should happen next — crediting the
sale, flagging a mismatch — happens wherever a `policy` reacts to the
event this emits, exactly the way `pizzas.bluebook`'s
`OnPizzaPaymentReceived` reacts to `PizzaPaymentReceived`; wiring that
reaction is [policies-and-process-managers.md](policies-and-process-managers.md)'s job, not this page's.

Call it the way a real payment processor's webhook handler would —
through `dispatch_port`, never through the entry point a chef's own commands
use:

```ruby
events = runtime.dispatch_port("Pizzas", "Order", "PaymentGateway", "Receive",
                                flat: { name: order.id, customer_name: { value: "Chris" }, amount: { cents: 1200 } })
events.map(&:name)   # => ["PizzaPaymentReceived"]
```

And here is the "no `sets`" claim, not just asserted but shown:
`events` above holds exactly the one event `PaymentGateway`'s `Receive`
itself declares with `emits` — not `"PizzaPurchased"`, which belongs to
`Purchase`, never to the port that led to it. The port's own return
value proves it touched nothing beyond translating the call.

The order sold anyway — read it back:

```ruby
Order.find(order.id).status              # => "sold"
Order.find(order.id).customer_name.to_h  # => { value: "Chris" }
```

That mutation did not come from the port. It came from
`OnPizzaPaymentReceived`, wired in `pizzas.bluebook` itself, reacting
to the very event the port above just emitted and dispatching
`Purchase` — the same command, the same `given` guards, that a real
purchase flow would call directly. The reaction is on the record, not
just asserted:

```ruby
runtime.registry.reaction_log   # => [{ policy: "OnPizzaPaymentReceived", on: "PizzaPaymentReceived", trigger: "Pizzas::Order.Purchase", delivered: true }]
```

An external call came in shaped nothing like this domain's own
commands, and everything that happened because of it stayed exactly
where every other business rule in this language lives — in a command,
reached through a policy, never inside the port.

## `subscribe`

`subscribe "EventName"` inside a hecksagon names an event this
domain's own wiring takes in from OUTSIDE `Pizzas`' own bluebook —
`hecksagon_builder.rb`'s own comment on the method calls it exactly
that: an event this hecksagon takes from outside the domain's own
bluebook. It is declared the same way everything else in a hecksagon
is — read straight back off the registry once booted:

```ruby
runtime.registry.hecksagon("Pizzas").subscriptions   # => ["IngredientShipmentReceived"]
```

Nothing more is claimed for it than that. It is a fact recorded
at the deployment boundary, not a routing table this page can show
dispatching anything — if a feature needs a subscribed event to
actually trigger a reaction, that reaction is a `policy`, the same as
every other one.

## `.world`: per-deployment values

A `.hecksagon` says WHICH adapter. A `.world` says what THAT adapter
needs to actually run — values, and only values, checked against the
exact binding they answer:

```ruby
runtime.registry.world("Pizzas").realm                                  # => "Examples"
runtime.registry.world("Pizzas").for_binding("persisted_by", "Memory")  # => { adapter: "Memory" }
```

Memory needs nothing beyond its own name, which is why that block
above is one bare word. A real deployment binding to Postgres instead
carries the values Postgres actually declares — `database` and `role`,
the two fields `postgres.adapter` names, though a deployment only ever
supplies what it actually uses. This is not hypothetical for Pizzas
either — this is `examples/pizzas/bluebook/pizzas.world`, quoted
verbatim, not run here (`.world` files are never loaded through the
doctest boot path, only through a real `Hecks.boot`):

```ruby skip
Hecks.world "Pizzas" do
  realm "Examples"
  persisted_by("PostgresEra") do
    database "postgres://localhost/hecks_pizzas"
    allow_superuser true
  end
end
```

That `allow_superuser true` is the one line a real deployment never
writes. `PostgresEra`'s era write-fence is Postgres row-level security,
and a superuser (or any role granted BYPASSRLS) walks straight through
every policy, `FORCE ROW LEVEL SECURITY` included — so `PostgresEra`
refuses to boot over such a connection by default, naming the role and
the two ways out: an ordinary role in the URL
(`postgres://<role>@<host>/<db>` — an ordinary *owner* still provisions
and mints), or this explicit opt-in, which boots with the fence void,
on the record, and says so on stderr on every boot. The example carries
it because it runs against whatever Postgres user your shell defaults
to, which on a self-hosted machine is almost always a superuser; the
[schema evolution guide](schema-evolution.md) has the whole story.

A `.world` block can carry more than one adapter binding, plus a
deployment target. `examples/banking/bluebook/banking.world`, quoted
verbatim:

```ruby skip
Hecks.world "Banking" do
  realm "Examples"
  latest "v1"
  persisted_by("Heki") do
    dir "data"
  end

  projected_by("SqliteProjection") do
    database "data/banking_projection.sqlite3"
  end

  deployed_to("AwsLambda") do
    region "us-east-1"
    memory 512
    timeout 10
    database "Shared"    # no RDS of Banking's own
    owner "Platform"     # isolated by its own native Postgres schema
  end
end
```

`deployed_to("AwsLambda")` is read by `hecks deploy recipe.project` (see
[Projections: Rust and
WebAssembly](projections.md), and [architecture-map.md](../../architecture-map.md) for
the projector inventory) to generate a SAM template, build Makefile and
deploy config, no secret typed anywhere. Because this example declares
`database "Shared"`, the stack borrows the VPC and Postgres instance of
the stack named by `owner` instead of creating its own; a domain that
declares no shared database gets its own VPC and RDS instance, plus a
bastion config for minting its first era. A deployment that must name a
specific owner stack or stack prefix does so in an environment overlay
(`hecks deploy recipe.project <domain> --environment=<name>`) kept outside this
repository.

### Hosting scripts for `AwsFargate`

A `deployed_to("AwsFargate")` block that sets `hosting_scripts true`
also gets the scripts an operator runs after the stack exists, in the
same directory as the template. A block without it generates exactly
what it did before.

The block's words are `hosting_scripts true`, `hecks_release "2.5.1"` (required:
the Hecks release the image is built from), `smoke_repo "owner/name"` (the GitHub
repository holding the smoke workflow), `smoke_workflow "smoke.yml"` and
`expected_eras ["199b08"]`, next to the `region` the block already carries.
`hecks_release "edge"` follows the newest commit on `stable` instead of a release:
the `edge` tag moves with every promotion (a `main` commit that passed every required
check), each build fetches it afresh and prints the
commit it got, and the exact-tag check is skipped for it alone. A build from `edge`
is not reproducible from the name, so a release is still how a deploy is pinned.
Run `hecks deploy recipe.project <domain> --out=<dir>` on a domain whose `.world` carries
the block and it writes those files beside `template.yaml`. Without
`hosting_scripts true` the same run writes only what it always did:

```ruby
require "fileutils"
require "open3"
require "tmpdir"

hecks_exe = File.join(InMemoryDomain::ROOT, "exe/hecks")
domain_dir = File.join(Dir.mktmpdir("hecks-doctest-hosting-"), "scratch")
FileUtils.mkdir_p(File.join(domain_dir, "bluebook"))
File.write(File.join(domain_dir, "bluebook/scratch.bluebook"), <<~BLUEBOOK)
  Hecks.bluebook "Scratch" do
    aggregate "Thing" do
      identified_by :name
      attribute :name, ThingName
      value_object "ThingName" do
        attribute :value, String
      end
      command "Create" do
        attribute :name, ThingName
        sets :name
        emits "ThingCreated"
      end
    end
  end
BLUEBOOK

generate = lambda do |hosting|
  File.write(File.join(domain_dir, "bluebook/scratch.world"), <<~WORLD)
    Hecks.world "Scratch" do
      deployed_to("AwsFargate") do
        region "us-east-1"
        stack_prefix "acme"
        #{hosting}
      end
    end
  WORLD
  out = File.join(domain_dir, "out-#{hosting.empty? ? 'plain' : 'hosting'}")
  _stdout, stderr, status = Open3.capture3("ruby", hecks_exe, "deploy", "recipe.project", domain_dir, "--out=#{out}")
  raise stderr unless status.success?

  Dir.children(out).sort
end

hosting = <<~SETTINGS.strip
  hosting_scripts true
  hecks_release "2.5.1"
  smoke_repo "owner/name"
  smoke_workflow "smoke.yml"
  expected_eras ["199b08"]
SETTINGS
generate.call(hosting) - generate.call("")   # => ["deploy-service.sh", "expected-era", "hosting.mk", "smoke-after-deploy.sh"]
```

| File | What it does |
| --- | --- |
| `deploy-service.sh` | Pushes a local image under a fresh tag, swaps one container's image in the active task definition, and syncs that container's CloudFormation `*ImageTag` parameter, checking that no other parameter changed |
| `smoke-after-deploy.sh` | Waits for the roll to settle, then dispatches the smoke workflow and reports the result |
| `hosting.mk` | Included by the `Makefile`: pins the Hecks release (`HECKS_ROOT` is a cached checkout of its tag) and adds `deploy-service`, `smoke-after-deploy` and `check-era` |
| `expected-era` | The eras `hecks host.check_era` accepts from a host's `GET /version` |

The settings, with their defaults, are documented on
`Hecks::Projections::Deploy::Scripts`. `hecks host.check_era <url> expected=expected-era`
compares the era a running host reports with that file and exits 1 when it
is not listed. The scripts take their containers, ECR repositories and
image-tag parameters from the same resolved settings the stack template is
rendered from (the world's `domain_container` and `containers`), never from a
second list, so `deploy-service.sh` names exactly what `template.yaml`
defines. The generated `Makefile`'s `deploy` follows a renamed domain
container's repository and image-tag parameter the same way.

The other opt-in files below share its rule: nothing is generated for a block
that does not ask, so a stack that never mentions them is unchanged.

### One box and one database: `AwsBox`

`deployed_to("AwsBox")` generates an RDS stack and an EC2 box that runs the
domain's containers with Docker Compose behind Caddy, for a project that does
not need a load balancer or a container service ([ADR 0085](../../decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md)).

```text
deployed_to("AwsBox") do
  region "us-east-1"
  containers [{ name: "website", port: 8080 }, { name: "cms", port: 8081 }]
  default_container "website"
  routes [{ container: "cms", paths: ["/cms/*"] }]
  origin_header "X-Origin-Secret"   # only requests carrying it are proxied
  origin_secret "acme/origin-secret" # a Secrets Manager name, read on the box
end
```

`hecks deploy project` writes `rds.yaml`, `box.yaml`, `Caddyfile`,
`services.json`, `render-compose.sh`, `fetch-secrets.sh`, `deploy-box.sh` and a
`Makefile`. Secrets are named, never written down: the box resolves them when it
deploys. A world with no `containers` is refused with an example.

A project moving off an existing database adds
`migration({ schemas: ["app", "app_cms"], source_database: "legacy" })`, and
three more files are written: `restore-to-rds.sh` (copy each schema through a
bastion, then verify), `verify-copy.sh` (structure and exact row counts of both
sides) and `MIGRATION.md`, the steps in order with the rollback caveat. The
bastion, hosts and secrets are arguments to the scripts, so the same files serve
a rehearsal, the cutover and a copy back. To let that bastion reach the new
database, pass its security group as `BastionSecurityGroupId` to the RDS stack.

The two scripts also run as commands, which record each copy in the Hecks database:

```
hecks deploy data_copy.restore <project> bastion=i-0abc source=<old-host> source_secret=<arn> \
  target=<rds-host> target_secret=<arn> [source_db=] [target_db=] [force=true] [skip_verify=true]
hecks deploy data_copy.verify  <project> bastion=i-0abc source=<host> source_secret=<arn> \
  target=<host> target_secret=<arn> [source_db=] [target_db=]
```

`data_copy.restore` overwrites the target database's schemas, so it **refuses unless `confirm=true`
is given**; the refusal names the schemas, database and host it would overwrite and writes
nothing. `dry_run=true` prints that plan and runs nothing, with or without `confirm`. `force=true`
drops schemas the target already has first (the script otherwise stops with 61). A restore that
ran is `restored`, and a policy then requests the comparison under the same run key (`skip_verify=true`
leaves it out), so the one `DataCopy` ends `verified` (both sides identical), `drifted` (they
differ; the differences are in `refusal`) or `flagged` (the copy or the comparison could not be
made). `data_copy.verify` runs the comparison alone, read-only on both databases, and records the
same outcomes on a `DataCopy`. A `drifted` or `flagged` copy is exit 1 (both commands wait for
their reactions). `script=<path>` names the script when a project holds more than one. The
scripts end with these statuses, which the reason names:

| Status | Meaning |
| --- | --- |
| 50 | `verify-copy.sh`: the databases differ (structure, row counts or an unpopulated materialized view): `drifted` |
| 60 | `restore-to-rds.sh`: `pg_dump`, `pg_restore` or `psql` older than 16 |
| 61 | `restore-to-rds.sh`: the target already has a schema (use `force=true`) |
| 62 | `restore-to-rds.sh`: restore errors other than the known `hecks_tr_extract` ones |

Any other status is a step that failed under `set -e` (1, or 254 or 255 from the `aws` CLI): `flagged`.
By hand, `restore-to-rds.sh` still verifies at its end (exit 50 on a difference); the command sets
`VERIFY_BY_COMMAND=1` so the policy's comparison is the only one.

A box whose containers use S3 declares it with
`s3_access [{ bucket: "acme-media", write: true }]`: the role reads every listed
bucket, and writes only on a production box (`Rehearsal=false`), so a rehearsal
never changes the real objects.

For a rehearsal that needs a smoke test without the CDN, the proxy imports any
site file placed under `caddy-extra` on the box, for example a loopback listener
that adds the origin secret; production mounts none. The proxy has its admin API
off, so restart it after adding a file (`docker compose -f compose.json restart caddy`
in the box's directory); a reload cannot reach it.

`make stacks` makes a production pair by default, with deletion protection and an
Elastic IP. `make stacks REHEARSAL=true` makes a throwaway pair instead, which is
how to try the generated stacks without touching anything that matters. The
deploy waits for the box's first boot to finish, so it can be run as soon as the
stacks exist.

To check what the stacks cost against a budget, run
`hecks deploy cost_check.check budget=75 since=2026-10-05 --wait`. It reads the
daily bill from `since` up to yesterday (today is still partial), scales the mean
to a month, and records the check as `within_budget` with a one-line report that
names the biggest services, or as `flagged` with the figures when the rate is over
the budget or no complete day has passed. Give it the first complete day after the
last change to what runs, so a bill that still carries the old setup is not read as
the new one. It exits 1 when flagged, and needs AWS credentials that can read Cost
Explorer.

To run the post-deploy smoke as a command, run
`hecks deploy smoke_run.run <project> --wait`, which finds the `smoke-after-deploy.sh` beside the
project's `Makefile` (or the only one under it; `script=<path>` names it otherwise)
(`taskdef=<family[:revision]>`, `skip=true`, `async=true` and `dry_run=true` become the
script's `TASKDEF`, `SKIP_POST_DEPLOY_SMOKE`, `SMOKE_ASYNC` and `DRY_RUN`). It runs the
generated script, so the settle checks and the workflow dispatch are the ones `make deploy`
already runs, records the run as `passed` with what the script printed, or as `flagged`
with its status (20 the roll did not settle, 21 `gh` missing, 22 the smoke failed, 23 result
unknown), and exits 1 when flagged. It only reads AWS.

To roll a project as a command, run `hecks deploy service_roll.run <project> service=<name> --wait`
(`existing_tag=<tag>` redeploys a tag already in ECR, `local_image=<ref>` names the image to push)
or `hecks deploy box_roll.run <project> --wait` (`taskdef=<family[:revision]>` for a project with a
task definition, `tags="web=20260101 worker=20260101"` for one without). Each runs the project's
generated `deploy-service.sh` or `deploy-box.sh`, found the way the smoke script is, and records a
`ServiceRoll` or `BoxRoll` (a service roll with its `tag` and `taskdef`). A failed roll is
`flagged` with the script's status and what it printed. A successful roll's policy requests a
`SmokeRun` under the same run key, and policies on the smoke's outcome move the roll to `verified`
(the smoke passed) or `flagged` (the smoke failed, its reason in `refusal`), so the command exits 1 for
a failed roll or a failed smoke. A roll that stays `rolled` requested no smoke, and its `smoke` field
says why: `skip_smoke=true` leaves it out, and a project with no `smoke-after-deploy.sh` records
`smoke skipped: no smoke script`. These commands write to AWS, as the scripts do. Their statuses:

| Status | Meaning |
| --- | --- |
| 2 | `deploy-service.sh`: unknown service |
| 30, 31 | `EXISTING_TAG` is not in ECR; the fresh tag is already in ECR |
| 32, 33 | the box's Compose file is unreadable; the box stack has no instance |
| 34 | the hosting stack has no parameter for the container |
| 35, 36 | the stack update failed or did not settle; a parameter other than the container's changed |
| 37, 38 | the task definition lacks the pushed image; it has no such container |
| 40, 41, 42 | `deploy-box.sh`: no instance; the roll did not succeed on the box; the box is not healthy after it |

Any other status is a step that failed under `set -e` (1 from bash, 254 or 255 from the `aws` CLI).
The design for the other deploy scripts is [ADR 0090](../../decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md).

To reach a container through a Cloudflare Tunnel instead of the CDN origin, add
`tunnel({ to: "stats", token_secret: "acme/tunnel-token" })`. The box then runs
`cloudflared` beside the containers, forwarding to `stats`' port, and the deploy
waits for a registered connection. `tunnel true` alone only opens the outbound
port, for a tunnel you run yourself.

A project that already runs on Fargate can point the box at the task definition it
has: `task_definition "acme-platform"`. The box is then rendered at deploy time from
that task, so its images, environment and secrets are the task's, and the world
lists only each container's name and port (a container that also sets `env`,
`secrets` or `repository` is refused). `make deploy TASKDEF=acme-platform:7` rolls a
chosen revision; with no argument it takes the latest.

With a task definition and an `origin_secret`, only the proxy reads the named secret:
the containers keep the task definition's own copy of the CDN's secret. A copy that
differs makes the proxy refuse every request from the CDN. Name the variables that hold
it, `origin_env ["CLOUDFRONT_ORIGIN_SECRET", "HECKS_PROXY_AUTH_SECRET"]`, and
`render-compose.sh` fetches the secret and refuses to render when any of them
differs, or when no container sets one (so a typo cannot skip the check). It never
prints a value. `origin_env` without an `origin_secret` and a `task_definition` is
refused.

### A database several sites share: `AwsSharedDatabase`, and `shared_database`

A platform that hosts more than one site can run one RDS instance for all of them
([ADR 0092](../../decisions/0092-clients-share-one-database-instance-each-in-its-own-database.md)).
The platform's own world declares the instance:

```text
deployed_to("AwsSharedDatabase") do
  region "us-east-1"
  stack_name "hecks-platform-rds"        # required: every site names this string
  database_class "db.t4g.small"          # defaults: db.t4g.small, 30 GB, Postgres 16, 7-day backups
end
```

`hecks deploy project` writes `rds.yaml`, a `Makefile` (`make stack VPC=... PRIVATE_SUBNETS=...`) and a README. The
stack makes no database of its own; each site's rule on its security group is that site's box stack's, and the bastion's
is its own resource so an update cannot revoke a site's rule.

A site's `deployed_to("AwsBox")` block then says `shared_database "hecks-platform-rds"`. It generates no `rds.yaml`;
`deploy-box.sh` and the `Makefile` read the endpoint and security group from the shared stack and the login from the
site's own secret `<site>/database`, and `provision-database.sh` (`make provision BASTION=i-...`) creates that site's
role (not a superuser), the database it owns, and the secret. `database_class`, `storage_gb`, `engine_version` and
`backup_days` are refused beside it, since they are the instance's.

### Hosting scripts for `AwsBox`

A `deployed_to("AwsBox")` block that sets `hosting_scripts true` also gets the
scripts an operator runs after the stacks exist, beside the others. A block
without it generates exactly what it did before.

```text
deployed_to("AwsBox") do
  ...
  task_definition "acme-platform"
  hosting_scripts true
  hosting_stack "acme-platform"      # the stack whose TaskDefinition reads the image tags
  smoke_workflow "smoke-prod.yml"    # required: the GitHub workflow to dispatch
  smoke_repo "acme/shop"             # default: the repository `gh` reads in the working directory
  smoke_ref "main"                   # default
  expected_eras ["a1b2c3"]
  public_url "https://shop.example.com"
end
```

A container can name its stack parameter with `tag_parameter "EngineImageTag"`; the
default is the container's name in CamelCase plus `ImageTag` (`web-app` becomes
`WebAppImageTag`). `hosting_scripts` without a `smoke_workflow` is refused, as is
a `task_definition` without a `hosting_stack`, a `hosting_stack` without a
`task_definition`, and any hosting word while `hosting_scripts` is not true.

| File | What it does |
| --- | --- |
| `deploy-service.sh` | Pushes a local image under a fresh tag (`<service>-<UTC timestamp>`, refused if ECR already has it), sets that container's parameter on the hosting stack and checks that no other parameter changed, refuses to roll a task definition that does not carry the pushed image, then runs `deploy-box.sh` on it. Without a `task_definition` it names the new tag for the service and the tag the box runs now for every other one. `EXISTING_TAG=<tag>` redeploys a tag already in ECR |
| `smoke-after-deploy.sh` | Waits for the box to settle, then dispatches the smoke workflow, finds the run that dispatch created and follows it. Exits 20 (did not settle), 21 (no `gh` or repository), 22 (smoke failed) or 23 (result unknown) |
| `hosting.mk` | Included by the `Makefile`: `deploy-service SERVICE=<name>` (the `service_roll.run` command), `smoke-after-deploy` and `check-era URL=...` |
| `expected-era` | The eras `hecks host.check_era` accepts from a host's `GET /version` |

Before a roll replaces a container, `deploy-box.sh` saves that container's log on the box, because Docker deletes it with the container. Each running container of the Compose project (with `deploy-service.sh`, only the service being rolled) is written to `/var/log/hecks-captures/<container>-<UTC timestamp>.log`, the newest 14 per container are kept, and the step prints each file's path and size, never its contents. It is skipped with a warning when under 2 GiB is free on `/var/log`, a failure to capture is a warning and never changes the roll's exit status, and `SKIP_LOG_CAPTURE=1` skips it. Read a capture over SSM, for example `grep would_refuse_role /var/log/hecks-captures/*.log`.

"Settled" means two consecutive checks, a few seconds apart, agree that the box
stack (and the hosting stack) is complete, every container and the proxy of the
box's Compose project is up and has stayed up, and, with a task definition, each
container runs the image the latest revision names. A roll that looked live but
left an old image running therefore never reaches the smoke. The box is read over
SSM, the way `deploy-box.sh` rolls it, and the scripts only read AWS apart from
the stack update and the roll itself. `make deploy` runs `hecks deploy box_roll.run` and
`make deploy-service` runs `service_roll.run`; the roll's policy requests
`smoke_run.run`, which runs `smoke-after-deploy.sh`. Every deploy so leaves a roll (that also
holds the smoke's outcome) and a `SmokeRun` in the Hecks database that `hecks deploy box_roll.verdict`,
`service_roll.flagged`, `smoke_run.verdict` and `smoke_run.flagged` can query. The command's exit
covers the whole deploy, so the target reads nothing after it.
`SKIP_POST_DEPLOY_SMOKE=1` becomes `skip_smoke=true`, and `DRY_RUN=1` dispatches nothing
when the smoke is run alone. A failed roll or smoke is exit 1; the script's own status
(the table above, or 20 to 23 for the smoke) is in the message.

The record needs a database, and a non-superuser role that owns it, on the machine
that runs `make deploy`. The Hecks domain reads `HECKS_DATABASE` and defaults to
`postgres://hecks@localhost/hecks`; `createdb hecks` alone is not enough, because the
era write-fence is row-level security and Postgres exempts a superuser from it, so the
boot refuses (`cannot open Hecks: ... this connection's role "hecks" is a superuser`).
A developer machine whose default `hecks` role is a superuser must use a separate
non-superuser role for deploy records, once:

```sql
CREATE ROLE hecks_deploy NOSUPERUSER LOGIN;
CREATE DATABASE hecks_deploy OWNER hecks_deploy;
```

and `HECKS_DATABASE=postgres://hecks_deploy@localhost/hecks_deploy`; the first run
creates the tables. A CI job that runs `make deploy` needs the same: a Postgres service and
`HECKS_DATABASE` set. Without the database the command cannot start, so the
generated `deploy`, `deploy-service` and `smoke-after-deploy` targets say so, run the
script anyway (and the smoke after a roll) so the result is printed, and fail with the
database error stated apart from the deploy's outcome: the script's own status when it
failed, or `Error 24` when it all passed. A project that does not set `hosting_scripts true`
deploys through `box_roll.run` as well; it has no smoke script, so its roll stays `rolled` with
`smoke skipped: no smoke script`.

### The last three scripts: the bluebook report, previews and a companion roll

Three scripts a project keeps by hand also run as commands, each found by name beneath the
project (`script=<path>` names one when there are several) and each recorded in the Hecks database:

```
hecks deploy bluebook_diff.run <project> [old=<json> new=<json>]
hecks deploy preview_run.<name|url|list|deploy|destroy|login> <project> [branch=<name>] [confirm=true] [dry_run=true]
hecks deploy companion_roll.run <project> taskdef=<family:rev> [companion=umami] [confirm=true] [dry_run=true]
```

`bluebook_diff.run` reports which bluebook releases a deploy changes. Given `old` and `new` (two
`hecks package.verify` outputs) it compares them itself, offline; given neither, it runs the project's
`bluebooks-diff.sh`, which reads the running image's bluebooks from the registry, read-only. It never
fails: the report is `unchanged`, `changed` or `unavailable` (a lookup failed, the script is missing or
ended non-zero), and each is exit 0. Only giving one of `old` and `new` is `flagged`, exit 1.

`preview_run` runs the project's `preview.sh` with the verb named. `name`, `url` and `list` read.
`deploy`, `destroy` and `login` write to AWS or read its secrets, so they **refuse unless
`confirm=true` is given**, naming the plan and running nothing; `dry_run=true` prints the plan and
runs nothing. `main` and `master` are refused before anything runs. The record ends `named`,
`located`, `listed`, `deployed`, `destroyed`, `signed_in`, `planned` or `flagged`.

`companion_roll.run` rolls a second Compose project onto the box beside the app's, with the
project's `deploy-<companion>.sh`. It refuses unless `confirm=true`, prints its plan for
`dry_run=true`, and ends `rolled` (the check on the box passed), `planned` or `flagged`.

| Command | Exit | Meaning |
| --- | --- | --- |
| `bluebook_diff.run` | 0 | `unchanged`, `changed` or `unavailable` |
| `bluebook_diff.run` | 1 | only one of `old` and `new` was given |
| `preview_run.*`, `companion_roll.run` | 0 | the script ended 0, or the run was a dry run |
| `preview_run.*`, `companion_roll.run` | 1 | the write was not confirmed, the branch was `main` or `master`, no script was found, or the script ended non-zero: 1 for every refusal and failure it reports, 2 for a bad verb, with its output in the reason |

### Per-branch previews for `AwsFargate`

A `preview` setting inside the `deployed_to("AwsFargate")` block adds two files
beside the template: `preview.yaml`, a separate CloudFormation template, so a
preview never appears in a change set against the live stack, and `preview.sh`,
which creates, updates and deletes one isolated copy of the stack per git branch.
`preview true`, or a `preview do ... end` block with no settings, accepts every
default:

```ruby
deploy = Hecks::Projections::Deploy::Preview
deploy.requested?({ preview: true })    # => true
deploy.requested?({ preview: {} })      # => true
deploy.requested?({ preview: false })   # => false
deploy.requested?({})                   # => false
```

`preview.sh` takes `deploy` (create or update this branch's preview, from the
images built locally, so it deploys the working tree, and the stack's `Commit`
tag ends in `-dirty` when there were uncommitted changes), `destroy` (which also drops the branch's database
when `PREVIEW_DROP_DATABASE=1`), `list`, `url`, `name`, `ensure-database` and,
unless `first_admin false`, `login`, which prints a browser-console line that
signs the deployer in as the preview's first admin. A preview's database is
created inside the VPC by a one-shot task the template declares, so neither the
main stack's bastion nor a tunnel is involved, and the host mints era 1 itself on
the empty database.

It cannot touch the live stack: `preview.sh` only operates on stacks under the
preview `prefix`, refuses the `protected_branches` (`main` and `master` unless
set), and the database task refuses the main database, `postgres` and the two
template databases. The block's keys, all optional, are `prefix`, `alb_prefix`,
`owner_stack`, `database_stack`, `database_endpoint_output`,
`database_secret_output`, `db_prefix`, `protected_databases`,
`protected_branches`, `cpu`, `memory`, `log_retention_days`, `session_cookie`,
`first_admin`, `signup_path`, `landing_path`, `db_init_image` and `containers`
(the containers the preview task runs; by default the main stack's). A key that
is not on that list, or a value that breaks the pattern its place allows (each
ends up in a stack name, a database name or a shell script), fails the generate
with a message naming it. The defaults and every pattern are documented on
`Hecks::Projections::Deploy::Preview`.

### A generic smoke workflow for `AwsFargate`

`smoke true` in the same block adds `smoke/harness.js`, a JavaScript smoke
harness that knows nothing about any site, and `smoke/workflow.yml`, a GitHub
Actions workflow that runs it on a schedule and on demand. `hecks deploy recipe.project`
adds them to whatever the deploy target produced; copy the workflow into the
repository's `.github/workflows/`.

```ruby
smoke = Hecks::Projections::Deploy::Smoke
role = "arn:aws:iam::123456789012:role/example-smoke"
settings = { smoke: true, region: "us-east-1", smoke_role_arn: role,
             smoke_secret_id: "example/session-secret", smoke_site_url: "https://example.org" }
smoke.files(settings, stack_name: "pizzas").keys.sort   # => ["smoke/harness.js", "smoke/workflow.yml"]
smoke.files({}, stack_name: "pizzas")                   # => {}
```

Three settings are required beside the `region`: `smoke_role_arn` (the role the
workflow assumes by OIDC, with no long-lived keys; created once, by hand, outside
the stack), `smoke_secret_id` (the Secrets Manager secret holding the signing
secret the harness needs) and `smoke_site_url`. Optional: `smoke_secret_field`
(a JSON field, when the secret is a JSON document), `smoke_secret_env` (the
variable the harness reads it from, `SESSION_SECRET` by default),
`smoke_schedule` (a cron expression, every 15 minutes by default),
`smoke_harness` and `smoke_config` (the repository-relative paths the workflow
runs, `smoke/harness.js` and `smoke/config.js`) and `smoke_setup` (one shell
command run before the AWS steps). A missing required setting, or a value that
could break out of the YAML or shell line it lands on, fails the generate.

What stays with the site is its own `config.js`, which this never writes: the
pages and flows to assert, the cookie name and the expected-era file. The
harness owns the rest: the check runner and its summary, HTTP helpers, signed
claims and session cookies, sandbox guest addresses, the expected-era check
against `GET /version` (the same allow-list format `hecks host.check_era` reads), and a
sweep that takes a run's own rows back out. It runs `SMOKE_MODE=safe` by default,
which tags every guest address with a sandbox mailbox so a run against
production never mails a real person; `SMOKE_MODE=full` is for a throwaway
database. The harness's header lists the config module's keys. The hosting scripts'
`smoke_repo` and `smoke_workflow` settings above name where
`smoke-after-deploy.sh` finds this workflow to dispatch it.

### The domain as a Vercel function: `Vercel`

`deployed_to("Vercel")` generates the configuration and deploy script for the
domain's host as one Vercel function ([ADR 0093](../../decisions/0093-vercel-is-a-deploy-kind-the-host-as-one-function.md)).
It creates no database: persistence is the hecksagon's, Postgres read from
`DATABASE_URL`.

```text
deployed_to("Vercel") do
  region "iad1"                  # a Vercel region id, the default
  memory 1024                    # MB
  max_duration 30                # seconds
  scope "acme"                   # the team, optional
  env ["SESSION_SECRET"]         # names only; DATABASE_URL is always set
  crons [{ path: "/cron/tick", schedule: "*/5 * * * *" }]
end
```

`hecks deploy project` writes `vercel.json`, `.vercelignore`, `deploy-vercel.sh`
and a `Makefile`. The script reads each named variable from the environment
(`op run --env-file=.env.tpl -- make deploy`) and passes it to Vercel on stdin
as a sensitive variable, so no value reaches a file or a command line. The host
needs a Vercel entry point at `api/host.rs` before the function answers; see
the ADR's open items.

A world can declare more than one deploy kind, so a small domain can start on
Vercel and keep an `AwsBox` block beside it. The persistence adapter, not the
deploy kind, owns the data (Postgres by URL), so the move is a deploy choice.
`hecks deploy project` writes each target under `<out>/<adapter>/`;
`--target=Vercel` writes only that one into `<out>`.

### Project-wide defaults

A project that attaches many chapters does not have to repeat that
`persisted_by ... database` block in a world per chapter, nor a
`persisted_by` line per aggregate in a hecksagon per chapter. The
project's own world can say both once — `default_adapter "PostgresEra"`
binds every aggregate no hecksagon binds, and `default_database "..."`
supplies the `database` of every bound adapter that takes one — and a
chapter's own bind or settings still win. `examples/compliance` does
exactly this; the [world reference](../reference/world.md) has the
resolution order.

A chapter can also come from a package of the shared bluebook registry
instead of hecks's own `lib/`: `attaches "<name>", from: :vendor` in the
hecksagon loads the package vendored into the project, and `hecks package.vendor` pins
one there. The [hecksagon reference](../reference/hecksagon.md#vendoring-a-package)
has the command, the `VENDORED_COMMIT` and `bluebook.lock` files it writes, and
what it refuses. The environment the host itself reads (checkout, payments and
the public-route rate limits, which a proxy in front of the host changes the
meaning of) is on [its own page](../rust-host.md).

## Writing your own port or adapter

Everything above reached for a port and an adapter the library already
ships (`persistence`, and `Memory`/`Postgres` answering it). A project
whose feature needs neither — a receipt printer, say — declares its
own the same two ways the library's own are said:

```ruby skip
Hecks.port "receipt" do
  verb "receipted_by"
end

Hecks.adapter "ThermalPrinter" do
  port   "receipt"
  field  :device_path
  secret :pairing_key
end
```

That declares "receipt" as a project-wide port — reusable by any
aggregate, worth its own file the moment more than one might bind it.
A port that belongs to exactly one aggregate does not need a file of
its own: the same `verb` word reached from *inside* the hecksagon,
right beside the aggregate it addresses, registers the identical
`IR::Port` — bound, verified, and settings-resolved exactly the same
way, just spelled where it is actually used instead of a level of
indirection away:

```ruby skip
Pizzas::Order.port "receipt" do
  verb "receipted_by"
end
```

Same name, same aggregate-scoped `port` call [Driving ports](#driving-ports)
above already reaches for `operation` — a port is one shape or the
other, `verb` or `operation`, never both. `Hecks.adapter
"ThermalPrinter"` does not change at all; an adapter names the port it
answers by string (`port "receipt"`), and does not care which of the
two ways that port was declared.

[writing-an-adapter.md](writing-an-adapter.md) is where that contract lives in full — what
`field` versus `secret` actually buys you, what a driven adapter must
implement, how a driving one calls back in. Reach for the library's
own port before inventing a new one; a new port is a bigger decision
than a new adapter, because every future adapter answering it inherits
the shape you chose today.

## Fields belong to the adapter, not the port

One rule worth carrying forward from `README.md`'s own wording: fields
belong to the **adapter**, not the port. `Postgres` and `Memory` both
answer `persistence`, and they genuinely need different things —
`database`, in Postgres's case; nothing at all, in Memory's. A
`.world` block is checked against exactly what the named adapter
declares, so a value it does not know is refused at boot, not silently
dropped. Get a field name wrong in a real `pizzas.world` and you find
out before the kitchen ever opens, not the first time a customer tries
to buy a pizza against it.
