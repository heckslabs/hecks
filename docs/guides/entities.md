# Entities

You have an aggregate, and it needs to hold onto a list of things that
each have to be found, changed, and refused individually — not just
appended and forgotten. Three shapes can hold a list, and picking the
wrong one is the mistake this page exists to prevent:

- No identity, no lifecycle of its own, nothing ever addresses one
  element instead of another — that's a **value object** in a
  `list_of`. A specimen's notes, in the getting-started guide, are
  exactly this: appended, read back, never individually reached.
- Its own identity, its own commands, its own lifecycle, but it never
  makes sense apart from the thing that holds it — that's an
  **entity**. A claim ticket only exists because a coat-check counter
  issued it; nobody looks one up on its own.
- Identity, AND it needs to be found and acted on directly from
  outside, with no parent in the sentence — that's a separate
  **aggregate**, referenced the way `commands.md`'s `Tree` references
  `Orchard`.

The middle one is this page. One small domain, real enough to lose a
coat if a command lets the wrong thing through.

## The declaration

```bluebook
Hecks.bluebook "Foyer" do
  vision "One counter, many claim tickets — nothing is handed back to the wrong hands."
  supporting

  aggregate "FoyerCounter" do
    description "The coat-check counter for one venue, and every ticket it has issued."

    identified_by { name.value }

    attribute :name,   FoyerCounterName
    attribute :checks, list_of(FoyerCheck)

    value_object "FoyerCounterName" do
      attribute :value, String
      invariant("a counter is named") { !value.to_s.empty? }
    end

    value_object "FoyerTicketNumber" do
      attribute :value, Integer
      invariant("a ticket number is positive") { value.positive? }
    end

    value_object "FoyerOwnerName" do
      attribute :value, String
      invariant("an owner is named") { !value.to_s.empty? }
    end

    value_object "FoyerItemNote" do
      attribute :value, String
    end

    entity "FoyerCheck" do
      description "One claim ticket, from check-in to reclaim."

      identified_by { ticket.value }

      attribute :ticket, FoyerTicketNumber
      attribute :owner,  FoyerOwnerName
      attribute :note,   FoyerItemNote

      lifecycle :status, default: "checked" do
        transition "Reclaim" => "reclaimed", from: "checked"
      end

      command "Reclaim" do
        role "Attendant"
        goal "Hand the item back, and only to the person who checked it in"

        attribute :claimant, FoyerOwnerName

        given("only the owner who checked it in may reclaim it") { owner.value == claimant.value }

        emits "Reclaimed"
      end

      query "Unclaimed" do
        description "Tickets nobody has come back for yet."
        where(status: "checked")
      end
    end

    command "OpenCounter" do
      role "Venue manager"
      goal "Stand up a coat-check counter before doors open"

      attribute :name, FoyerCounterName

      emits "CounterOpened"
    end

    command "CheckIn" do
      role "Attendant"
      goal "Take an item in and issue a claim ticket for it"

      reference_to FoyerCounter
      attribute :ticket, FoyerTicketNumber
      attribute :owner,  FoyerOwnerName
      attribute :note,   FoyerItemNote

      then_set :checks, append: { ticket: :ticket, owner: :owner, note: :note }

      emits "CheckedIn"
    end
  end
end
```

Read `entity "FoyerCheck" do ... end` for what it is: a block nested
INSIDE `aggregate "FoyerCounter"`, at the same level a `value_object`
or a `command` sits. It gets its own `description`, its own
`identified_by`, its own `attribute`s, its own `lifecycle`, its own
`command`s, its own `query` — everything an aggregate declares, in the
same words. That's not a coincidence: an entity has to answer
`hecks_name`, `attributes`, `attribute`, `identified_by`, and
`lifecycle` exactly as an aggregate does, because the runtime builds
the same `Instance` wrapper around either one and hands both to the
same rule engine as `declaring`. The one thing it never answers is
`value_object` — that's the single bit the runtime reads to tell a
piece from a head, and it's how `FoyerCheck` gets to have an identity
without being mistaken for the plain value objects sitting right next
to it in the same aggregate.

Notice what `FoyerCheck`'s commands do NOT declare: no `reference_to`,
anywhere. `Reclaim` needs no reference back to its own entity — it IS
addressed through the parent, always, so there's nothing to reference.
`CheckIn`, by contrast, is a command on the AGGREGATE, and it's the one
that grows the list: `then_set :checks, append: { ... }` is how a
`FoyerCheck` comes into being at all. An entity is never created
through its own command — only appended by one that acts on its
parent.

## Wiring

```ruby boot
Hecks.hecksagon("Foyer") { Foyer::FoyerCounter.persisted_by("Memory") }
```

## Opening the counter, checking two things in

`FoyerCounter` is the aggregate, so it gets the door: a creating
command becomes a module method, same as every other aggregate you've
wired.

```ruby
counter = Foyer::FoyerCounter.open_counter(name: { value: "Vestibule" })
counter.check_in(ticket: { value: 1 }, owner: { value: "Aline Corbin" },  note: { value: "grey wool coat" })
counter.check_in(ticket: { value: 2 }, owner: { value: "Marcel Huyghe" }, note: { value: "umbrella" })

counter.checks.map { |c| c[:owner].to_h }  # => [{ value: "Aline Corbin" }, { value: "Marcel Huyghe" }]
counter.checks.map { |c| c[:status] }      # => ["checked", "checked"]
```

