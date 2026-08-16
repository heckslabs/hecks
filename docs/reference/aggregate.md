# Aggregate

<!-- generated:begin id=page -->
Words available inside `aggregate do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against `examples/banking`'s `Account`, which carries
every structural word an aggregate has. Each generated table's `fills`
column names the IR field the argument's value lands in — worth
knowing if you're reading the runtime, safe to ignore if you're just
writing a bluebook.

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  persisted_by("Memory")
end
```

```ruby bluebook
Hecks.bluebook "AggregateReference" do
  vision "A film financed by one studio, and possibly distributed by another — as: is what tells the two references apart."

  aggregate "Studio" do
    attribute :name, Name

    identified_by :name
    value_object("Name") { attribute :value, String }

    # `attribute :name, Name` IS OMITTED HERE, ON PURPOSE — a bare `sets
    # :name` already says `Found` takes a `:name` argument, and `Studio`
    # itself already declares `attribute :name, Name`, so the command
    # imports it verbatim rather than retyping it (see command.md's own
    # `attribute` section for the full rule).
    command "Found" do
      sets :name
      emits "StudioFounded"
    end
  end

  aggregate "Film" do
    attribute :title, Title

    identified_by :title
    value_object("Title") { attribute :value, String }

    # ONE WORD, ONE MECHANISM. `reference_to` mints the bare target
    # name (`studio`, no `_id`) by default, or whatever `as:` names —
    # the same field either way, so two references to the same target
    # need `as:` to tell them apart.
    reference_to Studio, as: :financier
    reference_to Studio, as: :distributor

    command "Greenlight" do
      attribute :financier,      Studio
      attribute :distributor,    Studio, optional: true
      sets :title
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

Two references to the same target need `as:` to tell them apart —
`financier` and `distributor` are both `Studio`, distinct only because
each names its own `as:`:

```ruby
big   = AggregateReference::Studio.found!(name: { value: "Big Studio" })
indie = AggregateReference::Studio.found!(name: { value: "Indie Circuit" })
film  = AggregateReference::Film.greenlight!(title: { value: "Debut" }, financier: big.id, distributor: indie.id)
film.financier.id    # => "Big Studio"
film.distributor.id  # => "Indie Circuit"
```

```ruby
Banking::Customer.register!(reference: "ag-1",
                           name: { given: "Jean", family: "Bartik" },
                           email: "jean@example.com")
account = Banking::Account.open!(customer: "ag-1", number: "ag-a1",
                                kind: "current", daily_limit: 50_000)
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
Banking::Account.ir.description  # => "A balance belonging to one customer, and the ledger that explains how it got there."
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
Banking::Account.ir.provenance[:source]  # => "HecksCanonical"
```

Raw and unread — nothing coerces the Hash, so nothing refuses it either:

```ruby
Banking::Account.ir.provenance[:source_id]  # => "aggregate:account"
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

Names which already-declared field or fields say which record this is — one bare field (`:tag`) points at a single-field value object and its path is derived (`tag.value`); several, one per argument, join in declaration order, the composite form demonstrated below.

A bare scalar or a reference resolves to its own name unchanged, since there is nothing to unwrap.

Get this wrong and the aggregate either builds CRUD around something that was never more than a number, or lets two genuinely different records collide because nothing told the runtime how to tell them apart — a second creating command against an existing identity refuses as a duplicate, not a fresh record, demonstrated below.

`Account` declares `attribute :number, AccountNumber` and then
`identified_by :number`, so the number IS the record's identity — not
a field beside it:

```ruby
account.id  # => "ag-a1"
```

Opening a second account on the same number refuses as a duplicate
rather than quietly replacing the first:

```ruby
Banking::Account.open!(customer: "ag-1", number: "ag-a1", kind: "savings", daily_limit: 1)  # ~> AlreadyExists: Account
```

A composite identity joins its paths in declaration order —
`SafeDepositBox` is `branch_code.value` then `box_number.value`:

```ruby
Banking::SafeDepositBox.ir.identity_heads  # => [:branch_code, :box_number]
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

Points at another aggregate by id, not by object — the STORED field holds a bare id string, and handing it a nested value instead is refused at the door. Mints an attribute named for the target's own bare name by default (`customer`, no `_id`), or whatever `as:` names. The door's own accessor of the same name hydrates it — reads the bare id and finds the record it names — which is why a reference needs no separate "get me the real one" method.

