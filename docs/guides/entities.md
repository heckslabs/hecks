# Entities

You have an aggregate, and it needs to hold onto a list of things that
each have to be found, changed, and refused individually — not just
appended and forgotten. Three shapes can hold a list, and picking the
wrong one is the mistake this page exists to prevent:

- No identity, no lifecycle of its own, nothing ever addresses one
  element instead of another — that's a **value object** in a
  `list_of`. A pizza's toppings, in the [getting-started guide](getting-started.md), are
  exactly this: appended, read back, never individually reached.
- Its own identity, its own commands, its own lifecycle, but it never
  makes sense apart from the thing that holds it — that's an
  **entity**. A key only exists because a bank cut it for one specific
  box; nobody looks one up without already knowing which box issued
  it.
- Identity, AND it needs to be found and acted on directly from
  outside, with no parent in the sentence — that's a separate
  **aggregate**, the way `Account`, elsewhere in this same domain,
  names `Customer` through `reference_to` rather than nesting inside
  it (see [commands.md](commands.md) for what `reference_to` does in
  full).

The middle case is the subject of this page, illustrated with
`SafeDepositBox` — the one aggregate in `examples/banking` that holds
two entities at once, with deliberately different identity shapes, so
the contrast between them is real rather than asserted.

## The declaration

`SafeDepositBox` lives in `examples/banking/bluebook/banking.bluebook`,
alongside `Customer`, `Account`, and the rest of the flagship domain.
This is the aggregate itself, quoted from that file rather than
invented for this page:

```ruby skip
aggregate "SafeDepositBox" do
  description "A steel box in the vault, held under one customer's name and opened only against the branch and number stamped on its face."

  reference_to Customer

  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber

  identified_by :branch_code, :box_number
  attribute :size,        one_of("small", "medium", "large"), default: { value: "small" }
  attribute :visits,      list_of(Visit)
  attribute :keys,        list_of(KeyIssuance)

  value_object "BranchCode" do
    attribute :value, String
    invariant("a branch is coded") { !value.to_s.empty? }
  end

  value_object "BoxNumber" do
    attribute :value, Integer
    invariant("a box is numbered from one") { value.positive? }
  end

  value_object "VisitSequence" do
    attribute :value, Integer
    invariant("a visit sequence is positive") { value.positive? }
  end

  value_object "VisitDate" do
    attribute :value, String
    invariant("a visit names its date") { !value.to_s.empty? }
  end

  value_object "VisitNote" do
    attribute :text, String
  end

  value_object "KeySerial" do
    attribute :value, String
    invariant("a key is serialed") { !value.to_s.empty? }
  end

  entity "Visit" do
    description "One opening of the box, in the order it happened that day."

    attribute :date,     VisitDate
    attribute :sequence, VisitSequence

    identified_by :date, :sequence
    attribute :note,     VisitNote, optional: true

    lifecycle :state, default: "logged" do
      transition "Annotate" => "logged", from: "logged"
    end

    command "Annotate" do
      role "Vault officer"
      goal "Note something unusual about a visit after the fact"

      attribute :date,     VisitDate
      attribute :sequence, VisitSequence
      attribute :note,     VisitNote

      then_set :note, to: :note

      emits "VisitAnnotated"
    end

    query "Recent" do
      description "The last few visits, whatever the box has seen."
      where(state: "logged")
      limit 5
    end
  end

  entity "KeyIssuance" do
    description "One key cut for the box, held by whoever last signed for it."

    identified_by :serial

    attribute :serial, KeySerial

    lifecycle :status, default: "issued" do
      transition "Return" => "returned", from: "issued"
    end

    command "Return" do
      role "Vault officer"
      goal "Take a key back when a holder is done with it"

      attribute :serial, KeySerial

      given("only an issued key is returned") { status == "issued" }

      emits "KeyReturned"
    end
  end

  lifecycle :status, default: "vacant" do
    transition "Rent"      => "rented", from: "vacant"
    transition "Surrender" => "vacant", from: "rented"
  end

  command "Rent" do
    role "Branch clerk"
    goal "Assign the box to a customer"

    reference_to Customer
    attribute :branch_code, BranchCode
    attribute :box_number,  BoxNumber
    attribute :size,        Size

    then_set :size, to: :size

    emits "BoxRented"
  end

  command "LogVisit" do
    role "Vault officer"
    goal "Record that the box was opened"

    reference_to SafeDepositBox
    attribute :date,     VisitDate
    attribute :sequence, VisitSequence
    attribute :note,     VisitNote, optional: true

    given("only a rented box is opened") { status == "rented" }

    then_set :visits, append: { date: :date, sequence: :sequence, note: :note }

    emits "BoxOpened"
  end

  command "IssueKey" do
    role "Vault officer"
    goal "Cut a key for the box"

    reference_to SafeDepositBox
    attribute :serial, KeySerial

    then_set :keys, append: { serial: :serial }

    emits "KeyIssued"
  end

  command "Surrender" do
    role "Customer"
    goal "Give the box back and take the keys off the account"

    reference_to SafeDepositBox

    given("only a rented box is surrendered") { status == "rented" }

    emits "BoxSurrendered"
    emits "KeyReturnDue"
  end
end
```

