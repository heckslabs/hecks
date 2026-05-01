# Bluebook on a Napkin

The whole language is below. Five rules, one example, no qualifications.

## The Whole Language

```ruby
Hecks.bluebook "Library" do
  aggregate "Book" do
    attribute :title, String
    attribute :checked_out, Boolean

    command "CheckOut" do
      then_set :checked_out, to: true
      emits "BookCheckedOut"
    end

    query "Available" do
      where checked_out: false
    end
  end

  aggregate "Reader" do
    attribute :books_out, Integer

    policy "TrackCheckouts" do
      on "BookCheckedOut"
      dispatch "IncrementCount"
    end
  end
end
```

That is a complete domain. Two aggregates, one command, one query, one policy, one event flowing between them. Everything else is commentary.

## The Five Rules

**1. Everything is an aggregate.**
`Book` and `Reader` are aggregates. There are no top-level functions, no modules, no shared state — the two aggregates above are everything that exists in this domain. Where Smalltalk says *everything is an object*, we say *everything is an aggregate*.

**2. Behavior comes in three kinds.**
`command "CheckOut"` mutates state. `query "Available"` reads it. `policy "TrackCheckouts"` reacts to an event. Three verbs, no others. The verb is the shape, not a name to invent.

**3. State changes only through commands.**
The only way `:checked_out` flips is `CheckOut`. The command takes arguments, mutates state, and emits `BookCheckedOut`. There is no setter, no callback, no back-door write. Every state change is named, validated, and witnessed by an event.

**4. Aggregates communicate through events.**
`Reader` does not import `Book`. `Reader.TrackCheckouts` listens for `BookCheckedOut` and dispatches its own command in response. No direct call, no shared object reference. Aggregates are loosely coupled by construction.

**5. The bluebook is the system.**
What you read above *is* what runs. There is no separate compiled runtime interpreting a different model — the compiler enforces byte-identity between the description and the running code. If the bluebook says it, the runtime does it. If the runtime does it, the bluebook says it. We call this the Futamura discipline.

## What Is Not on the Napkin

The runtime substrate — file I/O, persistence (the heki binary store), the bootstrap parser, the specializer engine, the host language bindings. Real, finite, and not part of the spec.

A Smalltalk image hides a fifty-thousand-line VM behind its five rules. We hide a few thousand lines of Rust behind ours. The substrate is the price of the napkin staying napkin-sized — and the discipline is keeping the substrate as small as possible so the spec can stay sovereign.

## The Wager

The wager bluebook makes is that five rules are enough — that you can describe any business domain by composing aggregates, commands, queries, and policies, and that the loss in expressivity compared to a general-purpose language is paid back many times over by the gain in mechanical generation, audit, parity, and substrate-shrinking.

If the wager holds, AI will eventually write its software in specs like this one — not because we forced it to, but because the substrate disappeared and only the spec was left.