`film` (above) points at `Studio` twice — `as:` is the only thing that
kept `financier` and `distributor` from colliding on the same field:

```ruby
film.financier.id    # => "Big Studio"
film.distributor.id  # => "Indie Circuit"
```

`Account` references `Customer`; the raw id lives under the same name in
state, and the accessor hydrates it into the real record:

```ruby
account[:customer]     # => "ag-1"
account.customer.id    # => "ag-1"
```

Handing it the object instead is refused where it arrives:

```ruby
Banking::Account.open!(customer: { value: "ag-1" }, number: "ag-a3", kind: "current", daily_limit: 1)  # ~> TypeMismatch: a reference is an id
```

One direction only: if the target aggregate also references this one back, the bluebook refuses to build (`BluebookBuilder#validate_no_bidirectional_references!`, raises `Malformed`) — two aggregates pointing at each other means neither is a boundary a caller can reason about alone. `has_many`/`has_one`/`belongs_to` below are GONE — `reference_to` covers everything they did.

## has_many

<!-- generated:begin word=has_many -->
`has_many type, as:, optional:` — fills `attributes`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

GONE — see `reference_to` above, which mints the same bare, `_id`-less name on its own now, so the sugar had no work left. It also LIED while it existed: despite the plural name and plural argument it singularised its target and minted one scalar, not a list, so a `has_many Studios` field read `nil` until set and never `[]`. Refuses live, unconditionally:

```ruby
Hecks.bluebook("BackersGone") { aggregate("Studio") { identified_by :name; attribute :name, StudioName; value_object("StudioName") { attribute :value, String } }; aggregate("Film") { identified_by :title; attribute :title, Title; value_object("Title") { attribute :value, String }; has_many Studio } }  # ~> Malformed: has_many is gone
```

## has_one

<!-- generated:begin word=has_one -->
`has_one type, as:, optional:` — fills `attributes`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

GONE — see `reference_to` above; it existed only to drop the `_id` suffix `reference_to` used to mint by default, and `reference_to` drops it on its own now. Refuses live:

```ruby
Hecks.bluebook("DistributorGone") { aggregate("Studio") { identified_by :name; attribute :name, StudioName; value_object("StudioName") { attribute :value, String } }; aggregate("Film") { identified_by :title; attribute :title, Title; value_object("Title") { attribute :value, String }; has_one Studio } }  # ~> Malformed: has_one is gone
```

## belongs_to

<!-- generated:begin word=belongs_to -->
`belongs_to type, as:, optional:` — fills `attributes`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

GONE — an alias for `has_one` above (see `reference_to` for what replaced both), gone for the same reason. `OnboardingCase` was the corpus's one use; it now spells the same relationship with `reference_to Customer`, and reads `customer`, not `customer_id`:

```ruby
kase = Banking::OnboardingCase.open!(customer: "ag-1", reference: "ag-c1", account_number: "ag-a2")
kase[:customer]  # => "ag-1"
```

Written the retired way, it refuses:

```ruby
Hecks.bluebook("CaseGone") { aggregate("Customer") { identified_by :name; attribute :name, N; value_object("N") { attribute :value, String } }; aggregate("Case") { identified_by :ref; attribute :ref, R; value_object("R") { attribute :value, String }; belongs_to Customer } }  # ~> Malformed: belongs_to is gone
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
Banking::Account.ir.lifecycle.field  # => :status
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
Banking::Account.ir.entities.map(&:hecks_name)  # => ["LedgerEntry"]
```

## query

<!-- generated:begin word=query -->
`query name do ... end` — opens a `Query` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a read over this aggregate's own fields. See the Query context page for `where`, ordering, and the dotted-path rules.

Declared here, dispatched as `Domain::Aggregate.query_name` through
`runtime.query`, or as a bare door method of the same snake_case name.
`Account` declares a QUERY named "Open" alongside its CREATING command
of the same name, and the two never collide: a command's own door
method always ends in `!` (`open!` created the `account` this page has
been using throughout), leaving the bare name free for the query:

```ruby
runtime.query("Banking::Account.Open").map { |row| row[:number][:value] }  # => ["ag-a1"]
Banking::Account.open.map { |row| row[:number][:value] }                  # => ["ag-a1"]
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
Banking::Account.ir.value_objects.map(&:hecks_name).first(3)  # => ["AccountNumber", "DailyLimit", "LedgerSequence"]
```

## command

