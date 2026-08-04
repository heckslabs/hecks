# Queries and read models

You have an aggregate that refuses the wrong things and emits the right
events. Now someone wants a list — boats under a certain draft, everyone
who isn't moored, a dashboard that gathers a skipper's whole fleet in one
read. That is what `query` and `read_model` are for, and this guide is
about shipping one correctly: what the vocabulary can carry, what the
build refuses before your report reaches an adapter that would have
quietly disagreed with itself, and the one comparator you should not
trust yet.

Both constructs are built on the same option vocabulary
(`QuerySpecification::Common::DSL`) — `where`, `order_by`, `limit`, and
`offset` are what you'll reach for first, and this guide runs every
comparator `where` accepts against a real domain. `read_model` adds
`reference_to`/`include` on top, for a report that gathers more than one
aggregate at once.

## The domain

A marina: skippers, and the boats they keep here.

```bluebook
Hecks.bluebook "Marina" do
  vision "Boats swing on their moorings until they don't — and the harbourmaster needs to ask about depth, draft, and home port the same way every time, on whichever adapter is listening."
  supporting

  aggregate "Skipper" do
    description "Whoever keeps a boat here."

    identified_by { license.value }

    attribute :license, License
    attribute :name,    SkipperName

    value_object "License" do
      attribute :value, String
      invariant("a skipper is licensed") { !value.to_s.empty? }
    end

    value_object "SkipperName" do
      attribute :value, String
      invariant("a skipper is named") { !value.to_s.empty? }
    end

    command "Register" do
      role "Harbourmaster"
      goal "Take on a new skipper"

      attribute :license, License
      attribute :name,    SkipperName

      then_set :license, to: :license
      then_set :name,    to: :name

      emits "SkipperRegistered"
    end
  end

  aggregate "Boat" do
    description "A vessel on its mooring — where it sits, how deep it draws, and what the yard has flagged about it."

    identified_by { name.value }

    reference_to Skipper

    attribute :name,      BoatName
    attribute :home_port, HomePort
    attribute :draft,     Draft
    attribute :berth,     Berth
    attribute :tags,      list_of(Tag)

    value_object "BoatName" do
      attribute :value, String
      invariant("a boat is named") { !value.to_s.empty? }
    end

    value_object "HomePort" do
      attribute :value, String
      invariant("a home port is named") { !value.to_s.empty? }
    end

    value_object "Draft" do
      attribute :meters, Float
      invariant("a draft is never negative") { meters >= 0 }
    end

    value_object "Depth" do
      attribute :meters, Float
    end

    value_object "Berth" do
      attribute :number, Integer
      attribute :depth,  Depth
    end

    value_object "Tag" do
      attribute :value, String
      invariant("a tag is not the empty string") { !value.to_s.empty? }
    end

    lifecycle :status, default: "moored" do
      transition "Depart" => "underway", from: "moored"
      transition "Return" => "moored",   from: "underway"
    end

    command "Register" do
      role "Harbourmaster"
      goal "Give a boat a berth"

      reference_to Skipper
      attribute :name,      BoatName
      attribute :home_port, HomePort
      attribute :draft,     Draft
      attribute :berth,     Berth
      attribute :tags,      list_of(Tag), optional: true

      then_set :name,      to: :name
      then_set :home_port, to: :home_port
      then_set :draft,     to: :draft
      then_set :berth,     to: :berth
      then_set :tags,      to: :tags

      emits "BoatRegistered"
    end

    command "Depart" do
      role "Harbourmaster"
      goal "Send a boat out"

      reference_to Boat
      emits "BoatDeparted"
    end

    command "Return" do
      role "Harbourmaster"
      goal "Bring a boat back to its mooring"

      reference_to Boat
      emits "BoatReturned"
    end

    # eq, spelled the short way — a plain value is always eq.
    query "Moored" do
      description "Everything sitting at its berth right now — the harbourmaster's default view."
      where(status: "moored")
      order_by :name
    end

    # ne — everything the default view leaves out.
    query "Underway" do
      description "Everything that is not at its berth."
      where(status: { ne: "moored" })
      order_by :name
    end

    # lt, through a query argument resolved with :symbol — the caller
    # supplies the ceiling, never a value baked into the declaration.
    query "ShallowDraft" do
      description "Boats that draw less than a ceiling the caller supplies — who can raft up against the shallow dock."
      attribute :ceiling, Draft
      where(draft: { lt: :ceiling })
      order_by :draft
    end

    # gte, with a literal value instead of a :symbol — the other spelling
    # `where` accepts, and the ordering runs :desc.
    query "DeepDraftDesc" do
      description "Boats drawing at least two meters, deepest first — who needs the outer slips."
      where(draft: { gte: { meters: 2.0 } })
      order_by :draft, :desc
    end

    # lte, on a two-level dotted path into a nested value object.
    query "ShallowBerths" do
      description "Boats sitting in three meters of water or less."
      where(:"berth.depth.meters" => { lte: 3.0 })
      order_by :"berth.depth.meters"
    end

    # gt, same dotted path, with limit trimming the result.
    query "DeepBerths" do
      description "The two deepest berths in use — where a bigger boat could still fit."
      where(:"berth.depth.meters" => { gt: 3.0 })
      order_by :"berth.depth.meters"
      limit 2
    end

    # offset, paging past the shallowest berth.
    query "BerthsByDepthOffset" do
      description "Every boat by berth depth, skipping the shallowest — page two of the berth report."
      order_by :"berth.depth.meters"
      offset 1
    end

    # in, with the comma convention.
    query "FromHomePorts" do
      description "Boats whose home port is one of a caller-supplied list."
      where(home_port: { in: "Sausalito,Richmond" })
      order_by :name
    end

    # contains, over a list of value objects.
    query "Flagged" do
      description "Boats carrying a yard tag — the maintenance queue."
      where(tags: { contains: "leaky" })
      order_by :name
    end
  end

  # A THROUGH RELATIONSHIP: gathered from two aggregates in one read,
  # the way plain `query` never does.
  read_model "Roster" do
    description "One skipper's boats, gathered from two aggregates."
    reference_to Skipper
    include Skipper
    include Boat
  end
end
```

