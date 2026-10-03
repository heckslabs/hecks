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
  uses_framework "Governance"
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

A `port` declared in the hecksagon is a second front door, for facts
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
through `dispatch_port`, never through the door a chef's own commands
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

`deployed_to("AwsLambda")` is read by `hecks deploy project` (see
[Projections: Rust and
WebAssembly](projections.md), and [architecture-map.md](../../architecture-map.md) for
the projector inventory) to generate a SAM template, build Makefile and
deploy config, no secret typed anywhere. Because this example declares
`database "Shared"`, the stack borrows the VPC and Postgres instance of
the stack named by `owner` instead of creating its own; a domain that
declares no shared database gets its own VPC and RDS instance, plus a
bastion config for minting its first era. A deployment that must name a
specific owner stack or stack prefix does so in an environment overlay
(`hecks deploy project <domain> --environment=<name>`) kept outside this
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
Run `hecks deploy project <domain> --out=<dir>` on a domain whose `.world` carries
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
  _stdout, stderr, status = Open3.capture3("ruby", hecks_exe, "deploy", "project", domain_dir, "--out=#{out}")
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
| `expected-era` | The eras `hecks check_era` accepts from a host's `GET /version` |

The settings, with their defaults, are documented on
`Hecks::Projections::Deploy::Scripts`. `hecks check_era <url> expected=expected-era`
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

```ruby
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
Actions workflow that runs it on a schedule and on demand. `hecks deploy project`
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
against `GET /version` (the same allow-list format `hecks check_era` reads), and a
sweep that takes a run's own rows back out. It runs `SMOKE_MODE=safe` by default,
which tags every guest address with a sandbox mailbox so a run against
production never mails a real person; `SMOKE_MODE=full` is for a throwaway
database. The harness's header lists the config module's keys. The hosting scripts'
`smoke_repo` and `smoke_workflow` settings above name where
`smoke-after-deploy.sh` finds this workflow to dispatch it.

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
instead of hecks's own `lib/`: `uses_embryonaut_bluebook` in the hecksagon
loads the package vendored into the project, and `hecks vendor` pins
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