<!-- generated:begin word=command -->
`command name, from: do ... end` — opens a `Command` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `from:` | literal | false | from |
<!-- generated:end -->

Opens what this aggregate may be asked to do — what it needs, what it refuses, and what it emits. See the Command context page for the full vocabulary.

Each one becomes a verb on the door, creating or acting depending on
what it references:

```ruby
Banking::Account.ir.commands.map(&:hecks_name).first(4)  # => ["Open", "Credit", "Debit", "FreezeAccount"]
```

`from:` — a single state or an array of them — is a lifecycle guard,
checked against THIS aggregate's own `lifecycle` field right after
every `given` on the command already has. It replaces what used to be
a free-text `given("the account is open") { status == "open" }`,
typed out fresh (and worded inconsistently) on command after command:
naming the legal state checks it against the real state machine, where
the free-text version could drift out of sync with it and did. It
never transitions anything itself — no target state, nothing
`step_advance_lifecycle` ever sees — so a command can carry `from:`
with no matching `transition` at all:

```ruby
account_ir = Banking::Account.ir
account_ir.commands.find { |c| c.hecks_name == "Debit" }.from        # => "open"
account_ir.commands.find { |c| c.hecks_name == "CloseAccount" }.from # => ["open", "frozen"]
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, default:, optional:, pattern:, admits:, one_of:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | true | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
| `one_of:` | list | false | one_of |
<!-- generated:end -->

Declares a field, scalar or value object.

`pattern:` checks a String attribute against a regex the moment the bluebook loads, not the day a bad value reaches production — and only admits regexes every engine reads identically (no lookahead, no `\d`/`\w`).

`admits:` points a field at a closed vocabulary declared elsewhere (a `one_of` on another value object) rather than restating its members, so two fields can't drift out of sync on what's allowed.

`default:` fills the field when the record is built; for a value-object-typed attribute the default must fill that type's own fields (`default: { cents: 0 }`), not a bare scalar — a bare scalar loads cleanly and then refuses every create at dispatch. `optional:` lets a caller omit the argument entirely with no refusal, distinct from `default:`, which still fills the field either way.

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
Banking::Customer.register!(reference: " ", name: { given: "A", family: "B" }, email: "a@b.co")  # ~> TypeMismatch: must match
```

`admits:` points at a vocabulary declared elsewhere instead of restating
it — `ExternalTransfer.Request` admits `Account::LedgerDirection`, so
the two cannot drift:

```ruby
Banking::ExternalTransfer.ir.commands.find { |c| c.hecks_name == "Request" }.attributes.find { |a| a.name == :direction }.admits  # => "Account::LedgerDirection"
```

`optional:` is the one that lets a caller say nothing at all —
`SafeDepositBox.LogVisit`'s note, omitted here without refusal:

```ruby
box = Banking::SafeDepositBox.rent!(customer: "ag-1", branch_code: { value: "DT" }, box_number: { value: 9 }, size: { value: "small" })
box.log_visit!(date: { value: "2026-08-14" }, sequence: { value: 1 }).visits.size  # => 1
```

A value-object-typed attribute whose OWN declared type carries exactly
one field accepts a bare scalar in place of the wrapped `{ field: ...
}` shape — the same unwrap `identified_by` already gets (see above).
`size` above is `Size { value }`, one field, so the bare spelling
dispatches identically:

```ruby
Banking::SafeDepositBox.rent!(customer: "ag-1", branch_code: { value: "DT" }, box_number: { value: 10 }, size: "small").size.value  # => "small"
```

A genuinely multi-field value object still refuses the bare form —
`Money` (`cents`, `currency`) needs both, so this narrows nothing
`pattern:`/`admits:`/`one_of:` above already refuse:

```ruby
runtime.dispatch("Banking::Account.Credit", number: "ag-a1", amount: 100, narrative: "Deposit")  # ~> TypeMismatch: pass its fields as an object
```

## invariant

<!-- generated:begin word=invariant -->
`invariant description do ... end` — fills `invariants`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A rule that travels with the AGGREGATE, not with any one command — the
same word `value_object` already carries (see value_object.md), moved
up a level so it guards the settled record as a whole rather than one
value object's own fields. Checked at the same point a value object's
own `invariant` is: after every command that runs against this
aggregate, right before `save`, reading no `args` and no `old` the way
`ensures` does — just whatever the mutation actually left behind.

