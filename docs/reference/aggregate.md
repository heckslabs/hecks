# Aggregate

<!-- generated:begin id=page -->
Words available inside `aggregate do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against `examples/banking`'s `Account`, which carries
every structural word an aggregate has. `has_many` and `has_one` appear
nowhere in the corpus — `belongs_to` appears exactly once — so the
relationship sugar gets a chapter of its own:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
end
```

```ruby bluebook
Hecks.bluebook "AggregateReference" do
  vision "The three spellings of a reference, side by side."

  aggregate "Studio" do
    identified_by Name, as: :name

    value_object("Name") { attribute :value, String }

    command "Found" do
      attribute :name, Name
      sets :name, to: :name
      emits "StudioFounded"
    end
  end

  aggregate "Film" do
    identified_by Title, as: :title

    value_object("Title") { attribute :value, String }

    # THREE WORDS, THREE FIELD NAMES, ONE MECHANISM. `reference_to`
    # mints `studio_id`; the other two drop the suffix; and `has_many`
    # singularises rather than minting a list.
    reference_to Studio, as: :financier
    has_one  Studio, as: :distributor
    has_many Studio, as: :backers

    command "Greenlight" do
      attribute :title, Title
      attribute :financier_id,   Studio
      attribute :distributor,    Studio, optional: true
      attribute :backers,        Studio, optional: true
      sets :title, to: :title
      emits "FilmGreenlit"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("AggregateReference") do
  AggregateReference::Studio.persisted_by("Memory")
  AggregateReference::Film.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "ag-1" },
                 name: { given: "Jean", family: "Bartik" },
                 email: { address: "jean@example.com" })
account = Banking::Account.open(customer_id: "ag-1", number: { value: "ag-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the aggregate — no rules attached, read by nothing but a human.

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").description  # => "A balance belonging to one customer, and the ledger that explains how it got there."
```

## provenance

<!-- generated:begin word=provenance -->
`provenance from:` — fills `provenance`

| argument | kind | required | fills |
|---|---|---|---|
| `from:` | literal | true | provenance |
<!-- generated:end -->

Where this concept came from, when it was adopted from somewhere else rather
than invented here — a canonical library, an upstream spec, a prior domain.
Captured as a raw Hash, untouched, the same way `attribute ..., default:`
captures one: `provenance from: { source: "...", source_id: "...", source_version: "..." }`.
It never touches dispatch, identity, or any rule — nothing reads it but a
human, or future tooling built to reconcile a domain against the source it
was adopted from.

`Account` is the corpus's own adopted concept:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").provenance[:source]  # => "HecksCanonical"
```

Raw and unread — nothing coerces the Hash, so nothing refuses it either:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").provenance[:source_id]  # => "aggregate:account"
```

## identified_by

<!-- generated:begin word=identified_by -->
`identified_by identified_by, type, as: do ... end` / `identified_by identified_by, type, as:` — fills `identified_by`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | false | identified_by |
| positional 1 | constant | false | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Names which unchanging field or fields say which record this is — a single path (`{ tag.value }`) reads back exactly as written, and several paths, one per line, join in declaration order (`"north:3"`). The block is never called; its source is read the same way a `given`'s is, so a path names a field with no method behind it required. Get this wrong and the aggregate either builds CRUD around something that was never more than a number, or lets two genuinely different records collide because nothing told the runtime how to tell them apart — the second `Establish` against an existing identity refuses as a duplicate, not a fresh record.

`Account` is `identified_by AccountNumber, as: :number`, so the number
IS the record's identity — not a field beside it:

```ruby
account.id  # => "ag-a1"
```

Opening a second account on the same number refuses as a duplicate
rather than quietly replacing the first:

```ruby
Banking::Account.open(customer_id: "ag-1", number: { value: "ag-a1" }, kind: { name: "savings" }, daily_limit: { cents: 1 })  # ~> AlreadyExists: Account
```

A composite identity joins its paths in declaration order —
`SafeDepositBox` is `branch_code.value` then `box_number.value`:

```ruby
runtime.registry.bluebook("Banking").aggregate("SafeDepositBox").identity_heads  # => [:branch_code, :box_number]
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:, optional:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Points at another aggregate by id, not by object — the attribute holds a bare id string, and handing it a nested value instead is refused at the door. Mints an attribute named `target_id` by default, or whatever `as:` names.

`Account` references `Customer`, so it carries a `customer_id` holding a
bare id — not a nested customer:

```ruby
account.customer_id  # => "ag-1"
```

Handing it the object instead is refused where it arrives:

```ruby
Banking::Account.open(customer_id: { value: "ag-1" }, number: { value: "ag-a3" }, kind: { name: "current" }, daily_limit: { cents: 1 })  # ~> TypeMismatch: a reference is an id
```

One direction only: if the target aggregate also references this one back, the bluebook refuses to build (`BluebookBuilder#validate_no_bidirectional_references!`, raises `Malformed`) — two aggregates pointing at each other means neither is a boundary a caller can reason about alone. `has_many`/`has_one`/`belongs_to` below are sugar over this same call and are held to the same rule.

## has_many

<!-- generated:begin word=has_many -->
`has_many type, as:, optional:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Sugar over `reference_to` — despite the plural name and plural argument, it singularizes its target and mints one scalar reference, not a list. A `has_many Studios` field reads `nil` until set, never `[]`; this language has no direct spelling for a real one-to-many yet, and reaching for `has_many` to get one just hides the gap.

That is worth seeing rather than taking on trust. `Film` declares
`has_many Studio, as: :backers`, and what lands is one scalar field:

```ruby
runtime.dispatch("AggregateReference::Studio.Found", name: { value: "Pinewood" })
film = AggregateReference::Film.greenlight(title: { value: "The Reference" }, financier_id: "Pinewood")
film.backers  # => nil
```

Not `[]`, and not a collection — a second studio cannot be added to it,
because there is nowhere for a second one to go.

## has_one

<!-- generated:begin word=has_one -->
`has_one type, as:, optional:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Sugar over `reference_to` that drops the `_id` suffix, so the field reads as a relationship (`studio`, not `studio_id`).

