# Hecksagon

<!-- generated:begin id=page -->
Words available inside `hecksagon do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

`port`, `subscribe`, and `attaches` are wiring, so they run against
`examples/banking` with a hecksagon written here rather than the one the
example ships. `translates` and `bounded` get their own small boot further
down — they need two cooperating domains, which this page's own Banking
boot never declares two of:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  attaches "Governance"
  subscribe "Compliance.AccountFreezeReviewOpened"

  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")

  # A DRIVING PORT declared against one aggregate's own box — the
  # spelling `examples/pizzas` uses. See the note under `port` below on
  # the bare, chapter-level form.
  Banking::Account.port "RiskFeed" do
    operation "Flag" do
      attribute :number, Hecks::Bluebook::Reference.new("Account")
      attribute :narrative, Narrative
      emits "RiskFlagReceived"
    end
  end
end

# A FRAMEWORK MEMBER BRINGS ITS OWN SHAPE, NOT ITS OWN PERSISTENCE —
# whoever attaches it decides where its aggregates live.
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

## subscribe

<!-- generated:begin word=subscribe -->
`subscribe subscriptions` — fills `subscriptions`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | subscriptions |
<!-- generated:end -->

Names an event this hecksagon takes in from outside its own bluebook. It is declarative only, today — recorded on the registry (`runtime.registry.hecksagon(domain).subscriptions`) and readable back after boot, but nothing routes a subscribed event anywhere by itself. If a feature needs one to actually trigger a reaction, that reaction is still a `policy`, wired the ordinary way.

Declared and readable back:

```ruby
runtime.registry.hecksagon("Banking").subscriptions  # => ["Compliance.AccountFreezeReviewOpened"]
```

"Declarative only" is the part to take literally. Nothing routes it —
there is no handler to find, and asking the registry for one turns up
nothing at all:

```ruby
runtime.registry.bluebook("Banking").policies.map(&:event_name).include?("AccountFreezeReviewOpened")  # => false
```

**Checked, not routed.** `subscribe` still dispatches nothing at
runtime — the example just above proves that, and it stays true. What
changed is that it is now checked at model-check time: a cross-domain
`policy ... across: "X"` with nothing acknowledging `X` (neither
`subscribe "X.*"` nor `attaches "X"`) is a real, static finding
(`:unacknowledged_relationship`, `Hecks::Bluebook::ModelCheck`). Banking's
own `subscribe "Compliance.AccountFreezeReviewOpened"` line, above, is
exactly what makes its `across "Compliance"` policy clean:

```ruby
require "hecks/bluebook/model_check"
banking      = runtime.registry.bluebook("Banking")
hecksagon    = runtime.registry.hecksagon("Banking")
compliance_policy = banking.policies.find { |p| p.target_domain == "Compliance" }
Hecks::Bluebook::ModelCheck.call(banking, hecksagon: hecksagon).map(&:subject).include?(compliance_policy.name)  # => false
```

Remove the acknowledgment and the SAME policy is flagged — this is what
finally gives `subscribe` real teeth, without giving it real dispatch
behavior:

```ruby
# A PLAIN Hecksagon, built directly rather than through Hecks.hecksagon
# (which only runs inside a boot) — no subscribe, no attaches, so
# Compliance goes unacknowledged.
unacknowledging = Hecks::Bluebook::Hecksagon.new(domain: "Banking")
findings = Hecks::Bluebook::ModelCheck.call(banking, hecksagon: unacknowledging)
findings.find { |f| f.subject == compliance_policy.name }.kind  # => :unacknowledged_relationship
```

See `docs/implemented/reference/policy.md`'s own `## across` section for
the other half — `attaches` and `across` on the SAME target
(`:contradictory_relationship`) — and the model-checker's own file for
why this needs no new keyword at all.

## attaches

<!-- generated:begin word=attaches -->
`attaches attachments, from:` — fills `attachments`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | attachments |
| `from:` | symbol | false | source |
<!-- generated:end -->

Attaches a chapter to this domain by name, from one of two places. It marks the chapter a bounded context, so the attaching hecksagon also declares a `Hecks.hecksagon` block for that chapter, and persistence is bound there as for any other chapter. It records the name and its source on the hecksagon that asked for it. Persistence is never part of what it loads: a chapter's aggregates need their own `Hecks.hecksagon "Governance" do ... end` block, declared by whoever attaches it, the same as any other binding decision.

