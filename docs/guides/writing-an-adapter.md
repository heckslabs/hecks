# Writing an adapter

Writing an adapter means binding this language to something external —
a storage backend nobody else has bound yet, or a webhook that has to
turn an external fact into a domain event. These are two different
jobs, in two different directions through the hexagon, and this page
covers both: the DRIVEN side (something the domain calls, to persist
itself) and the DRIVING side (something that calls the domain, from
outside).

Rather than describing an abstraction, this guide walks through the
two smallest real adapters this codebase ships — Heki and Memory —
method by method, and then runs them, live, against a small domain.
What an adapter gets for free, and what it owes, both come out of
that reading: an adapter is not a promise, it is a fixed list of
methods, either fully implemented or not.

## The two-file pattern

Every driven adapter is said twice, on purpose. A `.adapter` file
declares the shape:

```ruby skip
Hecks.adapter "Heki" do
  port   "persistence"
  field  :dir
end
```

and a `.rb` file beside it is the implementation. `port` says which
port this binds to (`persistence`, here); `field` names a setting a
`.world` block may supply (`dir` — where Heki keeps its files);
`secret` (not used by Heki, but available) marks a field the same way
except that it is read from the environment, never written into a
`.world` file in the clear. Nothing here is optional ceremony: the
declared fields are checked against what a `.world` block actually
supplies at boot, before your adapter's `initialize` ever runs. Get
the field name wrong in your `.world` file and you find out at boot,
not at the first save.

Memory declares even less — no fields at all, because it keeps
nothing on disk to configure:

```ruby skip
Hecks.adapter "Memory" do
  port   "persistence"
end
```

Two files, one fact, checked twice. That is the whole pattern; nothing
about it changes for a database adapter versus a file adapter versus
one that talks to something over a network.

## The persistence contract

`Hecksagain::Ports::Persistence::AppendOnly` is what actually stands
between the domain and your adapter — every save and delete is
append-before-project, as a port invariant, not a convention your
adapter has to remember on its own. Read its constructor and the
contract is not a suggestion, it is a check:

```ruby skip
def initialize(adapter)
  @adapter = adapter
  required = %i[append project entries]
  missing = required.reject { |method| adapter.respond_to?(method) }
  raise Runtime::WiringError, "#{adapter.class} does not implement append-only persistence: #{missing.join(', ')}" unless missing.empty?
end
```

Three methods, checked at construction time, before your adapter ever
sees a real record — not the longer list you might expect from reading
`find`/`all`/`delete`/`count`/`save` calls elsewhere in this file.
Those exist too, but `AppendOnly` supplies `save` and `delete` itself
(each becomes an `append` immediately followed by a `project`, the
invariant the port exists to hold) and only *delegates* `find`, `all`,
and `count` to your adapter — nothing enforces those three at boot,
they simply fail the first time something calls them if you left them
out. `record_event` and `events` are optional passthroughs, called
only `if @adapter.respond_to?(...)`.

The checked half can be proven live by building something that
implements none of the three and handing it to `AppendOnly` directly:

```ruby
class IncompleteStore
  def initialize(aggregate:, settings: {}, root: nil)
    @aggregate = aggregate
  end

  attr_reader :aggregate
end

aggregate = Hecksagain::Bluebook::DSL::AggregateBuilder.new("Crate").tap do |b|
  b.value_object("Label") { attribute :value, String }
  b.attribute :label, "Label"
end.build

Hecksagain::Ports::Persistence::AppendOnly.new(IncompleteStore.new(aggregate: aggregate))  # ~> WiringError: does not implement append-only persistence: append, project, entries
```

That is the actual gate. Everything below is what a real adapter puts
behind it, walked against the two smallest ones this codebase has.

### What each method does, read off Heki

Heki is a file-backed store — a compressed snapshot plus an
append-only journal beside it (`lib/hecksagain/adapters/driven/heki.rb`,
`heki/snapshot.rb`, `heki/journal.rb`). Its own `initialize` takes
exactly what every adapter's does:

```ruby skip
def initialize(aggregate:, settings: {}, root: nil)
```

`aggregate` is the IR object your adapter is storing instances of —
you did not choose it, the domain declared it. `settings` is whatever
your `.adapter` file's `field`/`secret` list resolved to from the
`.world` block. `root` is a directory the adapter is free to resolve
paths against (Heki does; a network adapter would ignore it).

- **`save(instance)`** — builds a `save` entry from the instance's
  `id` and `state`, appends it, projects it, returns the instance.
  Heki's own `save` calls `append` then `project` itself — the same
  sequencing `AppendOnly` would do for you if you left `save` out
  entirely and let the port's default stand.
- **`find(id)`** — reads the current projected record for that id and
  returns `nil` if there is none. Heki materializes it back into a
  `Runtime::Instance`, keys transformed back to symbols; a store that
  kept the state already in that shape would just return it.
- **`all`** — every current record, as `Runtime::Instance` objects.
  Heki sorts by id first, deliberately: order otherwise depends on
  file-system enumeration or hash iteration, and a guide (or a test)
  that asserted on that order would be asserting on an accident.
- **`delete(id)`** — an entry with `operation: "delete"`, appended and
  projected the same as a save; Heki checks `find(id)` first and
  returns `false` without writing anything if there was nothing to
  delete.
- **`count`** — `store.size`, nothing more. Whatever your adapter's
  `all` would return, the length of it.
- **`entries`** — the raw append log, replayed to answer `find`/`all`.
  Heki's journal is literally this: one JSON line per entry, and
  `entries` parses every line back into a `Ports::Persistence::Entry`.
  This is the method `AppendOnly#recover!` reads to rebuild `all` and
  `find`'s answers from nothing after a crash — `entries.each { |e|
  project(e) }`.
- **`record_event(event)` / `events`** — append and read-back for
  events accumulated during a dispatch. Heki just pushes onto an
  in-memory array (`@events << event`) and hands it back; nothing here
  is durable, because a dispatch's events are read once, by the same
  process, before the array goes out of scope.

### Memory, side by side

Memory implements the identical surface with no file underneath it at
all — `@records`, `@events`, `@entries`, three plain Ruby structures:

```ruby skip
def find(id) = @records[id.to_s]
def all      = @records.values
def count    = @records.size
```

Its `entries` method is `@entries.dup` — the literal in-memory append
log, nothing replayed, because nothing needed to survive a restart.
Comparing the two side by side is the fastest way to see which parts
of Heki are the CONTRACT (the method names, the entry shape, the
append-before-project order) and which parts are just Heki's own
choice of durable format (JSON lines, zlib, a magic header). Your
adapter owes the first list. The second is yours to invent.

### Proving it, live

Both of these are ordinary Ruby objects — nothing about exercising
them requires a `.bluebook` declaration or a booted domain. This is
the adapter-writer's shortcut: build an aggregate IR object directly
with the same builder the query-agreement spec uses
(`spec/adapters/query_agreement_spec.rb`), and drive an adapter against
it by hand.

```ruby
def crate(aggregate, id, **fields)
  built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: id)
  fields.each { |name, value| built[name] = Hecksagain::Runtime::Value.for(aggregate, name, value) }
  built
end

memory = Hecksagain::Adapters::Memory.new(aggregate: aggregate)
memory.save(crate(aggregate, "crate-1", label: { value: "wool blankets" }))

memory.find("crate-1").state[:label].to_h  # => { value: "wool blankets" }
memory.count                                # => 1
memory.entries.map(&:operation)             # => ["save"]
memory.events                                # => []
```

```ruby
memory.delete("crate-1")
memory.find("crate-1")   # => nil
memory.count              # => 0
```

(Memory's own `delete` hands back whatever `Hash#delete` returns —
the removed record, or `nil` if there was none; only `AppendOnly`'s
wrapper normalizes that to a plain `true`/`false`. A raw adapter's
`delete` return value is not part of the contract — `find` afterward
is the fact that actually matters, and the one every caller should
check.)