Wire it to Memory — nothing here needs more:

```ruby boot
Hecks.hecksagon("Marina") do
  Marina::Boat.persisted_by("Memory")
  Marina::Skipper.persisted_by("Memory")
end
```

## Asking a declared query

Seed two skippers and five boats, then send one out:

```ruby
runtime.dispatch("Marina::Skipper.Register", license: { value: "SKIP-1" }, name: { value: "Ada Voss" })
runtime.dispatch("Marina::Skipper.Register", license: { value: "SKIP-2" }, name: { value: "Bo Reyes" })

runtime.dispatch("Marina::Boat.Register", skipper_id: "SKIP-1", name: { value: "Josephine" },
                  home_port: { value: "Sausalito" }, draft: { meters: 1.5 },
                  berth: { number: 12, depth: { meters: 2.0 } }, tags: [{ value: "leaky" }])
runtime.dispatch("Marina::Boat.Register", skipper_id: "SKIP-1", name: { value: "Windward" },
                  home_port: { value: "Alameda" }, draft: { meters: 2.0 },
                  berth: { number: 5, depth: { meters: 4.0 } }, tags: [{ value: "blue" }])
runtime.dispatch("Marina::Boat.Register", skipper_id: "SKIP-2", name: { value: "Petrel" },
                  home_port: { value: "Sausalito" }, draft: { meters: 0.9 },
                  berth: { number: 3, depth: { meters: 1.2 } })
runtime.dispatch("Marina::Boat.Register", skipper_id: "SKIP-2", name: { value: "Meridian" },
                  home_port: { value: "Richmond" }, draft: { meters: 2.8 },
                  berth: { number: 20, depth: { meters: 5.5 } }, tags: [{ value: "leaky" }])
runtime.dispatch("Marina::Boat.Register", skipper_id: "SKIP-1", name: { value: "Halcyon" },
                  home_port: { value: "Alameda" }, draft: { meters: 1.2 },
                  berth: { number: 8, depth: { meters: 3.5 } })

runtime.dispatch("Marina::Boat.Depart", name: { value: "Windward" })
```

A declared query is asked the way a command is dispatched — a fully
qualified verb, through the same `runtime` — and it answers an Array of
Hashes, each one the record's id merged with its state:

```ruby
runtime.query("Marina::Boat.Moored").map { |row| row[:name].value }
# => ["Halcyon", "Josephine", "Meridian", "Petrel"]

runtime.query("Marina::Boat.Underway").map { |row| row[:name].value }
# => ["Windward"]
```

