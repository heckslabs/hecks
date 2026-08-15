# Bluebook

<!-- generated:begin id=page -->
Words available inside `bluebook do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against the corpus — `examples/banking` is `core` and
carries every structural word; `examples/pizzas` is `supporting`.
`generic` and `formerly_known_as` are declared by nothing that ships, so
they get a chapter each:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end

Hecks.hecksagon("Pizzas") { Pizzas::Order.persisted_by("Memory") }
```

```ruby bluebook
Hecks.bluebook "BluebookReference" do
  vision "Nothing anybody competes on — the kind of thing you would buy if you could."
  generic

  aggregate "Postcode" do
    attribute :code, Code

    identified_by :code
    value_object("Code") { attribute :value, String }

    command "Record" do
      attribute :code, Code
      then_set :code, to: :code
      emits "PostcodeRecorded"
    end
  end
end
```

```ruby bluebook
Hecks.bluebook "Ledgering" do
  vision "The same domain, under the name it answers to now."
  # THE OLD NAME, KEPT — a chapter that is renamed still has to be
  # findable by whatever wrote records under the name it used to have.
  formerly_known_as "Bookkeeping"

  aggregate "Folio" do
    attribute :number, Number

    identified_by :number
    value_object("Number") { attribute :value, String }

    command "OpenFolio" do
      attribute :number, Number
      then_set :number, to: :number
      emits "FolioOpened"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("BluebookReference") { BluebookReference::Postcode.persisted_by("Memory") }
Hecks.hecksagon("Ledgering") { Ledgering::Folio.persisted_by("Memory") }
```

## vision

<!-- generated:begin word=vision -->
`vision vision` — fills `vision`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | vision |
<!-- generated:end -->

A one-line statement of what the domain is for. Optional, but not empty if given — the same value-object invariant fires here as on any string field, enforced by the meta-domain that judges the bluebook itself. Stored on the chapter and readable back after boot as `Chapter.vision`.

```ruby
runtime.registry.bluebook("Pizzas").vision  # => "Put toppings on a pizza and sell it to a customer."
```

## formerly_known_as

<!-- generated:begin word=formerly_known_as -->
`formerly_known_as formerly_known_as` — fills `formerly_known_as`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | formerly_known_as |
<!-- generated:end -->

A domain's own declared identity can change. Naming what it used to be lets the storage layer recognize its own history under the old name instead of minting a brand-new lineage from nothing — a rename, once applied, bridges the journal, the sequence, every era partition, and the domain-keyed rows in `hecks_eras`/`hecks_era_texts`/`hecks_approvals`/`hecks_attestations` onto the new name, in one transaction, the first time the domain boots under it. Optional, but not empty if given — the same value-object invariant fires here as on any string field. Stored on the chapter and readable back after boot as `Chapter.formerly_known_as`; safe to leave declared permanently, since every later boot after the bridge falls through to the ordinary already-held path.

The chapter answers to its current name and remembers the old one — the
old name is a fact about this chapter, not a second chapter:

```ruby
runtime.registry.bluebook("Ledgering").formerly_known_as  # => "Bookkeeping"
runtime.registry.bluebook("Bookkeeping")  # => nil
```

Nothing about the domain's own shape depends on it:

```ruby
Ledgering::Folio.open_folio(number: { value: "f-1" }).number.value  # => "f-1"
```

## core

<!-- generated:begin word=core -->
`core` — fills `classification`
<!-- generated:end -->

Marks this chapter a core subdomain, in the DDD sense (core/supporting/generic). `core`, `supporting`, and `generic` all just set the one `classification` field, so calling more than one leaves whichever ran last — and, verified against the runtime, nothing else currently reads that field back. It documents intent; it gates nothing.

```ruby
runtime.registry.bluebook("Banking").classification  # => "core"
```

"Gates nothing" is checkable rather than promised — a `core` chapter
dispatches exactly like any other:

```ruby
Banking::Account.open(customer: "bb-1", number: { value: "bb-a1" }, kind: { name: "current" }, daily_limit: { cents: 1 })  # ~> NotFound: bb-1
```

## supporting

<!-- generated:begin word=supporting -->
`supporting` — fills `classification`
<!-- generated:end -->

Marks this chapter a supporting subdomain. Same field, same mutual exclusivity, as `core`.

```ruby
runtime.registry.bluebook("Pizzas").classification  # => "supporting"
```

## generic

<!-- generated:begin word=generic -->
`generic` — fills `classification`
<!-- generated:end -->

Marks this chapter a generic subdomain — undifferentiated, off-the-shelf territory in the DDD sense. Same field as `core`.

```ruby
runtime.registry.bluebook("BluebookReference").classification  # => "generic"
```

## aggregate

<!-- generated:begin word=aggregate -->
`aggregate name do ... end` — opens a `Aggregate` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens the thing with identity in this domain — `identified_by`, its `attribute`s, `command`s, and lifecycle. See the Aggregate reference page for the full vocabulary inside.

Every aggregate a chapter opens becomes a door of its own, named after
the chapter:

```ruby
runtime.registry.bluebook("Banking").aggregates.map(&:hecks_name).first(3)  # => ["Customer", "Account", "ATMCard"]
BluebookReference::Postcode.record(code: { value: "N1" }).code.value  # => "N1"
```

## report

<!-- generated:begin word=report -->
`report name do ... end` — opens a `ReadModel` body, was `read_model`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a read that gathers heads from several aggregates around one spine — declared at the chapter's own top level, not under any single aggregate, because no one aggregate owns it. See the ReadModel reference page for `reference_to`/`include` and the rest. Spelled `read_model` in every bluebook written before this word's rename — that spelling still boots, forever; `report` is the SME-facing word going forward.

Banking declares five, and they sit on the chapter rather than under any
aggregate — which is the whole reason the word exists at this level:

```ruby
runtime.registry.bluebook("Banking").read_models.map(&:hecks_name)  # => ["CustomerPortfolio", "ComplianceDashboard", "DisputedPaymentCount", "DisputedPaymentMedian", "AccountsByKind"]
```

## policy

<!-- generated:begin word=policy -->
`policy name do ... end` — opens a `Policy` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

The same word as inside an `aggregate` — a reaction to an event, `on`/`trigger` — but written here at the chapter's top level for a policy that isn't one aggregate's own business. Pizzas' `OnPizzaPaymentReceived` (examples/pizzas/bluebook/pizzas.bluebook) is a real example: it triggers `Order.Purchase` but is declared beside the aggregate, not inside it. See the Policy reference page.

Banking declares four here and two inside aggregates, and they all land
in the same place — where a policy was WRITTEN is a readability decision,
not a structural one:

```ruby
runtime.registry.bluebook("Banking").policies.map(&:name)  # => ["ReviewOnFreeze", "RetryOnPaymentFailure", "FreezeAccountsOnSuspension", "NotifyOnClosure", "ReviewOnBoxSurrender", "FlagKeyReturn"]
```

The first two of those are `Account`'s and `ScheduledPayment`'s own,
declared inside them; the rest are the chapter's.

## process_manager

<!-- generated:begin word=process_manager -->
`process_manager name do ... end` — opens a `ProcessManager` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a stateful saga spanning several events and commands — `correlates_by`, `starts_on`/`ends_on`, its `handler`s. Chapter-level only, like `report` and top-level `policy`, since it belongs to no single aggregate. See the ProcessManager reference page.

```ruby
runtime.registry.bluebook("Banking").process_managers.map(&:name)  # => ["Settlement", "ExternalSettlement", "Onboarding"]
```