Heki, against a real temp directory, proving the journal is really a
file on disk and not a metaphor:

```ruby
require "tmpdir"

dir  = Dir.mktmpdir("grenier-heki-")
heki = Hecksagain::Adapters::Heki.new(aggregate: aggregate, root: dir)
heki.save(crate(aggregate, "crate-2", label: { value: "cedar chest" }))

heki.find("crate-2").state[:label].to_h  # => { value: "cedar chest" }
File.exist?(heki.path)                    # => true
File.exist?("#{heki.path}.journal")       # => true
heki.entries.map(&:operation)             # => ["save"]
```

## The `query` hook — optional, and worth deciding on purpose

`Ports::Query` gives every adapter exactly one hook to implement:

```ruby skip
def execute(repository, specification, args = {}, context: {})
  adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
  return nil unless adapter.respond_to?(:query)

  validate!(specification, adapter)
  adapter.query(specification, args, context: context)
end
```

Implement `query` and you compile the specification yourself — Sqlite
and Postgres both do, into SQL, so a `where`/`order_by`/`limit` in a
bluebook becomes a real `WHERE`/`ORDER BY`/`LIMIT` and the database
does the filtering. Skip it, and callers fall back to
`Ports::Query::InMemory` — the reference interpreter walks `repository.all`
by hand and answers correctly, just without any pushdown: every record
comes off disk (or wherever `all` reads from) before the filter runs.

This is a real shipping decision, not a box to check. A small adapter,
or one backing an aggregate nobody queries by anything but id, can
skip `query` entirely and be correct on day one. Heki and Memory both
take exactly that option — look again at their `query` methods:

```ruby skip
def query(specification, args = {}, context: {})
  Ports::Query::InMemory.execute(all, specification, args)
end
```

Neither compiles anything. Both hand their own `all` to the reference
interpreter and let it do the walking. That fallback can be shown to
answer correctly, live, against a declared query:

```ruby
queryable = Hecksagain::Bluebook::DSL::AggregateBuilder.new("Crate").tap do |b|
  b.value_object("Label") { attribute :value, String }
  b.attribute :label, "Label"
  b.lifecycle(:status, default: "stored") { transition "Move" => "moved", from: "stored" }
  b.query("Stored") { where(status: "stored") }
end.build

qmemory = Hecksagain::Adapters::Memory.new(aggregate: queryable)
qmemory.save(crate(queryable, "crate-1", label: { value: "wool blankets" }, status: "stored"))
qmemory.save(crate(queryable, "crate-2", label: { value: "cedar chest" },   status: "moved"))

qmemory.query(queryable.query("Stored")).map(&:id)  # => ["crate-1"]
```

The same declared query, run against Sqlite or Postgres instead, would
answer the identical id list — but by asking the database, not by
walking a Ruby array. Nothing about the bluebook changes to get that;
only which adapter it is bound to.

## Naming: `storage_name`, not your own scheme

An aggregate names its own table or file, and every adapter reads it
off the same method — none of them invent a naming convention of
their own:

```ruby skip
def storage_name = Naming.snake(@name)
```

```ruby
aggregate.storage_name  # => "crate"
```

Heki's path derivation runs straight through it —
`File.join(dir, "#{@aggregate.storage_name}.heki")` — and Postgres's
`Lineage#journal` does the same
(`"hecks_journal_#{Naming.snake(@domain)}"`) one level up, at the
domain rather than the aggregate. A new adapter that rolled its own
casing or pluralization would produce a name every other adapter,
every migration, and every piece of tooling that shells out to
`storage_name` would disagree with. Read the name off the aggregate;
do not compute it again.

## The conformance bar

