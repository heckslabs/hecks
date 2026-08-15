# Entity

<!-- generated:begin id=page -->
Words available inside `entity do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Six of these seven run against `examples/banking`'s `LedgerEntry` — the
movements inside an `Account`, which have their own identity, their own
state machine and their own commands, but no life apart from the account
holding them. `reference_to` appears on no entity anywhere in the corpus,
so it gets a small chapter of its own further down.

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end
```

```ruby bluebook
Hecks.bluebook "EntityReference" do
  vision "An entity that points at something outside the record holding it."

  aggregate "Manifest" do
    attribute :docket, Docket

    identified_by :docket
    attribute :crates, list_of(Crate)

    value_object("Docket")  { attribute :value, String }
    value_object("Handler") { attribute :value, String }
    value_object("Slot")    { attribute :value, Integer }

    entity "Crate" do
      attribute :slot, Slot

      identified_by :slot
      attribute :handler, Handler
      # THE WORD THIS CHAPTER EXISTS FOR — a crate inside one manifest,
      # naming the depot that holds it, which is its own aggregate.
      reference_to Depot
    end

    command "OpenManifest" do
      attribute :docket, Docket
      sets :docket
      emits "ManifestOpened"
    end

    command "AddCrate" do
      reference_to Manifest
      attribute :slot,     Slot
      attribute :handler,  Handler
      attribute :depot_id, Depot
      sets :crates, append: { slot: :slot, handler: :handler, depot_id: :depot_id }
      emits "CrateAdded"
    end
  end

  aggregate "Depot" do
    attribute :code, Code

    identified_by :code
    value_object("Code") { attribute :value, String }

    command "OpenDepot" do
      attribute :code, Code
      sets :code
      emits "DepotOpened"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("EntityReference") do
  EntityReference::Manifest.persisted_by("Memory")
  EntityReference::Depot.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "en-1" },
                 name: { given: "Evelyn", family: "Boyd" },
                 email: { address: "evelyn@example.com" })
account = Banking::Account.open(customer: "en-1", number: { value: "en-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
account.credit(amount: { cents: 10_000 }, narrative: { text: "opening" })
account.debit(amount: { cents: 2_500 }, narrative: { text: "groceries" })
```

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the entity — no rules attached, read by nothing but a human. Same word, same shape, as an aggregate's own `description`.

Carried on the IR, not on any record — nothing at runtime reads it:

```ruby
ledger_entry = runtime.registry.bluebook("Banking").aggregate("Account").entities.first
ledger_entry.description  # => "One movement across the account, in the order it was posted."
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

Names the field that tells one element of the list apart from another — unique within the parent, not globally, since a `FoyerTicketNumber` only has to be unambiguous inside its own counter. See entities.md for how this identity is carried alongside the parent's own when a command or query reaches through the aggregate.

`LedgerEntry` is `identified_by :sequence` (with `attribute :sequence,
LedgerSequence` declared alongside it), and the sequence only has to
be unique inside its own account — every account starts counting at
one:

```ruby
account.ledger.map { |entry| entry[:sequence][:value] }  # => [1, 2]
```

Which is why reaching one takes BOTH identities: the parent's, then the
entity's own.

## command

<!-- generated:begin word=command -->
`command name do ... end` — opens a `Command` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Same vocabulary as a command on an aggregate — see command.md — but this one never gets a door of its own: nothing installs a module for an entity, so it's reached only as `Aggregate.Entity.Command`, never independently. It also never declares `reference_to`; the parent qualifier in the dotted call already supplies both identities.

`Reverse` is `LedgerEntry`'s, not `Account`'s — addressed through the
account that holds it, and naming which entry by its own sequence:

```ruby
runtime.dispatch("Banking::Account.LedgerEntry.Reverse", number: { value: "en-a1" },
                 sequence: { value: 2 }, narrative: { text: "posted in error" })
Banking::Account.find("en-a1").ledger[1][:state]  # => "reversed"
```

The other entry is untouched — a command on one element is not a command
on the list:

```ruby
Banking::Account.find("en-a1").ledger[0][:state]  # => "posted"
```

## query

<!-- generated:begin word=query -->
`query name do ... end` — opens a `Query` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Reached the same dotted way a command is — `Aggregate.Entity.Query` — and answers across every parent that has a matching element, each row stamped with which parent it came from.

`Reversed` reads entries, not accounts — and each row says which account
it came from, under that parent's own reference key:

```ruby
rows = runtime.query("Banking::Account.LedgerEntry.Reversed")
rows.size  # => 1
rows.first[:account]  # => "en-a1"
```

## lifecycle

<!-- generated:begin word=lifecycle -->
`lifecycle state_field, default: do ... end` — fills `state_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | state_field |
| `default:` | literal | true | state_start |
<!-- generated:end -->

Opens the same `transition` vocabulary an aggregate's `lifecycle` does, checked against this entity's own state field — a `LifecycleRefused` here names the entity, never the parent. See the Lifecycle context page.

`LedgerEntry` declares `lifecycle :state, default: "posted"`, and the
entry above has already moved. Reversing it twice is refused against the
ENTRY's state — the account is still perfectly open:

```ruby
runtime.dispatch("Banking::Account.LedgerEntry.Reverse", number: { value: "en-a1" }, sequence: { value: 2 }, narrative: { text: "again" })  # ~> GivenNotMet: entry is posted
```

```ruby
Banking::Account.find("en-a1").status  # => "open"
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

Declares a field on the entity, scalar or value object — same word, same modifiers, as an aggregate's own `attribute`. See the Type and ValueObject context pages for what each type position and modifier does.

An entity's fields are its own, and they are read off the element rather
than off the parent:

```ruby
Banking::Account.find("en-a1").ledger[0][:amount][:cents]  # => 10000
Banking::Account.find("en-a1").ledger[0][:direction][:value]  # => "credit"
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Points an entity at a real ROOT, the same way an aggregate's own `reference_to` does — a `Card` entity's own `assignee_id`, pointing at a `Team`. Never at another entity: there's no cross-piece addressing anywhere in this language to resolve one against, so this only ever reaches a head.

`EntityReference`'s `Crate` is an entity inside `Manifest`, pointing at a
`Depot` — a real root of its own, not another piece:

```ruby
runtime.dispatch("EntityReference::Depot.OpenDepot", code: { value: "dp-1" })
runtime.dispatch("EntityReference::Manifest.OpenManifest", docket: { value: "mf-1" })
runtime.dispatch("EntityReference::Manifest.AddCrate", manifest: "mf-1", slot: { value: 1 },
                 handler: { value: "Ada" }, depot_id: "dp-1")
```

The reference is stored on the crate itself, one field among its own:

```ruby
EntityReference::Manifest.find("mf-1").crates.first[:depot_id]  # => "dp-1"
```

