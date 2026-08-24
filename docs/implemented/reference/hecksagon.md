# Hecksagon

<!-- generated:begin id=page -->
Words available inside `hecksagon do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

All three words are wiring, so they run against `examples/banking` with
a hecksagon written here rather than the one the example ships:

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

