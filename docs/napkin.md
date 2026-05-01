# Bluebook on a Napkin

Every system has a spec and a substrate. The spec is what you tell people the language is. The substrate is what runs it. Most systems get the substrate small and let the spec sprawl — bluebook does the opposite.

These are the five rules. Everything else is implementation.

## The Five Rules

**1. Everything is an aggregate.**
A unit of state with behavior, identified by name. Aggregates are the only thing that exists.

**2. Behavior comes in three kinds.**
Commands mutate state. Queries read it. Policies react to events.

**3. State changes only through commands.**
A command takes arguments, mutates state, and emits an event. There is no setter.

**4. Aggregates communicate through events.**
A policy on one aggregate listens for events from any aggregate and dispatches a new command. There is no direct call.

**5. The bluebook is the system.**
The description and the running runtime are byte-identical by construction. There is no hidden code path.

That is it. Hold these in your head and the rest of Hecks reads like commentary.

## What Follows

From rule 1 — there are no functions, no modules, no top-level state. Only aggregates. Where Smalltalk says *everything is an object*, we say *everything is an aggregate*.

From rule 2 — the language has three verbs, not arbitrary methods. The verb is the shape, not a name to invent.

From rule 3 — every state change is named, validated, and witnessed by an event. Audit is structural, not optional.

From rule 4 — aggregates are loosely coupled by construction. You do not import another aggregate. You listen for what it emits.

From rule 5 — if the bluebook says it, the runtime does it. If the runtime does it, the bluebook says it. The compiler enforces the equivalence. This is what we call the Futamura discipline.

## What Is Not on the Napkin

The runtime substrate — file I/O, persistence (the heki binary store), the bootstrap parser, the specializer engine, the host language bindings. Real, finite, and not part of the spec.

A Smalltalk image hides a fifty-thousand-line VM behind its five rules. We hide a few thousand lines of Rust behind ours. The substrate is the price of the napkin staying napkin-sized — and the discipline is keeping the substrate as small as possible so the spec can stay sovereign.

## A Worked Example

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

Two aggregates. One command, one query, one policy. An event flows from `Book` to `Reader` without either knowing about the other. Run it and the runtime is exactly what is written here. That is the whole language.

## The Wager

The wager bluebook makes is that five rules are enough — that you can describe any business domain by composing aggregates, commands, queries, and policies, and that the loss in expressivity compared to a general-purpose language is paid back many times over by the gain in mechanical generation, audit, parity, and substrate-shrinking.

If the wager holds, AI will eventually write its software in specs like this one — not because we forced it to, but because the substrate disappeared and only the spec was left.