Read `entity "Visit" do ... end` and `entity "KeyIssuance" do ... end`
for what they are: blocks nested INSIDE `aggregate "SafeDepositBox"`,
at the same level a `value_object` or a `command` sits. Each gets its
own `description`, its own `identified_by`, its own `attribute`s, its
own `lifecycle`, its own `command`s — everything an aggregate declares,
in the same words. That's not a coincidence: an entity has to answer
`hecks_name`, `attributes`, `attribute`, `identified_by`, and
`lifecycle` exactly as an aggregate does, because the runtime builds
the same `Instance` wrapper around either one and hands both to the
same rule engine as `declaring`. The one thing it never answers is
`value_object` — that's the single bit the runtime reads to tell a
piece from a head, and it's how `Visit` and `KeyIssuance` get to have
an identity without being mistaken for `BranchCode` or `KeySerial`
sitting right next to them in the same aggregate.

`Visit` and `KeyIssuance` are the same shape of thing — both entities,
both nested under `SafeDepositBox` — and they were deliberately given
different identity shapes. `Visit`'s `identified_by` names two fields:
a box number repeats across branches, and within one box a visit's own
`date` repeats too, since the box may be opened twice in a day (two
visitors, or one visitor twice) — neither field alone says which
visit this is, so the identity is their join. `KeyIssuance` needs only
one: `serial.value`, because a key's own serial already says which key
it is, once you already know which box you're asking about. A single
aggregate can hold entities with composite identity, single-field
identity, or both at once — the shape is a property of the entity, not
something the parent imposes uniformly on everything it holds.

Notice what neither entity's commands declare: no `reference_to`
naming their own kind, anywhere. `Annotate` and `Return` need no
reference back to their own entity — they're addressed through the
parent, always, so there's nothing to reference. `LogVisit` and
`IssueKey`, by contrast, are commands on the AGGREGATE, and they're
the ones that grow the lists: `then_set :visits, append: { ... }` and
`then_set :keys, append: { ... }` are how a `Visit` or a `KeyIssuance`
comes into being at all. An entity is never created through its own
command — only appended by one that acts on its parent.

## Wiring

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
end
```

`Customer` is wired here too, and not incidentally: `SafeDepositBox`
declares `reference_to Customer` at the aggregate level, and `Rent`
declares it again on the command — a box cannot be rented to a
customer who does not exist yet.

## Renting a box, logging two visits

`Customer` has to exist first. Its own creating command, `Register`,
becomes a module method the same way every aggregate's does:

```ruby
customer = Banking::Customer.register(reference: { value: "CUST-0001" },
                                       name: { given: "Odile", family: "Vasseur" },
                                       email: { address: "odile@example.com" })