Without `from:`, the name is a chapter the gem carries, found in one table: a `lib/hecks/framework/bluebook/` member such as `Governance` or `Identity`, or a chapter of the language itself (`Bluebook`, `Hecksagon`, `World`, `Adapter`, `Port`, `Translation`, `Paging`), `Expression`, `Tenancy`, `Deploy`, `Site`, `Tickets` or `QualityControl`. A gem chapter loads from its real location, never a copy, so it keeps working when the domain is copied somewhere else first (a fuzz run's isolated tmp boot, for instance); one that spans several files loads whole. A chapter that ships `<chapter_name>.ports.hecksagon` (the ports it declares, a `Hecks.hecksagon` block that merges into the attaching one) and `adapters/*.adapter` (the adapters that bind them) brings those too. A name the gem does not carry refuses with a `WiringError` that lists the names it does and says how to attach a vendored package:

```ruby
Hecks::Chapters.table.keys.sort  # => ["Adapter", "Bluebook", "Compliance", "ConsoleSettings", "Deploy", "Expression", "Governance", "Hecksagon", "Identity", "Paging", "Port", "Privacy", "QualityControl", "Site", "Tenancy", "Tickets", "Translation", "World"]
```

With `from: :vendor`, the name is a separate, independently-versioned package (`embryonaut_bluebooks`) vendored into the *consuming project's own checkout*: `<registry.root>/vendor/embryonaut_bluebooks/<name>/bluebook/`, resolved from the real registry's own root rather than a fixed constant, since there is no fixed answer until a real project (and its root) exists. It loads every `.bluebook` file the package declares, sorted, so a package spanning several files that reopen the same chapter loads in a stable order. `from: :vendor` is never a fallback: a vendored name written without it is not found among the chapters the gem carries and refuses, so a typo cannot silently pick a vendored package over a gem chapter.

The attachment is recorded on the hecksagon that asked for it, with its source:

```ruby
runtime.registry.hecksagon("Banking").attachments.map { |a| [a.name, a.source] }  # => [["Governance", :gem]]
```

And its chapter is really loaded: `Governance` is a domain in this registry now, dispatchable like any other, though nothing in `banking.bluebook` mentions it:

```ruby
runtime.registry.bluebook("Governance").aggregates.map(&:hecks_name).sort  # => ["RoleAssignment", "RoleTransition"]
```

Outside a real, rooted project (the doctest registry above, say) there is nowhere to vendor from, and `from: :vendor` refuses rather than silently finding nothing:

```ruby
Hecks.hecksagon("Widgets") { attaches "payments", from: :vendor }  # ~> WiringError: needs a registry with a root to vendor from
```

The Hecks domain (ADR 0080) is the main user of the gem form, attaching the language, Tenancy, Deploy, Site and QualityControl so one `hecks` launcher reaches all of their verbs. The QA ledger (`qa/bluebook/`) loads QualityControl by name with `Hecks::Chapters.load!("QualityControl")` and binds it to its own PostgresEra database.

## uses_framework

<!-- generated:begin word=uses_framework -->
`uses_framework attachments` — fills `attachments`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | attachments |
<!-- generated:end -->

The deprecated spelling of `attaches "Name"` for a framework member. It behaves as before and prints a one-line warning; it is removed in 3.2.0.

```ruby
Hecks.with_registry(runtime.registry) { Hecks.hecksagon("Legacy") { uses_framework "Governance" } }  # warns: use `attaches "Governance"`
```

## uses_embryonaut_bluebook

<!-- generated:begin word=uses_embryonaut_bluebook -->
`uses_embryonaut_bluebook attachments` — fills `attachments`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | attachments |
<!-- generated:end -->

The deprecated spelling of `attaches "name", from: :vendor`. It behaves as before and prints a one-line warning; it is removed in 3.2.0.

```ruby
Hecks.hecksagon("Legacy") { uses_embryonaut_bluebook "payments" }  # ~> WiringError: needs a registry with a root to vendor from
```

### Vendoring a package

One command puts a package in that directory, pinned to a release or a commit of the registry repository (`embryonaut_bluebooks`), which the command reads from a local checkout. In this repository it is `hecks package.vendor`; the gem ships `lib/` only, so a consuming project runs the same command through its own bundle:

```sh
bundle exec ruby -rhecks -e 'exit Hecks::EmbryonautBluebook::VendorCli.run(ARGV)' payments@1.2.0 --from ../embryonaut_bluebooks
```

The argument is `<package>[@<ref>]`. Without a ref it takes the newest `<package>-v*` release tag; with `1.2.0` (or the tag name `payments-v1.2.0`) it takes that release; any other ref is a bare commit-ish. `--from` defaults to `$EMBRYONAUT_BLUEBOOKS_SRC` and `--root` (the consuming project) to the current directory. From Ruby, `Hecks::EmbryonautBluebook.vendor!(name, from:, root:, ref:)` does the same and returns what changed; the command line is a thin wrapper over it, and the exit status is 0 when the package was vendored, 1 when it was refused and 2 for a usage error.

What lands is the top-level `bluebook/*.bluebook` files of the package and nothing else: a `.hecksagon`, `.port` or `.adapter` is a wiring decision for whoever deploys, never part of the package. The whole package directory is replaced, so a file the registry dropped does not linger, and nothing on disk changes when a pin is refused or its files do not load.

```text
vendor/embryonaut_bluebooks/payments/
  VENDORED_COMMIT     the full 40-character commit id and a newline
  bluebook.lock       release pins only: package, version, tag, commit, digest, shape
  bluebook/
    payments.bluebook
```

`VENDORED_COMMIT` is written for every pin, so `git -C <registry> show <commit>:payments/bluebook` reproduces the vendored files. `bluebook.lock` is written only for a release pin, as `key: value` lines: `package`, `version`, `tag`, `commit`, `digest` (the sha256 over the `<sha256>  <name>` line of every `*.bluebook` file, sorted by name, which `bin/bluebook_digest` in the registry prints for the same release), then one `shape: <Domain> <label>` line per domain. The label is the one `hecks introspection.shape` prints, the first characters of the hash PostgresEra names an era with.

A release pin also carries two refusals, because a production project binds `PostgresEra`:

- a version lower than the vendored one is refused unless `ALLOW_DOWNGRADE=1` is in the environment;
- a change to the storage shape that raises the version by less than a minor is refused, so a new era shows in the version number and not only in a hash. The message names the shape before and after.

A release must also be a real one: the `<package>/bluebook.yml` at the tag has to say the version the tag names. A bare commit-ish pins that commit and writes only the marker, with no lock and neither check. The last line of the command reports the shape either way: unchanged (no new era on the next deploy), changed (the next deploy mints one, so write its translation edge first), or nothing earlier to compare with.

A domain that binds `PostgresEra` needs no `require "hecks/ports/persistence/plugins/era"` of its own: `Hecks.boot` resolves every adapter a hecksagon binds before it collects the boot gates, which loads the era plugin and registers its gates. Requiring the plugin by hand is only for a program that wants translation support without binding `PostgresEra`.

## port

<!-- generated:begin word=port -->
`port name do ... end` — opens a `DomainPort` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

A driving port: a second front door for a fact that didn't originate inside the domain (a payment webhook, a card terminal). Called bare, as documented here, it belongs to the chapter as a whole rather than one aggregate. The more common shape in practice is the aggregate-scoped sibling — `Pizzas::Order.port "PaymentGateway" do ... end`, the same receiver `persisted_by` already reaches (see `examples/pizzas/bluebook/pizzas.hecksagon`) — which attaches to one record's own box instead. Either way the body only admits `operation`; see the DomainPort reference page.

The aggregate-scoped form is what the boot above uses, and the port
lands on the chapter either way:

```ruby
account = runtime.registry.bluebook("Banking").aggregate("Account")
account.ports.map(&:name)  # => ["RiskFeed"]
account.ports.first.operations.map(&:hecks_name)  # => ["Flag"]
```

## translates

<!-- generated:begin word=translates -->
`translates name do ... end` — opens a `Policy` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

A translation boundary between two domains, not a business rule — the exact same `Policy` shape a `policy` block inside a `.bluebook` builds (same `on`/`trigger`, same `PolicyInterpreter` at runtime), just declared here instead, because reacting to a FOREIGN domain's event is a wiring/context-mapping decision (this chapter conforming to another chapter's published fact), the same kind of decision `port`/`attaches` already are — not something this domain's own model states about itself.