Notice `row[:name]` came back a `Value`, the same object a command
argument would build — read it with `.value`, not `.inspect`, the same
rule AUTHORING.md holds every claim on this page to. A row is not a
plain hash the whole way down; only `read_model` flattens that far, and
the difference matters later in this guide.

The rest of `where`'s comparators, against the same seed:

```ruby
runtime.query("Marina::Boat.ShallowDraft", ceiling: { meters: 1.5 }).map { |row| row[:name].value }
# => ["Petrel", "Halcyon"]

runtime.query("Marina::Boat.DeepDraftDesc").map { |row| row[:name].value }
# => ["Meridian", "Windward"]

runtime.query("Marina::Boat.ShallowBerths").map { |row| row[:name].value }
# => ["Petrel", "Josephine"]

runtime.query("Marina::Boat.DeepBerths").map { |row| row[:name].value }
# => ["Halcyon", "Windward"]

runtime.query("Marina::Boat.BerthsByDepthOffset").map { |row| row[:name].value }
# => ["Josephine", "Halcyon", "Windward", "Meridian"]

runtime.query("Marina::Boat.FromHomePorts").map { |row| row[:name].value }
# => ["Josephine", "Meridian", "Petrel"]

runtime.query("Marina::Boat.Flagged").map { |row| row[:name].value }
# => ["Josephine", "Meridian"]
```

`DeepBerths` is worth a second look: three boats sit deeper than three
meters (Halcyon, Windward, Meridian), and `limit 2` cut Meridian, the
deepest of the three, because `order_by` ran ascending first. Limit
trims what ordering already sorted — declare them in the order you mean,
because the adapter doesn't guess which one you wanted kept.

`ShallowDraft` is the other one to notice: `:ceiling` is not a value
baked into the declaration, it's an argument named on the query
(`attribute :ceiling, Draft`) and resolved from whatever the caller
passes at ask-time — the same shape banking's `Account.Overdrawn` uses
for its `:floor`. A query with no such argument, or a `:symbol` naming
one that was never declared, is exactly what the seal catches next —
before a caller finds out at runtime that their filter silently matched
nothing.

## The seal — what you don't have to catch by hand

Four mistakes never reach an adapter. They're caught the moment the
bluebook builds, not the first time a caller runs the query and gets a
suspiciously empty result. That's the whole value of the seal: it turns
"this report has been quietly wrong since it shipped" into "this
domain didn't build." Everything past these four, you still have to get
right yourself — the open question at the end of this guide is exactly
that kind of thing.

Reaching the seal directly needs the same ambient registry a `.bluebook`
file gets from the boot loader — `Hecks.bluebook` refuses to run
outside one — so each attempt below opens its own with
`Hecksagain.with_registry` by hand, wrapped in a `lambda` so the build
only runs, and only refuses, at the point this guide claims it does.
None of these throwaway aggregates bothers with `identified_by`: the
seal you're about to trip runs before identity would ever matter, so
there's no reason to declare one just to reach it.

A `where` over a field the aggregate never declared — the report would
otherwise match nothing and refuse nothing, forever, on every adapter:

```ruby
seal_a = lambda do
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Hecks.bluebook("MarinaSealA") do
      aggregate "Dinghy" do
        value_object("BoatName") { attribute :value, String }
        attribute :name, BoatName
        query("Adrift") { where(depth: { lt: 5 }) }
      end
    end
  end
end
seal_a.call   # ~> Malformed: which Dinghy never declares
```

An ordered comparator (`lt`/`lte`/`gt`/`gte`) over a field that holds no
number — the reference interpreter would quietly match no rows while
SQL compared the text lexicographically, two answers for one query:

```ruby
seal_b = lambda do
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Hecks.bluebook("MarinaSealB") do
      aggregate "Dinghy" do
        value_object("BoatName") { attribute :value, String }
        attribute :name, BoatName
        query("BySize") { where(name: { gt: "A" }) }
      end
    end
  end
end
seal_b.call   # ~> Malformed: holds no number
```

A `:symbol` value naming no declared query argument — it would resolve
to `nil` at dispatch and match nothing, the same silent failure as the
undeclared field:

```ruby
seal_c = lambda do
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Hecks.bluebook("MarinaSealC") do
      aggregate "Dinghy" do
        value_object("Draft") { attribute :meters, Float }
        attribute :draft, Draft
        query("ShallowerThan") { where(draft: { lt: :ceiling }) }
      end
    end
  end
end
seal_c.call   # ~> Malformed: declares no ceiling attribute
```

A dotted path that lands on a value object instead of a scalar — SQL
would hand back a JSON object where the reference interpreter unwraps a
hash, and the two would disagree about what the row even holds:

```ruby
seal_d = lambda do
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Hecks.bluebook("MarinaSealD") do
      aggregate "Dinghy" do
        value_object("Depth") { attribute :meters, Float }
        value_object("Berth") { attribute :depth, Depth }
        attribute :berth, Berth
        query("ByBerth") { where(:"berth.depth" => { lt: 5 }) }
      end
    end
  end
end
seal_d.call   # ~> Malformed: lands on a value object
```

`ShallowBerths`/`DeepBerths` above show the path that IS allowed:
`:"berth.depth.meters"` reaches through two levels and lands on a
number, exactly the shape pizzas' `CostingLessThan`/`Expensive` queries
use over `:"pizza.price_cents.cents"` — nested value objects were, for a
while, simply unreachable by a query at all, until one field-path walk
(`QuerySpecification::FieldPath`) replaced three different readings of
what a dotted path means.

`ShallowDraft`/`DeepDraftDesc` show the other legal shape worth naming:
a bare, one-level value object with a single numeric member — `draft`
is a `Draft`, not a `Float`, and `lt`/`gte` still work on it directly,
the same convention banking's `Account.Overdrawn` relies on
(`where(balance: { lt: :floor })`). The convention stops at one level —
a dotted path has to land ON the number itself, it doesn't get to reach
through a named path AND unwrap a bare value object at the end.

## `read_model` — reading across aggregates

`query` never crosses an aggregate boundary. `Roster` does, on purpose:
`reference_to Skipper` names the root, `include Skipper` and
`include Boat` gather around it, and cardinality is inferred rather than
declared — the reference target is the one record, everything else
comes back a collection (`many: target != reference_target`). You do not
say `include Boat, many: true` anywhere; naming a second aggregate is
enough.

A read model is asked differently from an aggregate query — bare domain
name, dot, the model's own name, no aggregate in between — because
nothing single aggregate owns it:

```ruby
roster = runtime.query("Marina.roster", skipper: "SKIP-1")

roster.size                                            # => 1
roster.first[:skipper][:license]                       # => { value: "SKIP-1" }
roster.first[:boats].map { |boat| boat[:name][:value] } # => ["Halcyon", "Josephine", "Windward"]
```

That `[:value]` is not a typo for `.value` — a read model row is fully
materialized, every nested value object walked down to a plain Hash,
where an aggregate-query row above kept `Value` objects you read with a
method. Know which one you're holding before you write the line that
reads it; the two do not respond to the same calls.

## The gate that makes any of this trustworthy

None of the above means much if Memory answers one way and Sqlite
answers another the day you switch adapters. `spec/adapters/query_agreement_spec.rb`
exists because none of the ordinary adapter specs ever checked that —
each proves an adapter self-consistent, asking it a question and
checking its own answer looks sane, which cannot see two adapters
quietly disagreeing. That gate runs the same declared query against
Memory, Sqlite, and Postgres over the same seeded records, and asserts
every engine against one independent, hand-computed expected id list —
not merely that the adapters agree with each other, since three engines
sharing the same bug would still "agree" under that weaker check. When
you ship a query that must mean the same thing on whichever adapter a
deployment binds, that file is where the guarantee actually lives, not
in this guide's prose.

## Don't rely on this yet: `contains` with a comma

`contains` is exercised above on a plain value (`"leaky"`), and that's
deliberate. If the value you pass it *contains a comma*, the reference
interpreter and SQL stop agreeing: the reference interpreter reads
`contains` as CSV/list membership (splitting on comma, same as `in`
does), while compiled SQL reads it as a literal substring search. A
one-word tag survives that difference by accident; a value with a comma
in it will not, and which adapter is bound decides which answer you get.
This is a named, open gap in the language, not a corner you can reason
your way around — `spec/adapters/query_agreement_spec.rb` states it
plainly rather than testing around it, and so does this guide: don't
ship a `contains` clause over a value that might carry a comma until
this is resolved one way or the other.

— Miette