customer.reference.to_h   # => { value: "CUST-0001" }
```

`SafeDepositBox` is the aggregate, so `Rent` — its own creating command
— gets the same door:

```ruby
box = Banking::SafeDepositBox.rent(branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                    size: { value: "medium" }, customer_id: "CUST-0001")
box.status         # => "rented"
box.size.to_h       # => { value: "medium" }
```

`customer_id` is `reference_to Customer` minting its own argument name
— no `as:` was given, so it defaults to the target's name plus `_id`,
carrying the customer's own identity as a bare string, never a nested
object (see [aggregates-and-value-objects.md](aggregates-and-value-objects.md) for the full shape of a
reference).

Everything past `Rent` — the box's own `LogVisit`, `IssueKey`, and
`Surrender`, and both entities' commands — is reached the explicit
way, by its fully qualified verb, naming the box's whole composite
identity every time:

```ruby
runtime.dispatch("Banking::SafeDepositBox.LogVisit",
                  branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                  date: { value: "2026-01-05" }, sequence: { value: 1 })
runtime.dispatch("Banking::SafeDepositBox.LogVisit",
                  branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                  date: { value: "2026-01-05" }, sequence: { value: 2 }, note: { text: "Second visit, same day" })

box = Banking::SafeDepositBox.find("DOWNTOWN:12")
box.visits.map { |v| [v[:sequence].to_h, v[:state]] }   # => [[{ value: 1 }, "logged"], [{ value: 2 }, "logged"]]
```

`.find` takes the joined id — `"DOWNTOWN:12"`, branch and box number in
declaration order — the same shape `box.id` itself reads back as.
`visits` reads back as a plain array of hashes — one per `Visit`, each
field still a `Value` you unwrap with `.to_h`, plus the `state` the
lifecycle put there. There is no friendlier wrapper here, because a
list element was never minted a `Handle`; it lives inside its parent's
own state, exactly the way `list_of` always worked before an entity
had commands of its own.

## Addressing one visit

`Visit` gets no door. Booting installs a module for the AGGREGATE —
`Banking::SafeDepositBox` — and nothing for the entities nested inside
one. There is no `Banking::SafeDepositBox::Visit`, and no
`visit.annotate` sugar on an opening you're holding, because you are
never holding a visit on its own. You reach one the same way the
language reaches anything nested: a dotted verb, carrying every
identity in play:

```ruby
runtime.dispatch("Banking::SafeDepositBox.Visit.Annotate",
                  branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                  date: { value: "2026-01-05" }, sequence: { value: 1 },
                  note: { text: "Flagged for a follow-up" })

box = Banking::SafeDepositBox.find("DOWNTOWN:12")
box.visits.map { |v| v[:note].to_h }   # => [{ text: "Flagged for a follow-up" }, { text: "Second visit, same day" }]
```

`Domain::Aggregate.Entity.Command` — `SafeDepositBox`'s own qualifier
once, a `.` to cross into the piece (`Visit`), another `.` to name what
it does (`Annotate`). The keyword arguments carry FOUR things at once
and none of them can be skipped: `branch_code` and `box_number` find
the box (`SafeDepositBox`'s own composite `identified_by`), `date` and
`sequence` find the one visit inside it (`Visit`'s own composite
`identified_by`), and `note` is `Annotate`'s own declared argument. Get
the box right but name a visit that never happened and you get
`NotFound` naming the entity, not the box:

```ruby
runtime.dispatch("Banking::SafeDepositBox.Visit.Annotate", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 }, date: { value: "2026-01-05" }, sequence: { value: 99 }, note: { text: "x" })   # ~> NotFound: no Visit with date.value, sequence.value
```

Get the box's OWN identity wrong instead — a branch and number nothing
was ever rented under — and the runtime never gets as far as looking
at `visits` at all:

```ruby
runtime.dispatch("Banking::SafeDepositBox.Visit.Annotate", branch_code: { value: "DOWNTOWN" }, box_number: { value: 999 }, date: { value: "2026-01-05" }, sequence: { value: 1 }, note: { text: "x" })   # ~> NotFound: no SafeDepositBox with branch_code.value, box_number.value
```

Two different `NotFound`s, naming two different things, because a
dotted dispatch resolves the parent's identity before it ever looks at
the piece's.

## The refusal only the piece could make

`IssueKey` cuts a key the same way `LogVisit` logs a visit — a command
on the aggregate, appending to `keys`:

```ruby
runtime.dispatch("Banking::SafeDepositBox.IssueKey",
                  branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 }, serial: { value: "KEY-1" })
