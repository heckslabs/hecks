<!-- doctest: postgres -->

# Schema evolution

Requires a local Postgres — this guide is about the one adapter that
can carry data across a shape change, so it runs against the real
thing or not at all.

Your domain's shape will change. Not might — will, the day it survives
contact with a second requirement. The question that decides whether
you can ship the change is not "does the new bluebook look right" — it
is "what happens to the records that were written under the old one."
Most systems answer that question with a migration script, hand-written,
untested against real data until it runs in production. This guide
documents the other answer: the shape change is declared, the same way
everything else here is declared, and a real tool tells you — before
you boot — whether every old record survives it.

## It already happened here

This is not a hypothetical. `examples/pizzas` lived through exactly this,
in this repository, and the result is sitting in a real Postgres
database right now. The `Pizza` aggregate became `Order`, carrying a
nested `Pizza` value object — because a pizza has no identity of its
own (two identical Margheritas ARE the same value), while the order
does. The evidence follows below rather than a description of it:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.world"))
Hecks.hecksagon("Pizzas") { Pizzas::Order.persisted_by("Postgres") }
```

```ruby
require "pg"

db = PG.connect(dbname: "hecks_pizzas")
eras = db.exec("SELECT ordinal, label FROM hecks_eras ORDER BY ordinal").to_a
eras.map { |row| row["ordinal"] }   # => ["1", "2"]

# "alpha" was written under era 1's shape — top-level price_cents, no
# nested value object. It reads back through era 2 correctly, or this
# sentence would be a lie the suite could catch.
row = db.exec_params("SELECT state FROM order_head WHERE id = $1", ["alpha"]).first
state = JSON.parse(row["state"])
state["pizza"]["price_cents"]["cents"].positive?   # => true
db.close
```

Two eras, one database, and a record that predates the second era still
answers correctly through it. That is the whole promise of this
system, proven against data that was never touched to make this guide
true.

## The mechanism

The walkthrough below needs a shape to actually change, live, in front
of you — a real drift introduced on purpose, then scaffolded and
resolved. Pizzas' real era 1→2 history above already happened; there is
no more drift left in it to discover. Banking's real history has none
at all. Reproducing a controlled drift against either would mean
minting a fake historical era onto a domain whose whole value is being
the real, settled record — a different and larger kind of dishonesty
than a small, clearly-labelled scratch fixture. So this one section
uses a throwaway domain, built and torn down inside the walkthrough
itself, exactly the way `spec/fixtures/eras/` and
`spec/adapters/driven/postgres/lineage_spec.rb`'s own era fixtures do
for the same reason — the one deliberate exception in an otherwise
real-corpus guide.

Three pieces, and you will use all three every time your shape changes:

- **`bin/scaffold_translation <domain>`** — diffs the shape your
  bluebook currently declares against the shape the database holds,
  and writes an edge file with whatever it can infer confidently. What
  it cannot infer — an aggregate that vanished and a differently-named
  one that appeared, which look identical to "deleted, then created" —
  it refuses to guess at. That refusal is not a bug you work around; it
  is the one decision only you can make.
- **`bin/translation_audit <domain>`** — replays your edge against
  every record the database actually holds and shows you a before/after
  sample. It is the difference between "the rules type-check" and having
  actually reviewed what happens to the data.
- **the boot itself** — the first boot that finds a drifted shape *and*
  a covering edge mints the next era, in one transaction, and nothing
  else. No edge, no mint: the boot refuses instead, naming the tool
  that would fix it.

The following walkthrough exercises all three, live, against a barn
full of bins.

```ruby
require "fileutils"
require "tmpdir"

GRANGE_DB  = "hecksagain_doctest_grange"
GRANGE_DIR = Dir.mktmpdir("hecksagain-doctest-grange-")

admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{GRANGE_DB} WITH (FORCE)")
admin.exec("CREATE DATABASE #{GRANGE_DB}")
admin.close

FileUtils.mkdir_p(File.join(GRANGE_DIR, "bluebook"))

File.write(File.join(GRANGE_DIR, "bluebook/grange.bluebook"), <<~BLUEBOOK)
  Hecks.bluebook "Grange" do
    vision "A barn keeps crates, and a crate is what it holds."
    generic

    aggregate "Crate" do
      identified_by { label.value }

      attribute :label,  Label
      attribute :weight, Weight

      value_object "Label" do
        attribute :value, String
      end

      value_object "Weight" do
        attribute :value, Integer
      end

      command "Store" do
        attribute :label,  Label
        attribute :weight, Weight
        emits "Stored"
      end
    end
  end
BLUEBOOK

File.write(File.join(GRANGE_DIR, "bluebook/grange.hecksagon"), <<~HECKSAGON)
  Hecks.hecksagon "Grange" do
    Grange::Crate.persisted_by("Postgres")
  end
HECKSAGON

