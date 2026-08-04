# Commands

You are about to ship a feature, and the feature is a command: some
actor does something to your domain, and the domain either does it or
says why not. Before you write one, you need three things — the full
inventory of what a command can declare (there is nothing else), the
exceptions your caller has to be ready to catch, and the difference
between a rule you enforce going in and a guarantee you check coming
out. All three are provable in one sitting, against one small domain.

The examples below use an orchard domain: trees are planted, begin
bearing, get harvested, pruned, occasionally pressed into cider, and
eventually removed. The domain is small enough to cover in one
sitting, and realistic enough that a command letting the wrong thing
through would cost real money.

## The declaration

```ruby bluebook
Hecks.bluebook "Verger" do
  vision "Trees are planted, tended, harvested, and eventually taken out — an orchard's whole lifecycle in one small domain."
  supporting

  aggregate "Orchard" do
    description "A block of land holding trees."

    identified_by { name.value }

    attribute :name, OrchardName

    value_object "OrchardName" do
      attribute :value, String
      invariant("an orchard is named") { !value.to_s.empty? }
    end

    command "Establish" do
      role "Orchard manager"
      goal "Register a new orchard block"

      attribute :name, OrchardName

      emits "Established"
    end
  end

  aggregate "Tree" do
    description "One tree, from planting to uprooting, and everything it bears in between."

    identified_by { label.value }

    attribute :label,       TreeLabel
    attribute :variety,     Variety
    attribute :keeper,      Keeper
    attribute :fruit_count, Yield
    attribute :baskets,     list_of(Basket)

    value_object "TreeLabel" do
      attribute :value, String
      invariant("a tree is labelled") { !value.to_s.empty? }
    end

    value_object "Variety" do
      attribute :value, String
      invariant("a variety is named") { !value.to_s.empty? }
    end

    value_object "Keeper" do
      attribute :name, String
      invariant("a keeper is named") { !name.to_s.empty? }
    end

    # ONE FIELD, DEFAULTED — the only member Yield has gets `default: 0`,
    # which is what lets a fresh tree start at count 0 with no command
    # ever setting it: Instance.defaults auto-builds a value object whose
    # every field defaults, the same reason banking's Money(cents: 0,
    # currency: "USD") needs no command to touch it either.
    value_object "Yield" do
      attribute :count, Integer, default: 0
    end

    value_object "BasketWeight" do
      attribute :count, Integer
      invariant("a basket is not empty") { count.positive? }
    end

    value_object "BasketNote" do
      attribute :value, String
    end

    value_object "Basket" do
      attribute :note,   String
      attribute :weight, Integer
    end

    value_object "PruneCount" do
      attribute :count, Integer
      invariant("a prune removes at least one fruit") { count.positive? }
    end

    lifecycle :status, default: "sapling" do
      transition "Bear"   => "bearing",   from: "sapling"
      transition "Uproot" => "uprooted",  from: ["sapling", "bearing"]
    end

    command "Plant" do
      role "Orchardist"
      goal "Put a new tree in the ground"

      reference_to Orchard
      attribute :label,   TreeLabel
      attribute :variety, Variety

      emits "Planted"
    end

    # NO GIVEN HERE, ON PURPOSE — the lifecycle transition below is the
    # only gate. Call this twice and the SECOND call has nothing to blame
    # but the lifecycle itself: LifecycleRefused, not GivenNotMet.
    command "Bear" do
      role "Orchardist"
      goal "Confirm a tree has begun bearing, and note who tends it"

      reference_to Tree
      attribute :keeper, Keeper

      then_set :keeper, to: :keeper
      then_set :status,  to: "bearing"

      emits "Bore"
    end

    command "Harvest" do
      role "Picker"
      goal "Bring in one basket and count it toward the tree's yield"

      reference_to Tree
      attribute :note,   BasketNote
      attribute :weight, BasketWeight

      given("only a bearing tree is harvested") { status == "bearing" }

      then_set :baskets,     append:    { note: :note, weight: :weight }
      then_set :fruit_count, increment: :weight

      emits "Harvested"
    end

    command "Prune" do
      role "Orchardist"
      goal "Remove fruit before it drops, on purpose or by mistake"

      reference_to Tree
      attribute :count, PruneCount

      then_set :fruit_count, decrement: :count

      ensures("the yield fell by exactly the count")        { old.fruit_count.count == fruit_count.count + count.count }
      ensures("pruning never leaves fewer than zero fruit")  { fruit_count.count >= 0 }

      emits "Pruned"
    end

    command "Press" do
      role "Cidermaker"
      goal "Turn stored yield into cider, once there is enough of it"

      reference_to Tree

      given("at least ten fruit are needed to press") { fruit_count.count >= 10 }
      given("only a bearing tree is pressed")          { status == "bearing" }

      emits "Pressed"
    end

    # TWO FACTS FROM ONE ACT, same shape as banking's SafeDepositBox
    # Surrender: the tree is gone, and the plot it stood on is a separate
    # fact worth its own event, not a detail folded into the first.
    command "Uproot" do
      role "Orchardist"
      goal "Take the tree out for good"

      reference_to Tree

      emits "Uprooted"
      emits "PlotVacated"
    end
  end
end
```

