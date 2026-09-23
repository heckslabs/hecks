# Hecksagon

<!-- generated:begin id=page -->
Words available inside `hecksagon do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

`port`, `subscribe`, and `uses_framework` are wiring, so they run against
`examples/banking` with a hecksagon written here rather than the one the
example ships. `translates` and `bounded` get their own small boot further
down — they need two cooperating domains, which this page's own Banking
boot never declares two of:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
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
`subscribe "X.*"` nor `uses_framework "X"`) is a real, static finding
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
# (which only runs inside a boot) — no subscribe, no uses_framework, so
# Compliance goes unacknowledged.
unacknowledging = Hecks::Bluebook::Hecksagon.new(domain: "Banking")
findings = Hecks::Bluebook::ModelCheck.call(banking, hecksagon: unacknowledging)
findings.find { |f| f.subject == compliance_policy.name }.kind  # => :unacknowledged_relationship
```

See `docs/implemented/reference/policy.md`'s own `## across` section for
the other half — `uses_framework` and `across` on the SAME target
(`:contradictory_relationship`) — and the model-checker's own file for
why this needs no new keyword at all.

## uses_framework

<!-- generated:begin word=uses_framework -->
`uses_framework framework_members` — fills `framework_members`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | framework_members |
<!-- generated:end -->

Names a `lib/hecks/framework/bluebook/` member this domain wants attached — `uses_framework "Governance"`, say. Attaching one is a deployment decision, the same kind `persisted_by`/`projected_by` already are, so it lives in the hecksagon rather than as a fact stated in the domain's own bluebook. Loads that member's own bluebook into whatever registry this one is loading into — always from its own real location, never a copy, so it keeps working even when this domain is itself copied somewhere else first (a fuzz run's isolated tmp boot, for instance). Persistence is NOT part of what this loads — a member's aggregates need their own `Hecks.hecksagon "Governance" do ... end` block, declared by whoever is attaching it, the same as any other binding decision.

The member is recorded on the hecksagon that asked for it:

```ruby
runtime.registry.hecksagon("Banking").framework_members  # => ["Governance"]
```

And its chapter is really loaded — `Governance` is a domain in this
registry now, dispatchable like any other, though nothing in
`banking.bluebook` mentions it:

```ruby
runtime.registry.bluebook("Governance").aggregates.map(&:hecks_name).sort  # => ["RoleAssignment", "RoleTransition"]
```

## uses_embryonaut_bluebook

<!-- generated:begin word=uses_embryonaut_bluebook -->
`uses_embryonaut_bluebook vendored_bluebooks` — fills `vendored_bluebooks`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | vendored_bluebooks |
<!-- generated:end -->

One level further out than `uses_framework`: not a member shipped inside hecks's own `lib/`, but a separate, independently-versioned package (`embryonaut_bluebooks`) vendored into the *consuming project's own checkout* — `<registry.root>/vendor/embryonaut_bluebooks/<name>/bluebook/`, resolved from the real registry's own root rather than a fixed constant, since there is no fixed answer until a real project (and its root) exists. Loads every `.bluebook` file the package declares, sorted, so a package spanning several files that reopen the same chapter loads in a stable order. Persistence is NOT part of what this loads, the same restriction `uses_framework` already draws — a consuming project declares its own separate `Hecks.hecksagon` block to bind the vendored aggregates' real storage.

Real, external use: `lifeadelics/domain` (a hecks-based payments/booking service, not part of this repository) vendors `embryonaut_bluebooks/payments` this way — `uses_embryonaut_bluebook "payments"` attaches a `Payment` aggregate with a full settle/refund/dispute lifecycle, shared across every project that needs one, rather than reimplemented per project.

Outside a real, rooted project — the doctest registry above, say — there is nowhere to vendor from, and it refuses rather than silently finding nothing:

```ruby
Hecks.hecksagon("Widgets") { uses_embryonaut_bluebook "payments" }  # ~> WiringError: needs a registry with a root to vendor from
```

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

A translation boundary between two domains, not a business rule — the exact same `Policy` shape a `policy` block inside a `.bluebook` builds (same `on`/`trigger`, same `PolicyInterpreter` at runtime), just declared here instead, because reacting to a FOREIGN domain's event is a wiring/context-mapping decision (this chapter conforming to another chapter's published fact), the same kind of decision `port`/`uses_framework` already are — not something this domain's own model states about itself.

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
never write this word in their own files — `uses_framework` /
`uses_embryonaut_bluebook` mark those chapters bounded automatically.
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