File.write(File.join(GRANGE_DIR, "bluebook/grange.world"), <<~WORLD)
  Hecks.world "Grange" do
    realm "Doctest"
    persisted_by("Postgres") do
      database "postgres://localhost/#{GRANGE_DB}"
    end
  end
WORLD

era_one = Hecks.boot(GRANGE_DIR)
era_one.dispatch("Grange::Crate.Store", label: { value: "c1" }, weight: { value: 10 })
Grange::Crate.count   # => 1
```

Era 1, minted, with one real crate in it — the same as any first boot.

Now the requirement lands: a crate's weight is going to grow more
fields (a unit, eventually a tare), so it earns its own value object.
At the same time, `Crate` becomes `Bin` — closer to what the warehouse
actually calls it. Two changes at once, on purpose: this is the
discriminating case, the one `bin/scaffold_translation` cannot resolve
alone.

```ruby
File.write(File.join(GRANGE_DIR, "bluebook/grange.bluebook"), <<~BLUEBOOK)
  Hecks.bluebook "Grange" do
    vision "A barn keeps bins, and a bin is what it holds."
    generic

    aggregate "Bin" do
      identified_by { label.value }

      attribute :label,    Label
      attribute :contents, Contents

      value_object "Label" do
        attribute :value, String
      end

      value_object "Weight" do
        attribute :value, Integer
      end

      value_object "Contents" do
        attribute :weight, Weight
      end

      command "Store" do
        attribute :label,    Label
        attribute :contents, Contents
        emits "Stored"
      end
    end
  end
BLUEBOOK

File.write(File.join(GRANGE_DIR, "bluebook/grange.hecksagon"), <<~HECKSAGON)
  Hecks.hecksagon "Grange" do
    Grange::Bin.persisted_by("Postgres")
  end
HECKSAGON

scaffold = `bundle exec #{File.join(InMemoryDomain::ROOT, "bin/scaffold_translation")} #{GRANGE_DIR} 2>&1`
scaffold.include?("UNCLAIMED: Crate existed and now doesn't")   # => true
```

There is the refusal, exactly as promised: `Crate` disappeared, `Bin`
appeared, and nothing tells the scaffold they are the same thing. It
wrote an edge file anyway — empty, waiting — because it would rather
hand you a file to fill in than guess and be wrong silently.

```ruby
edge_path = Dir.glob(File.join(GRANGE_DIR, "bluebook/translations/*.bluebook")).first
edge_before = File.read(edge_path)
edge_before.strip.end_with?("do\nend")   # => true
```

The edge is resolved by hand — this is the one decision that was
always going to belong to a person, not the tool:

```ruby
edge_source = File.read(edge_path)
label = edge_path[/\d+-(\h+)\.bluebook\z/, 1]
from = edge_source[/from: "(\h+)"/, 1]
resolved = <<~EDGE
  Hecks.data_translation "Grange", from: "#{from}", to: "#{label}" do
    aggregate "Bin", was: "Crate" do
      move :weight, to: "contents.weight"
    end
  end
EDGE
File.write(edge_path, resolved)
```

`was: "Crate"` answers the identity question the scaffold could not;
`move :weight, to: "contents.weight"` answers where the one field that
crossed a value-object boundary now lives. Now the audit — the step
that turns "this type-checks" into confirmation of what actually
happens to the data:

```ruby
audit = `bundle exec #{File.join(InMemoryDomain::ROOT, "bin/translation_audit")} #{GRANGE_DIR} 2>&1`
audit.include?('"weight":{"value":10}')      # => true
audit.include?('"contents":{"weight"')       # => true
audit.include?("AUDIT PASSED")               # => true
```

Before and after, side by side, over the one real record this barn
holds. That is not a type-check — it is c1's actual weight, actually
moved, shown before anything commits. Now the boot that mints:

```ruby
era_two = Hecks.boot(GRANGE_DIR)
Grange::Bin.find("c1").contents.weight.to_h   # => { value: 10 }
Grange::Bin.count                             # => 1
```

The record c1 wrote before `Bin` existed reads back through `Bin`,
nested exactly where the edge said it would be. Nothing about this was
a migration script running against production for the first time —
every step above ran against the one real record in this barn before
the mint committed.

```ruby
admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{GRANGE_DB} WITH (FORCE)")
admin.close
FileUtils.remove_entry(GRANGE_DIR)
true   # => true
```

## The other six rule kinds

The Grange edge above used two of the eight things a translation rule
can say: `was:` (an aggregate renamed) and `move` (a field crossed a
value-object boundary). The other six matter just as much, and each
one's effect on a stored record can be shown without a second Postgres
round-trip — `Hecksagain::Ports::Persistence::Lineage` is the exact
code every mint runs internally, and it answers directly:

```ruby
Move    = Hecksagain::Bluebook::IR::TranslationMove
Convert = Hecksagain::Bluebook::IR::TranslationConvert
Retype  = Hecksagain::Bluebook::IR::TranslationRetype
Entry   = Hecksagain::Ports::Persistence::Entry
Lineage = Hecksagain::Ports::Persistence::Lineage
```

**`rename`** — a field keeps its shape, only its name changes:

```ruby
lineage = Lineage.new({ cost: :amount })
entry = Entry.new(operation: "save", id: "a1", state: { cost: 100 })
lineage.translate(entry).state   # => { amount: 100 }
```

**`drop`** — a declared, deliberate acknowledgment that a field's data
does not survive. Not a silent vanishing — a line in the edge file that
says so:

```ruby
lineage = Lineage.new({}, [], [], [:legacy_note])
entry = Entry.new(operation: "save", id: "a1", state: { legacy_note: "x", kept: true })
lineage.translate(entry).state   # => { kept: true }
```

**`convert`** — a move whose value has nothing in common with its
replacement, so it needs a lookup table rather than a rename. Nested
state is read back exactly as a real adapter decodes it from JSON —
string keys, not symbols, which is why the value object below is built
that way:

```ruby
lineage = Lineage.new({}, [], [Convert.new("kind.label", "kind.label",
                                            { "biz" => "business", "pers" => "personal" })])
