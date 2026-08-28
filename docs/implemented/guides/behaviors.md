# Behaviors

A `.behaviors` file is a set of hand-curated examples of how a domain is
used, written in the domain's own vocabulary: one situation, one command
(or query), one expectation, per test. It is not a fuzzer, not a
parameterized test matrix, not a fixture format — there are no loops, no
`cases` block, no generating examples from JSON. If a situation can't be
written as a `.behaviors` test, that's a finding about the bluebook (a
missing command, a missing query), not a gap in this DSL.

This guide teaches the DSL's own vocabulary using chess as the running
example — turn order, blocking, occupancy, capture, and a graveyard that
records what fell — because those are real rules worth showing refused,
not because chess ships with hecks. The examples this page actually
*runs* are `examples/pizzas/bluebook/pizzas.behaviors`, the real,
in-repo corpus member.

## `vision` and `loads`

Every `.behaviors` file opens with a one-line `vision` (what these
examples are examples *of*) and a `loads` line naming the exact files to
boot — relative to the `.behaviors` file itself, not to a directory
convention or a same-stem guess:

```ruby skip
Hecks.behaviors "Chess" do
  vision "Examples of how a game of chess is played through this domain."
  loads "chess.bluebook", "chess.hecksagon"

  # ... tests go here
end
```

Both are required. A file with no `loads` refuses to parse, naming the
fix directly, because scope is a fact the file declares — never inferred
from the filesystem or from a bluebook sharing its stem.

## `test`, `tests`, `setup`, `input`, `expect`

One `test "description" do ... end` block is one example. Inside it:

- `tests` names the command or query under test — `on:` an aggregate for
  a bare name, or a dotted string taken as a literal fully-qualified
  name (`"Chess::Graveyard.Fallen.OfSide"`). `kind:` is `:command`
  (the default) or `:query`.
- `setup` dispatches commands, in order, to put the domain into the
  situation the test is about. Arguments pass through verbatim.
- `input` supplies the arguments for the command or query actually under
  test.
- `expect` checks the result — see below.

```ruby skip
test "Black may not move first" do
  tests "MoveKnight", on: "Game"
  setup  "CreateGame",  label: "g"
  setup  "PlaceKnight", label: "g", id: "bn", square: { file: 1, rank: 7 }, color: { value: "black" }
  input  label: "g", id: "bn", to: { file: 2, rank: 5 }
  expect refused: "it is that color's turn"
end
```

## `expect`

Five things, and only these:

| key | checks |
|---|---|
| `ok: true` | the dispatch or query succeeded |
| `refused: "substring"` | the dispatch or query refused, with a message containing this text |
| `emits: [ordered, exact]` | exactly these event names, in this order |
| `count: N` | a query returned this many rows (queries only) |
| `<field>: value` | an aggregate-level field equals this, value-object-aware — bare (`kind: "bishop"`) and wrapped (`kind: { value: "bishop" }`) both compare equal |

Any other key names none of these five and fails, naming them.

```ruby skip
test "a move cascades into PlyAdvanced" do
  tests "MoveKnight", on: "Game"
  setup  "CreateGame",  label: "g"
  setup  "PlaceKnight", label: "g", id: "wn", square: { file: 1, rank: 0 }, color: { value: "white" }
  input  label: "g", id: "wn", to: { file: 2, rank: 2 }
  expect emits: ["KnightMoved", "PlyAdvanced"]
end
```

`emits:` sees a real policy cascade, not just the tested command's own
immediate event — there is no `kind: :cascade` in this DSL because a
cascade is not a special case here, it is simply on, always. A domain
where moving a piece triggers a policy that advances the game's own ply
is exactly the case `emits:` is written to see through.

## Refusals

Every `Hecks::Runtime` refusal class (`GivenNotMet`, `EnsuresNotMet`,
`LifecycleRefused`, `InvariantViolation`, `AlreadyExists`, `NotFound`, and
the rest of `Hecks::Runtime::DOMAIN_REFUSALS`) satisfies `refused:`.
Where the refusal happens matters: a refusal raised by a `setup` dispatch
is always an **error** — the example never reached the situation it
claims to test — while a refusal from the command or query actually
under test is checked against `expect refused:` as a **fail** or a
**pass**, depending on whether it matches.