None of the above proves your adapter agrees with the others on what a
query actually *means* — only that it answers, not that it answers the
same thing Sqlite or Postgres would for the identical declared query
over the identical records. `spec/adapters/query_agreement_spec.rb` is
the gate that checks exactly that: one aggregate, five records, eleven
declared queries (`eq`, `ne`, `in`, an empty `in`, `lt` through a
query argument, `gte` descending, a two-level nested path with a limit,
an offset, ordering by a value-object string, `contains` on a list of
value objects, `contains` on a scalar), each asserted against a
hand-computed id list worked out independently of any of the three
engines — not merely "the adapters agree with each other," because
three engines sharing one bug would still pass a pairwise check. Memory,
Sqlite, and Postgres all run through the same `agree!` helper today.

If you are shipping a fourth adapter that implements `query`, this is
the file to extend — add your adapter's `let`, add it to `agree!`, and
run the suite. An adapter that skips the native `query` hook entirely
still owes correctness (via `Ports::Query::InMemory`, which this
suite's Memory row already exercises) but has no compiled dialect of
its own to gate here. An adapter that implements `query` and is never
run through this file is one nobody should trust with a `where` clause
yet — this is the actual shipping check, not a tour of the port.

## `lineage_capable?` — what only Postgres carries

An adapter's era story is optional, and the runtime asks for it by
capability, not by name:

```ruby skip
def lineage_capable?(registry, adapter_name)
  adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
  adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
rescue StandardError
  false
end
```

Today exactly one adapter answers true — `Hecksagain::Adapters::Postgres`
declares `def self.lineage_capable? = true` and nothing else does.
Memory and Heki simply do not implement the class method at all, and
the check treats that the same as answering false:

```ruby
Hecksagain::Adapters::Memory.respond_to?(:lineage_capable?)  # => false
Hecksagain::Adapters::Heki.respond_to?(:lineage_capable?)    # => false
```

Lineage-capable is what lets an adapter mint an era when a domain's
declared shape drifts, hold that era's frozen source text beside the
data it describes, and apply a translation across the boundary — the
whole reason Postgres carries `lineage_manager/` and `lineage.rb` at
all (era minting, the head/tail view chain, `merge_tail!`). Not
implementing it costs something real: a domain bound to a
non-lineage-capable adapter still boots, still runs, still refuses
everything it always refused — but the moment its declared shape
changes, there is no edge for that change to travel across. The data
must be hand-migrated outside the language, or the shape must not
change. That may be a fine trade for a small adapter that will never
carry a domain through a schema change — Heki, today, makes exactly
that trade — but it is a trade, decided once, at the adapter level.

## The driving side: anything that calls `dispatch_port`

Everything above assumed the domain calls out to storage. A driving
adapter is the opposite direction — code OUTSIDE the domain calling
IN. There is no special class to subclass and no file extension of its
own; a driving adapter is any code that calls
`Dispatcher#dispatch_port`:

```ruby skip
def dispatch_port(domain, aggregate_name, port_name, operation_name, **args)
  aggregate = resolve_aggregate(domain, aggregate_name, "#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}")
  port = aggregate.port(port_name) ||
         raise(UnknownVerb, "#{aggregate_name} has no port #{port_name.inspect}")
  operation = port.operation(operation_name) ||
              raise(UnknownVerb, "#{port_name} has no operation #{operation_name.inspect}")

  announced = @port_ops.call(domain, aggregate, operation, args)

  announced.each { |event| @policies.react(event, domain) }
  announced.each { |event| @sagas.advance(event, domain) }

  announced
end
```

A Rails controller, a webhook handler, a cron job — every one of them
is a driving adapter in exactly this sense: they translate something
that happened out there into a call shaped like this one, and nothing
about the domain's own rules changes depending on who is calling.
`examples/pizzas/bluebook/hecksagon/mock_stripe_payment_adapter.rb` is
the worked example — a stand-in for a real Stripe webhook, quoted here
rather than run (it boots the whole Pizzas example with `Hecks.boot`,
a heavier path than this guide needs):

```ruby skip
# A real handler would verify a Stripe signature here and pull these
# fields out of event.data.object; a reference is always a bare id.
RUNTIME.dispatch_port(
  "Pizzas", "Order", "PaymentGateway", "Receive",
  name:          NAME,
  customer_name: { value: "Chris" },
  amount:        { cents: 1200 }
)
```

Note what a port operation does NOT do: no `given`, no `then_set`, no
save. `PortOperationInterpreter` is a trimmed `CommandInterpreter` —
the same argument gate and coercion, but it never hydrates or mutates
the aggregate record itself. It only translates an external call into
an event in the domain's own vocabulary; whatever happens next happens
wherever a `policy` reacts to that event, the same as it would for any
command-emitted one. The port is the boundary; the business rule stays
where every other business rule in this language lives, in a command
or a policy the port never touches directly.

That shape can be shown for real, against a small domain declared for
this purpose. Declare the aggregate:

```ruby bluebook
Hecks.bluebook "Grenier" do
  vision "An attic ledger: what's stored up there, and whether it still is."
  supporting

  aggregate "Crate" do
    description "One crate, stored in the loft until it comes back down."

    identified_by { label.value }

    attribute :label, Label

    value_object "Label" do
      attribute :value, String
      invariant("a crate is named") { !value.to_s.empty? }
    end

    lifecycle :status, default: "stored" do
      transition "Move" => "moved", from: "stored"
    end

    command "Store" do
      role "Keeper"
      goal "Put a crate up in the loft"

      attribute :label, Label

      emits "Stored"
    end
  end
end
```

Declare the port in the hecksagon — a driving port lives here,
never in the bluebook, the same boundary a `persisted_by` line marks
for storage:

```ruby boot
Hecks.hecksagon("Grenier") do
  Grenier::Crate.persisted_by("Memory")

  Grenier::Crate.port "ClimateSensor" do
    operation "Alert" do
      reference_to Crate, as: :label
      attribute :reading, Integer

      emits "TemperatureAlerted"
    end
  end
end
```

And call it exactly the way a real sensor's webhook handler would —
through `dispatch_port`, never through the facade a command would use:

```ruby
crate = Grenier::Crate.store(label: { value: "wool blankets" })
crate.status  # => "stored"

runtime.dispatch_port("Grenier", "Crate", "ClimateSensor", "Alert", label: crate.id, reading: 41).map(&:name)  # => ["TemperatureAlerted"]
```

`TemperatureAlerted` is now in this domain's event log, in this
domain's own vocabulary — a fact a `policy` could react to (raise a
`Move` command, page someone, whatever the loft actually needs), the
same way `OnPizzaPaymentReceived` reacts to `PizzaPaymentReceived` in
the real example. That policy is not wired here, on purpose — the
point of this page is the boundary itself, and the boundary is
already fully proven: an external call came in shaped nothing like
this domain's own commands, and left as an event shaped exactly like
every other one it emits.

## Shipping checklist

- `.adapter` + `.rb`, both written, the fields matching what your
  `.world` block actually supplies.
- `append`, `project`, `entries` implemented — `AppendOnly` checks
  these three at construction and refuses to boot without them.
- `find`, `all`, `count` implemented — not checked at boot, but every
  read path calls them.
- `record_event`/`events` if your adapter needs to answer `events` at
  all; optional, called only if present.
- A decision made, not defaulted into, on `query`: implement it and
  compile your own dialect, or accept `Ports::Query::InMemory` and
  answer correctly without pushdown.
- Run `spec/adapters/query_agreement_spec.rb` against your adapter
  before anyone trusts it with a `where` clause.
- A decision made, not defaulted into, on `lineage_capable?`: carry
  eras and let a bound domain's shape evolve, or accept that it never
  can without a hand migration.
- For a driving adapter: nothing to declare in the bluebook at all —
  only a `port`/`operation` in the hecksagon, and a caller that reaches
  it through `dispatch_port`.