`Account` declares one. Six different commands can move `:balance` —
`Credit`, `Debit`, `ApplyFee`, `CorrectFee`, `AccrueInterest`,
`CorrectInterest` — and rather than guard each one with its own
`given` or `ensures` (worded three different ways before this, and
missing outright on the three that only ever increase it), the rule
that the balance never goes negative is declared once, on the
aggregate, and checked after every one of them:

```ruby
Banking::Account.ir.invariants.map(&:description)  # => ["the balance never goes negative"]
```

## given

<!-- generated:begin word=given -->
`given description do ... end` — fills `preconditions`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

Declares a NAMED precondition directly on the aggregate — block
required here, exactly one canonical predicate per description, stored
under that description rather than attached to any one command. A
command's OWN `given(description)`, with no block of its own, then
reads back the aggregate's predicate of that name instead of
re-declaring it — same enforcement point, same `GivenNotMet` refusal,
worded identically no matter which command a caller hits. Declare it
before the commands that reference it: resolution happens at the
referencing command's own build time, against whatever the aggregate
has declared so far — the one ordering rule this word carries that
`identified_by`/`attribute` do not.

`Account` declares two — `"customer is active"` and `"customer is not
closed"` — and most of its own commands read one back rather than
retyping the predicate:

```ruby
account_ir = Banking::Account.ir
account_ir.preconditions.map(&:description)  # => ["customer is active", "customer is not closed"]
account_ir.commands.find { |c| c.hecks_name == "Credit" }.givens.map(&:description)  # => ["customer is active"]
```

A referencing command's own `given` carries the SAME canonical
predicate the aggregate declared, not a copy — one description, one
refusal message, everywhere it's read:

```ruby
account_ir.commands.find { |c| c.hecks_name == "FreezeAccount" }.givens.map(&:canonical)  # => ["customer.status != \"closed\""]
```

## projects

<!-- generated:begin word=projects -->
`projects name, from:` — fills `projected_fields`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| `from:` | symbol | true | from |
<!-- generated:end -->

A FIELD READ THROUGH A REFERENCE, HELD LOCALLY — the boundary rule's
whole point is that a `given`/`ensures`/`invariant` should never reach
across a `reference_to` at rule-evaluation time to ask another
aggregate a live question. `projects` is the alternative: `from:` names a dotted
path — the LOCAL reference attribute to read through, then the SCALAR
field on the target to copy — and the copy lands under `name` on this
aggregate's own record, kept fresh by an explicit rebuild sweep
(`Runtime::RebuildSweep`) rather than read on every dispatch.

`from:` is checked in two tiers, the same way a query's own hop is.
Declaring it checks the LOCAL half immediately — `reference` must name
a real `reference_to` this aggregate actually declares, never a value
object or a plain attribute:

```ruby
Hecks.bluebook("Bad") { aggregate("Widget") { identified_by :id; projects :owner_status, from: :status } }  # ~> Malformed: reference.field
```

The TARGET half resolves once every aggregate in the chapter is real
— `remote_field` must land on a real scalar there, never a reference,
a value object, or a list (`BluebookBuilder#validate_projected_fields!`,
checked alongside `validate_query_hops!`). `Account` and
`SafeDepositBox` each declare one, both reading the same remote field
through their own independent `reference_to Customer`:

```ruby
banking = runtime.registry.bluebook("Banking")
banking.aggregate("Account").projected_fields.map { |f| [f.name, f.reference, f.remote_field] }        # => [[:customer_status, :customer, :status]]
banking.aggregate("SafeDepositBox").projected_fields.map { |f| [f.name, f.reference, f.remote_field] }  # => [[:customer_status, :customer, :status]]
```

A record that predates the declaration, or that no sweep has yet
reached, reads as genuinely absent rather than as a stale guess — a
`given`/`ensures`/`invariant` that reads a projected field before it
has ever been swept refuses with `ProjectionAbsent`, the same shape
`AttributeAbsent` already gives an ordinary field nobody backfilled.
Neither of banking's own two declarations is wired into a real rule
yet — Account and SafeDepositBox both still check `customer.status`
live, the way every `given("customer is active")` in this corpus
always has — so the sweep, and the refusal it guards against, are
demonstrated directly instead: `spec/runtime/rebuild_sweep_spec.rb`
declares a small dedicated fixture, dispatches into it, and shows a
guard refuse with `ProjectionAbsent` before a sweep runs, then reads
the swept value cleanly after.

