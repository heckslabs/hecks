# Dropping one argument drops one argument

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-28.

## Context

The sequence generator malforms at most one argument per step so the check that fired is
identifiable. One of its three malformations, `drop_one`, removes a droppable argument. It
chose the argument inside the `reject` block, so each argument was tested against a fresh draw
and the call could remove several, or none, whatever the arguments were.

## Decision

`drop_one` draws the argument once and rejects that name. It removes exactly one droppable
argument, and still never the identity or an argument the runtime answers.

## Consequences

- **Seeded sequences change.** The fix changes how many draws `drop_one` takes from the
  generator's random source, so every sequence that reaches a dropped argument after the fix
  differs from the one the same seed gave before. A seed recorded as a reproduction of a
  failure before this change may no longer reproduce it; replay from the recorded steps, which
  are unchanged, and not from the seed.
- **No pinned expectation moved.** Every spec under `spec/fuzzing` was run; none pinned a seeded
  sequence that passes through `drop_one`. `spec/fuzzing/argument_drawing_spec.rb` is new and
  holds the rule: one argument dropped for every seed tried, never the identity or a needed
  fact, and every droppable argument reachable.