Read the inventory off that file, because it is the whole file: `role`,
`goal`, one or more `attribute`s, an optional `reference_to`, zero or
more `given`s, zero or more `ensures`, zero or more `then_set`s, one or
more `emits`. A command cannot declare anything else — there is no
handler body to smuggle a side effect into.

## Wiring

```ruby boot
Hecks.hecksagon("Verger") do
  Verger::Orchard.persisted_by("Memory")
  Verger::Tree.persisted_by("Memory")
end
```

## What you must handle

Every command you write can fail in a fixed set of ways, and your
caller — a controller action, a saga step, a test — has to be ready for
whichever ones apply to it. This is the complete roster for a command
dispatch; the rest of this page proves each row once, live, against
Verger:

| raises | when | shown |
|---|---|---|
| `GivenNotMet` | a declared `given` reads false | Harvest before Bear |
| `EnsuresNotMet` | a declared `ensures` reads false, AFTER the mutation ran | over-pruning |
| `InvariantViolation` | a value object's own rule rejects the fields it was built from | an unlabelled tree |
| `LifecycleRefused` | the command names a transition the current state cannot take | bearing twice |
| `AlreadyExists` | a creating command's identity already names a record | planting the same label twice |
| `NotFound` | an acting command's identity names no record | tending a tree that was never planted |
| `AbsentArgument` | a required attribute never arrived | planting with no variety |
| `TypeMismatch` | an argument arrived in the wrong shape — a reference handed as an object is the case that costs the most in practice | an orchard passed as a hash |

Every one of these is a `StandardError` subclass under
`Hecksagain::Runtime`, and every one is the domain answering, not the
runtime breaking. A refusal is a response, not a malfunction.

## Creating vs. acting

A command either creates a new record or acts on one that already
exists, and the DSL reads this off one fact: does the command
`reference_to` its own aggregate. `Plant` doesn't — it references
`Orchard`, a different aggregate, to say which orchard the tree belongs
to — so `Plant` creates, and the facade installs it as a method on the
aggregate module itself. `Bear`, `Harvest`, `Prune`, `Press`, and
`Uproot` all `reference_to Tree`, their own aggregate, so each is a
method on the record in hand. Get this backwards in your own bluebook —
add a stray `reference_to Self` to what should be a creating command —
and it silently stops being callable the way a controller expects.

```ruby
Verger::Tree.respond_to?(:plant)    # => true
Verger::Tree.respond_to?(:harvest)  # => false
```

```ruby
orchard = Verger::Orchard.establish(name: { value: "Domaine des Merisiers" })
tree    = Verger::Tree.plant(orchard_id: orchard.id,
                              label: { value: "Elstar-1" }, variety: { value: "Elstar" })
tree.label.to_h  # => { value: "Elstar-1" }
```

A creating command's identity still has to be FRESH — dispatch `Plant`
again with a label you already used and there is no second tree, only
a collision with the one you have:

```ruby
Verger::Tree.plant(orchard_id: orchard.id, label: { value: "Elstar-1" }, variety: { value: "Elstar" })  # ~> AlreadyExists: Plant creates a Tree that already exists
```

