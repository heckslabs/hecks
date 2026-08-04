# Aggregates and value objects

This guide covers the decisions involved in modeling domain state:
whether a concept gets an identity of its own or is just a value two
records might share, and whether an invalid shape is refused at the
point a caller sends it or only discovered later against production
data. Each section below covers one such decision, along with a
demonstration of what happens when it is made incorrectly.

The domain used throughout is a pottery workshop — kilns, studios, and
the pieces thrown in them. It is small, but exercises a composite key,
a closed vocabulary, and a reference that is deliberately misused to
demonstrate a refusal. Everything below runs against the one
declaration:

```ruby bluebook
Hecks.bluebook "Atelier" do
  vision "A workshop, its kilns, and the pieces thrown and fired there."
  supporting

  aggregate "Kiln" do
    description "A kiln in the workshop, referenced by the pieces fired inside it."

    identified_by { tag.value }

    attribute :tag, KilnTag

    value_object "KilnTag" do
      attribute :value, String
      invariant("a kiln is tagged") { !value.to_s.empty? }
    end

    lifecycle :status, default: "cold" do
      transition "Fire" => "hot", from: "cold"
      transition "Cool" => "cold", from: "hot"
    end

    command "Install" do
      role "Workshop hand"
      goal "Put a kiln into service"

      attribute :tag, KilnTag

      emits "KilnInstalled"
    end

    command "Fire" do
      reference_to Kiln
      emits "KilnFired"
    end
  end

  aggregate "Studio" do
    description "A room in the workshop, known by its district and the number on its door — one studio in a building of several."

    # A STUDIO NUMBER REPEATS ACROSS DISTRICTS. Studio 3 in the north wing
    # and studio 3 in the east wing are not the same room, so neither field
    # alone says which studio this is — the identity is their JOIN, in
    # declaration order.
    identified_by do
      district.value
      studio_number.value
    end

    attribute :district,      District
    attribute :studio_number, StudioNumber
    attribute :focus,         Focus

    value_object "District" do
      attribute :value, String
      invariant("a district is named") { !value.to_s.empty? }
    end

    value_object "StudioNumber" do
      attribute :value, Integer
      invariant("a studio is numbered from one") { value.positive? }
    end

    # A CLOSED VOCABULARY, WRITTEN THE LONG WAY — `one_of do member ... end`,
    # a block on the value object itself. More on the other spelling below.
    value_object "Focus" do
      attribute :value, String

      one_of do
        member value: "ceramics"
        member value: "glass"
        member value: "textile"
      end
    end

    command "Establish" do
      role "Workshop manager"
      goal "Open a studio for a given discipline"

      attribute :district,      District
      attribute :studio_number, StudioNumber
      attribute :focus,         Focus

      emits "StudioEstablished"
    end
  end

  aggregate "Piece" do
    description "One thing thrown on the wheel, from clay to glaze to the kiln."

    identified_by { serial.value }

    attribute :serial,     Serial
    # A VALUE OBJECT'S DEFAULT FILLS ITS FIELDS, not the object itself — see
    # the refusal below for what happens if you write this as a bare scalar.
    attribute :price,      Price, default: { cents: 0 }
    # `admits:` NAMES A SET DECLARED ELSEWHERE rather than restating it — the
    # discipline vocabulary lives on Studio::Focus, above, so this reads it
    # instead of copying "ceramics"/"glass"/"textile" a second time for
    # something to eventually drift out of sync with.
    attribute :discipline, Discipline, admits: "Studio::Focus"
    # THE INLINE SHORTHAND — `one_of` called directly as an attribute's type,
    # synthesising a "Finish" value object for itself. The other spelling
    # from Studio::Focus, above, and the one that CANNOT be nested — see the
    # closed-sets section below.
    attribute :finish,     one_of("matte", "glossy")
    attribute :glaze,      Glaze
    attribute :tags,       list_of(Tag)

    reference_to Kiln, as: :fired_in
    has_one Studio
    has_many Studios

    value_object "Serial" do
      # A DECLARED PATTERN, checked when the bluebook loads — not when a bad
      # serial finally shows up in production. See the refusal below for what
      # a pattern the checker cannot admit looks like.
      attribute :value, String, pattern: '^[A-Z]{2}-[0-9]{4}$'
    end

    value_object "Price" do
      attribute :cents, Integer, default: 0
      invariant("a price is never negative") { cents >= 0 }
    end

    value_object "Discipline" do
      attribute :value, String
    end

    value_object "Coat" do
      attribute :value, String

      one_of do
        member value: "single"
        member value: "double"
      end
    end

    # A VALUE OBJECT HOLDING A VALUE OBJECT — Glaze's `coat` field is typed
    # Coat, not String, so Coat's own closed set travels with it. More on
    # this shape at the end of the guide.
    value_object "Glaze" do
      attribute :color, String
      attribute :coat,  Coat
    end

    value_object "Tag" do
      attribute :value, String
      invariant("a tag names something") { !value.to_s.empty? }
    end

    command "Throw" do
      role "Potter"
      goal "Start a new piece on the wheel"

      attribute :serial,     Serial
      attribute :discipline, Discipline, admits: "Studio::Focus"
      attribute :finish,     Finish
      attribute :glaze,      Glaze
      # OPTIONAL: a caller may leave this out entirely — no argument, no
      # refusal for one missing. Left out, the head's own `default:` above
      # still fills the field once the record exists (see below).
      attribute :price,      Price, optional: true

      reference_to Kiln, as: :fired_in
      reference_to Studio, as: :studio

      emits "PieceThrown"
    end

    command "Reprice" do
      reference_to Piece
      attribute :price, Price
      then_set :price, to: :price
      emits "PieceRepriced"
    end

    command "Tag" do
      reference_to Piece
      attribute :tag, Tag
      then_set :tags, append: { value: :tag }
      emits "PieceTagged"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("Atelier") do
  Atelier::Kiln.persisted_by("Memory")
  Atelier::Studio.persisted_by("Memory")
  Atelier::Piece.persisted_by("Memory")
end
```