```ruby skip
test "a capture refuses a piece already captured" do
  tests "CaptureBishop", on: "Game"
  setup  "CreateGame",    label: "g"
  setup  "PlaceBishop",   label: "g", id: "bb", square: { file: 2, rank: 2 }, color: { value: "black" }
  setup  "CaptureBishop", label: "g", id: "bb", side: { value: "black" }
  input  label: "g", id: "bb", side: { value: "black" }
  expect refused: "status is"
end
```

## Reading state back

A `.behaviors` test never invents a new way to read state — the only
read is a **declared query**, dispatched exactly like a command:

```ruby skip
test "a captured piece is recorded in the graveyard" do
  tests "Chess::Graveyard.Fallen.OfSide", kind: :query
  setup  "CreateGame",    label: "g"
  setup  "PlaceBishop",   label: "g", id: "bb", square: { file: 2, rank: 2 }, color: { value: "black" }
  setup  "CaptureBishop", label: "g", id: "bb", side: { value: "black" }
  input  side: { value: "black" }
  expect count: 1
end
```

If the domain has no query that can answer what a test wants to check,
that is a missing word in the bluebook, not a reason to add a sixth
`expect` key.

## Running it

`Hecks::Behaviors.run(path)` runs one file and returns one result
per test — `:pass`, `:fail`, or `:error`, each with a message.
`Hecks::Behaviors.run_all(dir)` sweeps every `.behaviors` file under
a directory. Boot is ONE `Hecks.boot_files` call per SUITE, not per
test — a real boot is expensive enough (chess: 76 tests, 155s of pure
boot time) that per-test booting doesn't scale — and the runtime is
reset between tests instead (`Registry#reset_runtime_state!`).
Isolation from that reset is real for `Memory`-bound aggregates, which
is why a behaviors suite's `loads` is required to resolve every
aggregate to a `Memory` binding: pointing `loads` at a domain's real,
non-`Memory` hecksagon is refused at boot, precisely so state can never
leak from one test into the next — or into a real database.

```ruby
require "hecks/behaviors"

path   = File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.behaviors")
result = Hecks::Behaviors.run(path)

result.parse_error                              # => nil
result.runs.size                                 # => 7
result.runs.map(&:status).uniq                   # => [:pass]
result.runs.first.description                    # => "CreatePizza puts a fresh pizza on the menu, available for sale"
```

`bin/behaviors` is the command-line form — one file or a directory to
sweep, human-readable output, a nonzero exit on any fail, error, or
parse error:

```
bin/behaviors examples/pizzas/bluebook/pizzas.behaviors
bin/behaviors examples/
```

For a consumer whose own test suite runs on rspec,
`hecks/behaviors/rspec` turns a `.behaviors` file into ordinary
examples — one `it` per test, named by the test's own description — the
same shape this repo's own `spec/behaviors_examples_spec.rb` uses to run
`examples/pizzas/bluebook/pizzas.behaviors` as part of `bundle exec
rspec`:

```ruby skip
require "hecks/behaviors/rspec"

Dir.glob("bluebook/**/*.behaviors").each do |path|
  Hecks::Behaviors::RSpec.describe_file(path)
end
```

## A fuller worked example

Chess is the domain this DSL was actually proven against while it was
being built — turn order enforced through a `given`, four sliding and
leaping pieces each checking every occupant list before a `Move`
succeeds, a two-dispatch `Capture`-then-`Move` protocol, and a
`Graveyard` aggregate fed entirely by policy from the board's own
`Captured` events. Every example on this page is drawn from that
domain's real `chess.behaviors` file — turn order, blocking, occupancy,
capture, and the graveyard, the same five categories `spec/chess_spec.rb`
groups its own direct assertions under in the project that domain lives
in. It is not part of this repo's own corpus (`examples/` stays domains
hecks itself owns and ships), which is why every snippet above is
marked "shown, never run" rather than boot the game for real — but it is
real, and it is the shape a `.behaviors` file takes once a domain has
more than one aggregate, entities with their own commands, and a
projection fed by policy.