```

`KeyIssuance::Return`'s `given` reads a field off the entity's OWN
state (`status`) — not against an incoming argument this time, but
against whatever state the key is already in. `SafeDepositBox` does
not need to know whether key `KEY-1` is still out; that fact belongs
to the key. (The argument-vs-own-state variant of the same idea is two
aggregates up in this same file: `LedgerEntry.Amend` reads its own
`amount` against an incoming `adjustment`. Either way, the rule
belongs to the piece holding the field, not the aggregate that
contains it.)

```ruby
runtime.dispatch("Banking::SafeDepositBox.KeyIssuance.Return",
                  branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 }, serial: { value: "KEY-1" })

box = Banking::SafeDepositBox.find("DOWNTOWN:12")
box.keys.map { |k| k[:status] }   # => ["returned"]
```

Run the identical dispatch again and the SAME `given` refuses it —
not because the runtime remembers this particular call happened
before, but because it re-evaluates `status` against the key's current
state every time, and that state changed underneath it:

```ruby
runtime.dispatch("Banking::SafeDepositBox.KeyIssuance.Return", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 }, serial: { value: "KEY-1" })   # ~> GivenNotMet: only an issued key is returned
```

The event it would have announced never happens; the ones that already
did are still there, filed under the record they always were —
`KeyIssuance.Return` announces onto the SAME event log `SafeDepositBox`'s
own commands write to, because there is only ever one identity in play
here, the parent's:

```ruby
box.events.map(&:name)   # => ["BoxRented", "BoxOpened", "BoxOpened", "VisitAnnotated", "KeyIssued", "KeyReturned"]
```

## Asking the box about its visits

A `query` inside `entity` reaches the same way a command does — dotted,
through the aggregate — and it answers with every element that
matches, across every box that has one, each row carrying which parent
it came from:

```ruby
runtime.query("Banking::SafeDepositBox.Visit.Recent").map { |row| row.transform_values { |v| Hecksagain::Runtime::Value.materialize(v) } }  # => [{ safe_deposit_box: "DOWNTOWN:12", date: { value: "2026-01-05" }, sequence: { value: 1 }, note: { text: "Flagged for a follow-up" }, state: "logged" }, { safe_deposit_box: "DOWNTOWN:12", date: { value: "2026-01-05" }, sequence: { value: 2 }, note: { text: "Second visit, same day" }, state: "logged" }]
```

`safe_deposit_box` is not a field you declared — it's the parent's own
key, stamped onto every row so an answer spanning several boxes still
says which one each visit belongs to. `where` runs against the element
the same way it runs against a head, no different for living one level
down.

The aggregate has its own query too — `Rented`, which lists every box
currently assigned to a customer for the annual access audit. It reads
back exactly like `Customer`'s own queries do; the only thing it adds
is `authorize` and `consistency`, which are their own topic (see
[queries-and-read-models.md](queries-and-read-models.md)), not an entity concern.

## What this bought you, and what it didn't

An entity is appropriate exactly when a list needs individual
identity, individual rules, and an individual lifecycle — a visit
logged against a box, a key issued against it, a ledger entry, an
order line. The tradeoff is the door: nothing about a `Visit` or a
`KeyIssuance` is ever addressable except through the `SafeDepositBox`
that holds it, by design — the same design that makes
`box.visits.first` and `Banking::SafeDepositBox.find("DOWNTOWN:12")`
after an `Annotate` agree, because there was never a second copy of a
visit to disagree with. Wanting to look one up on its own, without its
parent in the call, is the sign a separate aggregate was needed all
along — the third shape at the top of this page, which an entity can
never become without declaring it again.