## Identity: one field, or several — and why that is not a style choice

The first decision, before any attribute, is whether a concept has a
lifecycle of its own, addressable by a key that never changes meaning —
an aggregate — or is just a value, interchangeable with any other
instance carrying the same fields — a value object. Getting this wrong
means either building CRUD around something that was never more than a
number, or letting two genuinely different records collide because
nothing told the runtime how to tell them apart.

`identified_by` is where an aggregate declares which field answers
"which one is this." A single path reads back exactly as written — the
tag is the kiln's identity:

```ruby
kiln = Kiln.install(tag: { value: "kiln-01" })

kiln.id   # => "kiln-01"
```

A composite identity reads back as its parts joined by `:`, in the
order declared — Studio needs one because a studio number by itself
does not say which building it is in:

```ruby
studio = Studio.establish(district: { value: "north" }, studio_number: { value: 3 }, focus: { value: "ceramics" })

studio.id   # => "north:3"
```

This is the actual purpose of `identified_by`: two studios with the
same district and number are not two studios that happen to agree —
they are the same record, and a second `Establish` against that pair
is not a fresh room, it is a duplicate:

```ruby
Studio.establish(district: { value: "north" }, studio_number: { value: 3 }, focus: { value: "glass" })   # ~> AlreadyExists: already exists
```

That refusal is the whole reason `identified_by` exists. If two
records can carry the same fields and still be two different things (a
customer and their twin), you need a field that actually distinguishes
them, or your aggregate silently collapses cases the business
considers distinct. If two records with the same fields ARE the same
thing (a studio, known by where it is), `identified_by` is what lets
the runtime catch a caller who tries to open it twice. This is not a
modelling nicety — it is the difference between a domain that notices
a duplicate and one that quietly overwrites a record because two
callers happened to agree on a name.

## What an attribute actually promises

Every `attribute` line is a promise about what a field can hold and
what happens when a caller gets it wrong. The first decision is scalar
or value object: a bare `String` or `Integer` carries no rules of its
own, so any invariant, pattern, or closed set has to live wherever the
attribute is declared — and if you forget it on one command, that
command is the hole. A value object carries its rules once, wherever
it is used. If a field means something on its own (a price that can't
go negative, a serial that must look a certain way), give it a value
object; if it is really just a scalar with a name, a `String` is
honest about that. Guess wrong here and you either write the same
validation four times (and eventually forget one), or you wrap a
paint-color string in ceremony nothing ever checks.

Throw a piece without ever mentioning `price` — the command marked it
optional, and the head's `default:` fills the field anyway, because
`default:` is read when the record is built, not when a command
happens to supply the value:

```ruby
piece = Piece.throw(serial: { value: "AT-0001" }, discipline: { value: "ceramics" },
                     finish: { value: "matte" }, glaze: { color: "celadon", coat: { value: "single" } },
                     fired_in: "kiln-01", studio: "north:3")

piece.price.to_h    # => { cents: 0 }
piece.finish.to_h   # => { value: "matte" }
```

This is where `default:` becomes a trap. `price` is typed `Price` — a
value object — so its default has to fill Price's own fields
(`default: { cents: 0 }`, exactly as declared above). Writing a bare
scalar instead still lets the bluebook load — it fails later, at every
single create, because the value object wants its fields and gets a
number instead:

```ruby
def atelier_bad_default
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Hecks.bluebook("AtelierBadDefault") do
      aggregate "Thing" do
        identified_by { thing_id.value }
        value_object("Price") { attribute :cents, Integer }
        attribute :price, Price, default: 0
      end
    end
  end
end

atelier_bad_default   # ~> Malformed: a default fills its FIELDS
```

That refusal fires the moment the bluebook is declared, not the moment
someone forgets to pass `price`. A default that cannot describe the
type it defaults is a bug you would otherwise ship and discover only
when every create using it fails.

A pattern is refused the same way — at declaration, not at the first
bad value. `pattern:` only admits regexes every engine reads
identically (explicit ranges, alternation, anchors); lookahead and the
`\d`/`\w` perl classes are refused outright, because they mean
different things — ASCII here, Unicode there — depending on which
engine reads them:

```ruby
def atelier_bad_pattern
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Hecks.bluebook("AtelierBadPattern") do
      aggregate "Thing" do
        identified_by { thing_id.value }
        value_object("Code") { attribute :value, String, pattern: '^(?=.*[A-Z]).+$' }
        attribute :code, Code
      end
    end
  end
end

atelier_bad_pattern   # ~> Malformed: uses a lookahead
```

A pattern that IS admitted still refuses a value that does not match
it — that check runs at the door, when a caller actually offers a
serial, not buried inside a predicate three commands later:

```ruby
Piece.throw(serial: { value: "at-1" }, discipline: { value: "ceramics" }, finish: { value: "matte" }, glaze: { color: "x", coat: { value: "single" } }, fired_in: "kiln-01", studio: "north:3")   # ~> TypeMismatch: must match
```

And `admits:` refuses the same way, for a set declared somewhere else
entirely — `discipline` names `Studio::Focus` rather than restating
its members, so a caller who ships a discipline the workshop's studios
don't recognise is refused with the SAME vocabulary Studio itself
enforces, not a second list that could drift from the first:

```ruby
Piece.throw(serial: { value: "AT-0009" }, discipline: { value: "stone" }, finish: { value: "matte" }, glaze: { color: "x", coat: { value: "single" } }, fired_in: "kiln-01", studio: "north:3")   # ~> InvariantViolation: got "stone"
```

## Where a rule actually belongs

A value object's `invariant` is not a validation attached to one
command — it travels with the type, into every command that carries
it. That is what `invariant` provides: the rule is written once, on
the value, and every future command that accepts that value inherits
it whether the author remembers to add it or not. The alternative — a
`given` repeated on each command that touches price — can hold for the
first several commands and silently stop holding on a later one added
without noticing the pattern.

`Price` declared its invariant once, above: `cents >= 0`. It fires on
two commands that have nothing else in common — the creating `Throw`
and the later `Reprice` — because both merely accept a `Price`:

```ruby
Piece.throw(serial: { value: "AT-0002" }, discipline: { value: "ceramics" }, finish: { value: "matte" }, glaze: { color: "x", coat: { value: "single" } }, fired_in: "kiln-01", studio: "north:3", price: { cents: -5 })   # ~> InvariantViolation: a price is never negative

piece.reprice(price: { cents: -1 })   # ~> InvariantViolation: a price is never negative
```

Neither command wrote that rule, and neither command could get it
wrong — the rule lives on the value, not on its callers, so any future
command that accepts `Price` inherits it automatically:

```ruby
piece.reprice(price: { cents: 500 })

piece.price.to_h   # => { cents: 500 }
```

## Closed vocabularies, and the one that will not nest

`one_of` ships a fixed vocabulary — a field that can only ever be one
of the values named, refused at the door for anything else. It has two
spellings, and using the wrong one in the wrong place produces a crash
while the bluebook is still being written, rather than a clean
declaration.

The block form lives ON the value object — `Studio::Focus`, above, is
one. It reads well when the closed set is worth naming as its own type
(you saw it refuse a bad discipline already, borrowed by `admits:`;
here it is refusing directly):

```ruby
Studio.establish(district: { value: "south" }, studio_number: { value: 9 }, focus: { value: "bronze" })   # ~> InvariantViolation: got "bronze"
```

The inline shorthand skips the ceremony — `attribute :finish,
one_of("matte", "glossy")`, on `Piece`'s head, above — synthesising a
`Finish` value object without you naming it anywhere else. Reach for
this one when the set is small, local, and not worth a name anyone
else will ever reuse.

The trap: the inline shorthand desugars by calling `one_of` on
whichever builder currently has `self` — and a nested `value_object`
block already defines its own `one_of`, for closed-set members. Writing
the shorthand inside a `value_object` block does not synthesize a
closed set — it calls the wrong `one_of`, with the wrong arity, and the
bluebook does not load:

```ruby
def atelier_bad_one_of
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Hecks.bluebook("AtelierBadOneOf") do
      aggregate "Thing" do
        identified_by { thing_id.value }
        attribute :box, Box

        value_object "Box" do
          attribute :size, one_of("small", "large")
        end
      end
    end
  end
end

atelier_bad_one_of   # ~> ArgumentError: wrong number of arguments
```

`Glaze`, above, needed exactly this shape — a closed set (`Coat`,
`single` or `double`) held INSIDE another value object — and the
workaround is already sitting in its own declaration: `Coat` is its
own sibling value object, block form, and `Glaze` just holds it by
name. Nothing about the shorthand's convenience is worth reaching for
once a value object is going to hold the set rather than an attribute
directly — the sibling spelling always works, and the inline one only
works when it is not nested.

## A field that grows

`list_of` declares a repeating field — not set once, but appended to
by whichever commands say so. A fresh piece starts with no tags at
all:

```ruby
piece.tags   # => []
```

`Tag`, declared on `Piece`'s head above, carries its own invariant —
"a tag names something" — and `list_of` does not exempt an appended
element from it. Every element built by `append:` goes through the
same construction a bare value would, invariant included:

```ruby
piece.tag(tag: { value: "glossy-edge" })

piece.tags.map(&:to_h)   # => [{ value: "glossy-edge" }]

piece.tag(tag: { value: "" })   # ~> InvariantViolation: a tag names something
```

The rule you declared once on `Tag` holds for element one and for
element four hundred — a `list_of` field is not a place invariants
quietly stop applying.

## Pointing at another aggregate

A reference is how one aggregate names another, and getting the shape
wrong here does not fail loudly at declaration — it fails silently
later, when code reads `piece.studios` expecting a list and gets `nil`
instead.

`reference_to Target` is the base form — it mints an attribute named
`target_id` by default, or whatever you pass as `as:` (`Piece` used
`as: :fired_in` for its kiln, above):

```ruby
piece.fired_in   # => "kiln-01"
```

That is a bare id — a String — not a nested object. A reference IS an
id, so an id is the only shape it is stored as; hand it an object
instead (the shape you would reach for reflexively, wrapping "the
kiln" the way you would wrap any other field) and the runtime refuses
it at the door, by name, rather than let a wrapped reference travel
quietly into storage:

```ruby
Piece.throw(serial: { value: "AT-0010" }, discipline: { value: "ceramics" }, finish: { value: "matte" }, glaze: { color: "x", coat: { value: "single" } }, fired_in: { value: "kiln-01" }, studio: "north:3")   # ~> TypeMismatch: arrived as an object
```

`has_one` and its alias `belongs_to` are sugar over the same
`reference_to` — the only difference is the attribute name: no `_id`
suffix, because the field already reads as a relationship (`studio`,
not `studio_id`, from `Piece`'s `has_one Studio` above):

```ruby
piece.studio   # => "north:3"
```

One direction only: if `Studio` were to declare `reference_to Piece`
back, the bluebook would refuse to build — two aggregates pointing at
each other is not a modelling choice this language leaves open, since
neither side would be a boundary a caller could reason about alone.
`spec/dsl_spec.rb`'s "refuses two aggregates that reference each
other" is where that refusal is proven; not reproduced here, since
demonstrating it live would mean breaking this very domain to show it.

One case to note in particular: `has_many` reads like it should
produce a list — it is spelled with the plural of the target (`Piece`
wrote `has_many Studios`, above) — but it singularizes the target back
down to the aggregate it actually names (`Studio`) and mints a single
scalar reference under the plural attribute name. It is sugar for
exactly one relationship, not a one-to-many: a real list of references
has no precedent in this language, because `list_of` is checked
everywhere as a list of value objects, not references. `has_many`
looks like the collection form and is not one — the field it produces
is `nil` until set, the same as any other unset reference, never `[]`:

```ruby
piece.studios   # => nil
```

If what you actually need is a one-to-many, `has_many` will not give
it to you — that is a real relationship this language does not have a
direct spelling for yet, and reaching for the sugar here just hides
the gap behind a name that sounds right.

## A value object holding a value object

`Glaze`, above, holds `coat`, itself a value object — nesting is
ordinary, and every invariant on the inner type still fires when the
outer one is built:

```ruby
piece.glaze.to_h   # => { color: "celadon", coat: { value: "single" } }
```

Reaching a nested scalar from a query — `pizza.price_cents.cents`, in
the language's own corpus — is its own small topic, with its own
rules about where a dotted path is allowed to land; see
[queries and read models](queries-and-read-models.md) for the full
treatment.

## Where to go next

- **[Getting started](getting-started.md)** — the whole shape of the language in one sitting,
  if you have not read it yet.
- **[Commands](commands.md)** — everything a command may do and refuse, including
  postconditions.
- **[Wiring](wiring.md)** — the hecksagon and world in full: adapters, ports,
  per-deployment values.