`checks` reads back as a plain array of hashes — one per `FoyerCheck`,
each field still a `Value` you unwrap with `.to_h`, plus the
`status` the lifecycle put there. There is no friendlier wrapper here,
because a list element was never minted a `Handle`; it lives inside its
parent's own state, exactly the way `list_of` always worked before an
entity had commands of its own.

## Addressing one ticket

Here is the fact this whole page turns on: `FoyerCheck` gets no door.
Booting installs a module for every AGGREGATE — `Foyer::FoyerCounter`
— and nothing for the entities nested inside one. There is no
`Foyer::FoyerCheck`, and no `check.reclaim` sugar on a ticket you're
holding, because you are never holding a ticket on its own. You reach
one the same way the language reaches anything nested: a dotted verb,
through its aggregate, carrying both identities:

```ruby
runtime.dispatch("Foyer::FoyerCounter.FoyerCheck.Reclaim",
                 name: { value: "Vestibule" }, ticket: { value: 1 }, claimant: { value: "Aline Corbin" })

counter = Foyer::FoyerCounter.find("Vestibule")
counter.checks.map { |c| c[:status] }  # => ["reclaimed", "checked"]
```

`Domain::Aggregate.Entity.Command` — the parent's own qualifier
(`FoyerCounter`) once, a `.` to cross into the piece (`FoyerCheck`),
another `.` to name what it does (`Reclaim`). The keyword arguments
carry THREE things at once and none of them can be skipped: `name`
finds the counter (`FoyerCounter`'s own `identified_by`), `ticket`
finds the one check inside it (`FoyerCheck`'s own `identified_by`), and
`claimant` is `Reclaim`'s own declared argument. Get the ticket number
right but the counter's name wrong and you get `NotFound` on the
counter before the runtime ever looks at the list; get both right and a
`ticket` nobody posted and you get `NotFound` naming the entity instead
— never a `nil`, either way.

## The refusal only the piece could make

`Reclaim`'s `given` reads a field off the entity's OWN state
(`owner`) against an argument the command declares (`claimant`) — the
same shape banking's `LedgerEntry.Amend` reads its own `amount` against
an incoming `adjustment`. This is a rule that belongs to the ticket,
not the counter: `FoyerCounter` has no opinion about who checked
ticket 1 in, and shouldn't have to.

```ruby
counter.check_in(ticket: { value: 3 }, owner: { value: "Odile Vasseur" }, note: { value: "black scarf" })

runtime.dispatch("Foyer::FoyerCounter.FoyerCheck.Reclaim", name: { value: "Vestibule" }, ticket: { value: 3 }, claimant: { value: "Someone Else" })  # ~> GivenNotMet: only the owner who checked it in may reclaim it
```

And the entity's own lifecycle refuses on its own terms, entirely
independent of the `given` above — ticket 1 is already `reclaimed`
from the call two sections up, so doing it again finds no admissible
transition:

```ruby
runtime.dispatch("Foyer::FoyerCounter.FoyerCheck.Reclaim", name: { value: "Vestibule" }, ticket: { value: 1 }, claimant: { value: "Aline Corbin" })  # ~> LifecycleRefused: Reclaim moves it only from "checked"
```

Two different refusals, and both belong to `FoyerCheck`, never to
`FoyerCounter` — proof that an entity's rules are its own, checked
against its own state, exactly as if it were the aggregate. The events
they would have announced never happen; the ones that already did are
still there, filed under the record they always were —
`FoyerCheck.Reclaim` announces onto the SAME event log `FoyerCounter`'s
own commands write to, because there is only ever one identity in play
here, the parent's:

```ruby
counter.events.map(&:name)  # => ["CounterOpened", "CheckedIn", "CheckedIn", "Reclaimed", "CheckedIn"]
```

## Asking the counter something about its tickets

A `query` inside `entity` reaches the same way a command does — dotted,
through the aggregate — and it answers with every element that
matches, across every counter that has one, each row carrying which
parent it came from:

```ruby
runtime.query("Foyer::FoyerCounter.FoyerCheck.Unclaimed").map { |row| row.transform_values { |v| Hecksagain::Runtime::Value.materialize(v) } }  # => [{ foyer_counter: "Vestibule", ticket: { value: 2 }, owner: { value: "Marcel Huyghe" }, note: { value: "umbrella" }, status: "checked" }, { foyer_counter: "Vestibule", ticket: { value: 3 }, owner: { value: "Odile Vasseur" }, note: { value: "black scarf" }, status: "checked" }]
```

`foyer_counter` is not a field you declared — it's the parent's own key,
stamped onto every row so an answer spanning several counters still
says which one each ticket belongs to. Reclaimed ticket 1 doesn't
appear: the `where` runs against the element the same way it runs
against a head, no different for living one level down.

## What this bought you, and what it didn't

An entity earns its keep exactly when a list needs individual
identity, individual rules, and an individual lifecycle — a claim
ticket, a ledger entry, an order line. It costs you the door: nothing
about a `FoyerCheck` is ever addressable except through the
`FoyerCounter` that issued it, by design — the same design that makes
`counter.checks[1]` and `Foyer::FoyerCounter.find("Vestibule")` after a
`Reclaim` agree, because there was never a second copy of a ticket to
disagree with. If you find yourself wanting to look one up on its own,
without its parent in the call, that's the tell you actually wanted a
separate aggregate all along — the third shape at the top of this
page, and the one entity can never become without you declaring it
again.

— Miette