Only `on`/`trigger` are meaningful inside the block; `where`/`for_each`/`across` all still work exactly as they do inside an ordinary `policy`, since it's the identical builder underneath.

Two things to get right that are easy to get wrong: command and event references use `::` throughout (`Tenant::Register`, never `Tenant.Register`), and `on` should name the FOREIGN aggregate and event WITHOUT the domain prefix (`on Tenant::TenantProvisioned`, not `on Deploy::Tenant::TenantProvisioned`) — matching happens on event name plus the aggregate's own demodulised name only, never the domain, so a domain-qualified reference silently never matches.

```ruby boot
Hecks.bluebook "Provisioning" do
  aggregate "Tenant" do
    identified_by :id
    attribute :id, Id

    value_object "Id" do
      attribute :value, String
      invariant("an id is present") { !value.to_s.empty? }
    end

    command "Provision" do
      goal "provision a tenant, for real, elsewhere"
      attribute :id, Id
      sets :id
      emits "TenantProvisioned"
    end
  end
end

Hecks.bluebook "Tenancy" do
  aggregate "Tenant" do
    identified_by :id
    attribute :id, Id

    value_object "Id" do
      attribute :value, String
      invariant("an id is present") { !value.to_s.empty? }
    end

    command "Register" do
      goal "record that a tenant now exists"
      attribute :id, Id
      sets :id
      emits "TenantRegistered"
    end
  end
end

Hecks.hecksagon "Provisioning" do
  Provisioning::Tenant.persisted_by("Memory")
end

Hecks.hecksagon "Tenancy" do
  Tenancy::Tenant.persisted_by("Memory")

  translates "RegisterProvisionedTenant" do
    on Tenant::TenantProvisioned
    trigger Tenant::Register
  end
end
```