## `given` — the rule you enforce going in

A `given` reads the record as it stands BEFORE any mutation and refuses
if it doesn't like what it sees. The refusal is `GivenNotMet`, and the
message is exactly the description you wrote — nothing templated, no
translation between what you declared and what the caller reads:

```ruby
tree.harvest(note: { value: "too soon" }, weight: { count: 4 })  # ~> GivenNotMet: only a bearing tree is harvested
```

Multiple givens run in the order you wrote them, and the FIRST one that
reads false is the one your caller sees — the others never run at all.
`Press` declares its fruit-count check before its bearing check, so a
tree that fails both still reports only the first:

```ruby
tree2 = Verger::Tree.plant(orchard_id: orchard.id,
                            label: { value: "Elstar-2" }, variety: { value: "Elstar" })

tree2.press  # ~> GivenNotMet: at least ten fruit are needed to press
```

That tree is also not bearing, which would fail `Press`'s second given
just as surely — but you will never see that message from this call,
because the first refusal wins and the dispatch stops there. Write your
givens with the cheapest or most-likely-to-fail check first if you want
your callers reading the most useful message; the runtime will not
reorder them for you.

`Bear` carries no `given` at all — its lifecycle transition is the only
gate it has, and that is enough on its own:

```ruby
tree.bear(keeper: { name: "R. Aubert" })
tree.status  # => "bearing"
```

Call it again and there is no state left for the transition to move
from — the refusal is `LifecycleRefused`, not `GivenNotMet`, because
nothing declared on `Bear` itself objected:

```ruby
tree.bear(keeper: { name: "Someone else" })  # ~> LifecycleRefused: Bear refused
```

## `ensures` — the guarantee you check coming out

A `given` reads the record before the mutation runs. An `ensures` reads
it AFTER — against the settled state, with `old` naming the record as
it stood before, so you can assert a relationship between the two
rather than just a fact about one. This is how you catch a command that
computed the right thing for the wrong reason, or the wrong thing
outright, in a test instead of in production: `enforce_ensures` is the
step right after `apply_mutations` in the dispatch pipeline, and it
still sits before `save` — a failed `ensures` never reaches the store.

`Prune` carries two. The first is an identity that arithmetic alone
already guarantees, so it never actually fires — it is there as a
written-down guarantee, not a trap:

```ruby
tree.harvest(note: { value: "first pick" },  weight: { count: 6 })
tree.harvest(note: { value: "second pick" }, weight: { count: 3 })
tree.fruit_count.to_h  # => { count: 9 }

tree.prune(count: { count: 4 })
tree.fruit_count.to_h  # => { count: 5 }
```

The second is the one that earns its place — nothing upstream of it
stops you from pruning more fruit than the tree has, so it is the only
thing standing between an over-eager prune and a negative yield sitting
in your store:

```ruby
tree.prune(count: { count: 20 })  # ~> EnsuresNotMet: pruning never leaves fewer than zero fruit
```

`Prune` never declared a `given` bounding `count` against the current
yield — it could have, and that would have caught this earlier, before
the mutation ran at all. The `ensures` catches it anyway, after the
fact, which is the whole point of having both: a `given` is a rule you
remembered to write going in, an `ensures` is a guarantee that holds
regardless of what you remembered.

## `then_set` — one op per field, and the op is a real decision

Four operations, and which one you reach for is not stylistic — it is
the difference between overwriting a field, growing a list, and doing
arithmetic on one:

**`to:`** replaces the field outright, from an argument or a literal.
`Bear` does both in the same command:

```ruby
tree.status       # => "bearing"
tree.keeper.to_h  # => { name: "R. Aubert" }
```

(`then_set :status, to: "bearing"` is redundant here — the lifecycle
transition already moves `status` to `"bearing"` on its own — shown
because a literal target is legal, not because this one is load-bearing.)

**`append:`** grows a list attribute by one value object, built from
the fields you name. When one of those fields is itself a value object
with exactly one member, it flattens into the scalar the list element
actually declares — `weight:` arrives as a `BasketWeight` (one Integer
field) and lands in `Basket#weight`, a bare `Integer`:

```ruby
tree.baskets.map(&:to_h)  # => [{ note: "first pick", weight: 6 }, { note: "second pick", weight: 3 }]
```

Hand `append:` a value object with more than one member for a scalar
slot and it has no single field to flatten to — that refusal is
`TypeMismatch: ... cannot stand in for a scalar`, not shown here
because nothing in this domain can trigger it, but worth knowing before
you design a value object that might.

**`increment:` / `decrement:`** do arithmetic on a numeric field —
either a plain Integer or, as here, the one shared Integer field
between two value objects. `Yield#count` and `BasketWeight#count`
share a name and a type, the same way banking's `Money#cents` and
`PositiveMoney#cents` do, and that shared name is what lets the
runtime know which field to add — already proven above, alongside the
`ensures` that watches it:

```ruby
tree.fruit_count.to_h  # => { count: 5 }
```

## `emits` — a promise made after the write, not before

Events are announced only once the record has actually been saved:
`save` runs before `emit` in the dispatch order, so a command that gets
all the way to raising `EnsuresNotMet` never announces anything —
there is nothing after a refusal for a caller to react to. Read them
back off the record:

```ruby
tree.events.map(&:name)  # => ["Planted", "Bore", "Harvested", "Harvested", "Pruned"]
```

One command can announce more than one fact. `Uproot` does — the tree
is gone, and the plot it stood on is vacant, and those are two
different things a reaction downstream might care about separately:

```ruby
tree.uproot
tree.events.last(2).map(&:name)  # => ["Uprooted", "PlotVacated"]
```

## The argument gate

Before any rule runs, before the record is even hydrated, a command's
arguments are checked for shape. Four things to know before you wire a
caller to one of these:

A required attribute that never arrives refuses before anything else
happens — no partial record, no half-run mutation:

```ruby
Verger::Tree.plant(orchard_id: orchard.id, label: { value: "Elstar-3" })  # ~> AbsentArgument: Plant was not given variety
```

A value object's own invariant travels with it into every command that
carries one, checked the moment the argument is coerced — before
`Plant`'s given, before its identity is even looked up:

```ruby
Verger::Tree.plant(orchard_id: orchard.id, label: { value: "" }, variety: { value: "Elstar" })  # ~> InvariantViolation: TreeLabel invariant violated — a tree is labelled
```

A value object arrives as its fields, plainly — `{ value: "Elstar" }`,
`{ count: 6 }` — never as a constructed instance. A reference to
another aggregate, by contrast, arrives as a bare id — the string
`orchard.id`, not an object describing the orchard:

```ruby
Verger::Tree.plant(orchard_id: orchard.id, label: { value: "Elstar-4" }, variety: { value: "Elstar" }).variety.to_h  # => { value: "Elstar" }
```

Hand a reference the object it stands for instead of the id, and it
refuses — this is the mistake that costs the most in practice, because
it is the one that LOOKS like it should work (you have the orchard
right there, why not pass it):

```ruby
Verger::Tree.plant(orchard_id: { name: "Domaine des Merisiers" }, label: { value: "Elstar-5" }, variety: { value: "Elstar" })  # ~> TypeMismatch: a reference is an id, and orchard_id arrived as an object
```

And a command acting on an identity that names no record refuses with
`NotFound`, not a nil you have to check for yourself:

```ruby
runtime.dispatch("Verger::Tree.Bear", label: "never-planted", keeper: { name: "Someone" })  # ~> NotFound: no Tree with label
```

## Refusals leave state untouched

A refusal that happens after mutation but before save — an `ensures`,
mainly — never reaches the store. The over-prune above raised before
anything was written, and a fresh read proves it: the tree's yield is
still what the last SUCCESSFUL prune left it at, not the negative
number the refused call tried to write.

```ruby
Verger::Tree.find(tree.id).fruit_count.to_h  # => { count: 5 }
```

Nothing about this is specific to `ensures` — a `given` that refuses,
a `LifecycleRefused`, a dangling reference, all stop the same dispatch
pipeline before `save` ever runs. A command either completes and
persists, or it refuses and the record you already had stands exactly
as it was.
