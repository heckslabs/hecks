# Getting started

I am going to show you the whole shape of this language in one sitting —
a domain declared, wired, booted, and refused. Not a tour of features.
One small thing, done completely.

First, what you are looking at. A `.bluebook` file declares a business
domain — its aggregates, their rules, what they may do and what they
must refuse — and the runtime boots that declaration directly. There is
no handler body anywhere, no class you write, no schema you migrate.
The domain is data. Everything this project can do — diff a domain,
store it, translate it across versions, verify it statically — follows
from that one choice. *Le fond des choses* : if it is data, it can be
read; and what can be read can be checked.

## What you need

This is a research language, and I will not pretend otherwise. There is
no gem. You clone the repository, and the repository is the tool:

```sh
git clone https://github.com/chrisyoung/hecksagain
cd hecksagain
bundle install
bin/console          # boots the pizzas example — try it first
```

Postgres is optional — everything here boots against the in-memory
adapter. You will want Postgres the day you care about schema
evolution, and there is a guide for that day.

## The first declaration

A domain about pressed flowers. Small enough to hold in one hand,
real enough to refuse things.

```bluebook
Hecks.bluebook "Herbier" do
  vision "Pressed specimens, labelled and mounted — nothing enters the folio unnamed."
  generic

  aggregate "Specimen" do
    description "One pressed plant, from collection to mounting."

    identified_by { label.value }

    attribute :label,     Label
    attribute :notes,     list_of(Note)

    value_object "Label" do
      attribute :value, String
      invariant("a specimen is named") { !value.to_s.empty? }
    end

    value_object "Note" do
      attribute :text, String
    end

    lifecycle :state, default: "pressed" do
      transition "Mount" => "mounted", from: "pressed"
    end

    command "Collect" do
      role "Botanist"
      goal "Bring a specimen into the folio"

      attribute :label, Label

      emits "Collected"
    end

    command "Annotate" do
      role "Botanist"
      goal "Record an observation on the sheet"

      reference_to Specimen
      attribute :note, Note

      given("a mounted sheet is closed") { state == "pressed" }

      then_set :notes, append: { text: :note }

      emits "Annotated"
    end

    command "Mount" do
      role "Botanist"
      goal "Fix the specimen to its sheet"

      reference_to Specimen

      emits "Mounted"
    end
  end
end
```

Read it once as prose before you read it as code. An aggregate is the
thing with identity — two specimens with the same label ARE the same
specimen, which is exactly what `identified_by` declares. A value
object has no identity at all; a `Label` is only its value, and its
invariant travels with it everywhere the value goes. The lifecycle
names the states a specimen may hold and the one transition between
them. And every command says three things: what it needs, what it
refuses (`given`), and what it announces (`emits`). There is nothing
else to a command. That is not a simplification — it is the inventory.

## Wiring

The declaration says nothing about storage, deliberately. Where a
domain's state lives is a decision, and decisions are made in the
`.hecksagon` — one line here:

```ruby boot
Hecks.hecksagon("Herbier") { Herbier::Specimen.persisted_by("Memory") }
```

Memory for now. The same domain binds to Sqlite or Postgres by changing
this one word, and the domain never learns which was chosen.

## Using it

Booting installs the door — your aggregates arrive as plain Ruby
constants, a creating command as a module method, everything else as a
method on the record in hand:

```ruby
specimen = Specimen.collect(label: { value: "Achillea millefolium" })

specimen.state                 # => "pressed"
specimen.notes                 # => []
```

Commands return the record, so a session chains the way a narrative
does:

```ruby
specimen.annotate(note: { text: "collected at the tree line" })
specimen.mount

specimen.state                 # => "mounted"
specimen.notes.map(&:to_h)     # => [{ text: "collected at the tree line" }]
specimen.events.map(&:name)    # => ["Collected", "Annotated", "Mounted"]
```

Notice what you did not write: no `save`, no repository call, no id
passed by hand. Identity was declared once, and the door carries it.

## The refusals

Now the half of the language most systems treat as an afterthought.
Try to annotate the mounted sheet:

```ruby
specimen.annotate(note: { text: "too late" })   # ~> GivenNotMet: a mounted sheet is closed
```

And try to collect a specimen with no name:

```ruby
Specimen.collect(label: { value: "" })          # ~> InvariantViolation: a specimen is named
```

Two different refusals, and the difference matters. The `given` is the
command's own rule — it reads the aggregate's state and says no on its
behalf. The invariant is the value object's rule — it travels with
`Label` into every command that carries one, declared once, enforced
everywhere. Neither is an exception in the Ruby sense. A refusal is the
domain saying no, in words you wrote, and the runtime treats it as half
of what the domain means. *Un refus est une réponse* — a refusal is an
answer, not a failure to answer.

One more thing, and it is the point of the whole arrangement: every
example on this page was executed against the real runtime before you
read it, claims and refusals both, by `spec/guides_spec.rb`. This guide
cannot drift from the language, because the suite would go red the
moment it did. Documentation that is not read by anything can disagree
with anything — so here, everything is read.

## Where to go next

- **aggregates-and-value-objects** — identity in full, composite keys,
  defaults, patterns, closed sets, references between aggregates.
- **commands** — everything a command may do and refuse, including
  postconditions.
- **wiring** — the hecksagon and world in full: adapters, ports,
  per-deployment values.
- **schema-evolution** — what happens when a domain's shape changes and
  its data must survive; the reason Postgres earns its place.

— Miette