entry = Entry.new(operation: "save", id: "a1", state: { kind: { "label" => "biz" } })
lineage.translate(entry).state   # => { kind: { "label" => "business" } }
```

A value the table does not cover refuses the whole mint rather than
carry something unrecognized into the new era — the exhaustiveness is
the point:

```ruby
lineage = Lineage.new({}, [], [Convert.new("kind.label", "kind.label", { "biz" => "business" })])
bad = Entry.new(operation: "save", id: "a1", state: { kind: { "label" => "mystery" } })
lineage.translate(bad)   # ~> WiringError: cannot translate kind.label: "mystery" has no mapping
```

**`retype`** — the odd one out: it moves nothing at all. A value
object's own TYPE name changed while its members stayed identical, and
since stored data never carries a type name, there is nothing to
translate — `retype` only tells the era diff that the two names mean
the same shape, so it stops asking:

```ruby
lineage = Lineage.new({}, [], [], [], retypes: [Retype.new("Money", "Cash")])
lineage.retype?("Money", "Cash")   # => true
lineage.retype?("Cash", "Money")   # => false
```

**`compute`** is the one rule with no in-process implementation at
all — its SQL expression is its only meaning, run inside the era's own
compiled view, and `Lineage#translate` passes a computed field through
untouched on purpose. That is exactly why minting an edge with a
`compute` rule requires `bin/translation_audit --approve` first: a
human has to look at the before/after sample, because nothing else can
verify it. If you reach for `compute`, budget the review — it is not
optional, and the mint refuses without it.

**`rekey`** is the aggregate's own identity changing what it's computed
from — `identified_by { name.value }` becoming `identified_by { email.value }`,
say. Ordinarily this refuses outright: stored ids were minted under the
old key, and nothing in the other seven rule kinds says "these rows are
the same entity under a new key." A `rekey` rule is exactly that
declaration — SQL-only, like `compute`, with no in-process reference
implementation (`Lineage#translate` never touches an entry's `id`,
only its `state`) and the same `bin/translation_audit --approve`
requirement before it can mint. Unlike every other rule here, it takes
no `from:`/`to:` path — it isn't moving or consuming a `state` field,
only recomputing what identifies the record:

```ruby skip
aggregate("Member") do
  rekey sql: "CASE ((__s -> 'name') ->> 'value') WHEN 'Chris Young' THEN 'chris@example.com' END"
end
```

The journal row itself never changes — `aggregate_id` stays whatever it
was minted under, forever, the same immutability every other rule here
already holds itself to. What changes is what the *next* era's
compiled view resolves that row as, and what a fresh dispatch mints for
a brand-new record going forward. One known gap: `bin/merge_tail`'s own
conflict detection (`tail_merge.rb#conflict_ids`) does not yet
recognize a pre-rekey and post-rekey row as the same entity — merging a
domain whose history includes a rekey may leave both surviving as
separate, undetected duplicate heads. Resolve manually if you hit this;
teaching the merge about rekeys is real, separate work.

`retired "OldAggregate"`, declared at the edge level rather than inside
an `aggregate` block, says an aggregate is simply gone — the honest
alternative to a `was:` claim pointing at something unrelated.

## What to actually do

Change the bluebook. Run `bin/scaffold_translation`. Resolve every
`unresolved` line it leaves you — that is where the real decisions
live, not busywork to get through. Run `bin/translation_audit` and
read the sample; do not skim it. Then boot. If a `compute` or `rekey`
rule is involved, run the audit with `--approve` first, and mean it.

The domain never learns any of this happened. The bluebook you write
next describes the shape you have now, not the history that got you
here — the history lives in `translations/`, one file per edge, read
by the next person who needs to know why a field moved.