```ruby
runtime.dispatch("Provisioning::Tenant.Provision", to: "acme", with: { id: { value: "acme" } })
runtime.registry.repository("Tenancy", runtime.registry.bluebook("Tenancy").aggregate("Tenant")).find("acme").nil?
# => false
```

Once `Deploy::Tenant.Provision` emits `TenantProvisioned`, this reaction dispatches `Tenancy::Tenant.Register` — the two domains stay separately modeled; this is the one explicit seam where a fact from one becomes a fact in the other.

## bounded

<!-- generated:begin word=bounded -->
`bounded`
<!-- generated:end -->

A consumer-owned bounded-context mark. Framework and vendored packages
never write this word in their own files — `attaches` marks those
chapters bounded automatically.
A bounded chapter wraps in its own module (`Domain::Aggregate`) and does
not install Object shortcuts, so two BCs can both declare `Person`.

Writing `bounded` on a consumer chapter always requires a `translates`
ACL or boot refuses. Mapping lives on the hecksagon, not in rust/host.

The boot above already declared two chapters; this one reuses that
shape and marks Tenancy bounded, with the same `translates` ACL the
section above already needs:

```ruby
hexagon = runtime.registry.hecksagon("Tenancy")
hexagon.bounded?     # => false
hexagon.translates   # => ["RegisterProvisionedTenant"]
```

A chapter that *does* write it, and the ACL that lets it boot:

```ruby boot
Hecks.bluebook "BoundedThing" do
  aggregate "Thing" do
    identified_by :id
    attribute :id, Id

    value_object "Id" do
      attribute :value, String
      invariant("an id is present") { !value.to_s.empty? }
    end

    command "Fire" do
      goal "emit a fact another domain reacts to"
      attribute :id, Id
      sets :id
      emits "ThingFired"
    end
  end
end

Hecks.bluebook "BoundedEcho" do
  aggregate "Echo" do
    identified_by :id
    attribute :id, Id

    value_object "Id" do
      attribute :value, String
      invariant("an id is present") { !value.to_s.empty? }
    end

    command "Register" do
      goal "record the echo"
      attribute :id, Id
      sets :id
      emits "EchoRegistered"
    end
  end
end

Hecks.hecksagon "BoundedThing" do
  BoundedThing::Thing.persisted_by("Memory")
end

Hecks.hecksagon "BoundedEcho" do
  bounded
  BoundedEcho::Echo.persisted_by("Memory")
  translates "EchoOnThingFired" do
    on Thing::ThingFired
    trigger Echo::Register
  end
end
```

```ruby
runtime.registry.hecksagon("BoundedEcho").bounded?    # => true
runtime.registry.hecksagon("BoundedEcho").translates  # => ["EchoOnThingFired"]
runtime.registry.bounded?("BoundedEcho")              # => true
```