The suffix is the whole difference. `Film` declares all three against
the same target, and only the plain `reference_to` keeps `_id`:

```ruby
AggregateReference::Film.greenlight(title: { value: "Two" }, financier_id: "Pinewood", distributor: "Pinewood").distributor  # => "Pinewood"
```

## belongs_to

<!-- generated:begin word=belongs_to -->
`belongs_to type, as:, optional:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

An alias for `has_one` — same attribute, same `_id`-less naming, whichever name reads better at the call site.

`OnboardingCase` is the corpus's one use, and it reads as the
relationship it is — `customer`, not `customer_id`:

```ruby
kase = Banking::OnboardingCase.open(customer: "ag-1", reference: { value: "ag-c1" }, account_number: { value: "ag-a2" })
kase.customer  # => "ag-1"
```

## lifecycle

<!-- generated:begin word=lifecycle -->
`lifecycle state_field, default: do ... end` — fills `state_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | state_field |
| `default:` | literal | true | state_start |
<!-- generated:end -->

Opens a body of `transition` declarations naming the states this aggregate may hold and the moves between them. See the Lifecycle context page for the transition vocabulary in full.

The field named here is the one every transition moves, and it starts at
`default:` without any command setting it:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").lifecycle.field  # => :status
account.status  # => "open"
```

## entity

<!-- generated:begin word=entity -->
`entity name do ... end` — opens a `Entity` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a piece owned by this aggregate, with its own commands and lifecycle. See the Entity context page.

`Account` owns `LedgerEntry` — pieces with their own identity that have
no life outside the account holding them:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").entities.map(&:hecks_name)  # => ["LedgerEntry"]
```

## query

<!-- generated:begin word=query -->
`query name do ... end` — opens a `Query` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a read over this aggregate's own fields. See the Query context page for `where`, ordering, and the dotted-path rules.

Declared here, dispatched as `Domain::Aggregate.query_name`:

```ruby
runtime.query("Banking::Account.Open").map { |row| row[:number][:value] }  # => ["ag-a1"]
```

## policy

<!-- generated:begin word=policy -->
`policy name do ... end` — opens a `Policy` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a reaction owned by this aggregate. See the Policy context page.

`Account` owns one. Where a policy is written is a readability decision
— it still lands on the chapter alongside the top-level ones:

```ruby
runtime.registry.bluebook("Banking").policies.map(&:name).first  # => "ReviewOnFreeze"
```

## value_object

<!-- generated:begin word=value_object -->
`value_object name do ... end` — opens a `ValueObject` body, fills `value_objects`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a type with no identity of its own, carrying its `attribute`s and `invariant`s wherever it is used. See the ValueObject context page for the full vocabulary.

`Account` declares eight, and they are types rather than records —
nothing addresses one:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").value_objects.map(&:hecks_name).first(3)  # => ["AccountNumber", "CustomerStanding", "CustomerReference"]
```

## command

<!-- generated:begin word=command -->
`command name do ... end` — opens a `Command` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens what this aggregate may be asked to do — what it needs, what it refuses, and what it emits. See the Command context page for the full vocabulary.

Each one becomes a verb on the door, creating or acting depending on
what it references:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").commands.map(&:hecks_name).first(4)  # => ["Open", "Credit", "Debit", "FreezeAccount"]
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| positional 2 | text | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

Declares a field, scalar or value object. `pattern:` checks a String attribute against a regex the moment the bluebook loads, not the day a bad value reaches production — and only admits regexes every engine reads identically (no lookahead, no `\d`/`\w`). `admits:` points a field at a closed vocabulary declared elsewhere (a `one_of` on another value object) rather than restating its members, so two fields can't drift out of sync on what's allowed. `default:` fills the field when the record is built; for a value-object-typed attribute the default must fill that type's own fields (`default: { cents: 0 }`), not a bare scalar — a bare scalar loads cleanly and then refuses every create at dispatch. `optional:` lets a caller omit the argument entirely with no refusal, distinct from `default:`, which still fills the field either way.

`Account`'s own fields are value objects and a list, and each starts
where its type says rather than at `nil`:

```ruby
account.balance.cents  # => 0
account.ledger  # => []
```

`default:` fills the field whether or not the caller named it —
`Money`'s currency is never passed anywhere above:

```ruby
account.balance.currency  # => "USD"
```

`pattern:` is checked where the value arrives. `CustomerNumber` requires
a non-blank string, so a blank one is refused rather than stored:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: " " }, name: { given: "A", family: "B" }, email: { address: "a@b.co" })  # ~> TypeMismatch: must match
```

`admits:` points at a vocabulary declared elsewhere instead of restating
it — `ExternalTransfer.Request` admits `Account::LedgerDirection`, so
the two cannot drift:

```ruby
runtime.registry.bluebook("Banking").aggregate("ExternalTransfer").commands.find { |c| c.hecks_name == "Request" }.attributes.find { |a| a.name == :direction }.admits  # => "Account::LedgerDirection"
```

`optional:` is the one that lets a caller say nothing at all —
`SafeDepositBox.LogVisit`'s note, omitted here without refusal:

```ruby
box = Banking::SafeDepositBox.rent(customer_id: "ag-1", branch_code: { value: "DT" }, box_number: { value: 9 }, size: { value: "small" })
box.log_visit(date: { value: "2026-08-14" }, sequence: { value: 1 }).visits.size  # => 1
```

