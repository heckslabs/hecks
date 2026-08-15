# Verification

Your suite is green. Every `given` you wrote refuses correctly, every
`ensures` holds, the corpus you remembered to write passes. None of
that answers the question that actually decides whether you ship:
does anything about this domain's own SHAPE break in a way no test you
wrote would ever exercise — a lifecycle state your own transitions can
never reach, a saga waiting on a handler chain with no path to it, a
refusal the corpus swears must fire that the runtime quietly accepts
instead. Those are not bugs your tests catch, because a test only
walks the path you thought to write. This page is the toolbox for the
paths you didn't.

Four checks, each answering a narrower question than "is the suite
green." `bin/model_check` reads your domain's own declared shape and
proves facts about every path through it, not just the ones you
tested. `bin/fuzz` walks random-but-valid histories through the real
interpreter and checks properties that must hold of ANY of them. The
corpus under `spec/corpus/` is the fixed list of refusal paths you
already decided matter, walked end to end by `bin/run`. And the golden
IR is a frozen snapshot of what your builder emits, so a shape drift
shows up before something that reads that shape by name silently
corrupts. None of them replace the suite — they are what you reach for
when the suite passing is not, by itself, a complete answer to whether
it is safe to ship.

## A small domain with a hole in it

Every other example on this page — below, and everywhere else this
guide's doctests run — is real: banking, pizzas, the frozen corpus.
This one section is the deliberate exception, and it stays that way on
purpose: `model_check` needs something genuinely BROKEN to catch, and
banking and pizzas have to stay valid, golden, and frozen, so wiring a
real unreachable state into either of them would corrupt the fixture
every other section on this page relies on. What follows is not a
domain — it is the smallest fragment that still trips the finding, on
the same footing as
[`spec/fixtures/model_check/lifecycle_findings.bluebook`](../../spec/fixtures/model_check/lifecycle_findings.bluebook)
in the test suite: one aggregate, one lifecycle, one hole, on purpose,
because the hole is the whole demonstration:

```ruby bluebook
Hecks.bluebook "Chapelle" do
  aggregate "Reliquary" do
    identified_by :label

    attribute :label, Label

    value_object "Label" do
      attribute :value, String
    end

    lifecycle :state, default: "sealed" do
      transition "Consecrate" => "consecrated", from: "sealed"
      transition "Reopen"     => "opened",       from: "locked"
    end

    command "Consecrate" do
      reference_to Reliquary

      emits "Consecrated"
    end

    command "Reopen" do
      reference_to Reliquary

      emits "Reopened"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("Chapelle") { Chapelle::Reliquary.persisted_by("Memory") }
```

Nothing above is ever dispatched — there is no creating command, and
nothing below ever calls one — because `model_check` needs no run at
all. It reads the declaration, not a dispatch.

## `bin/model_check` — what a dispatch never tells you

The runtime itself never checks any of this: a dead transition simply
never fires, in silence, and a saga stuck on an unreachable state looks
identical to one that is merely rare — nothing raises, nothing logs,
the domain just quietly never does the thing you declared it could.
`bin/model_check`'s own header names the family it belongs to —
TLA+, Alloy, P, the lightweight-formal-methods leg of the arc — and
`model_check.rb` states the property that makes it worth having rather
than a second spec someone has to remember to keep in sync: the model
IS the implementation. It walks the exact IR the runtime dispatches
against, so there is no second copy of the truth to drift from the
first.

Call it the same way `spec/model_check_spec.rb` does — in process,
against the chapter you just booted:

```ruby
require "hecksagain/bluebook/model_check"

chapter  = runtime.registry.bluebooks.values.first
findings = Hecksagain::Bluebook::ModelCheck.call(chapter)

findings.map(&:kind).sort   # => [:dead_transition, :stuck_state, :unreachable_state, :unreachable_state]
findings.count { |f| f.severity == :error }    # => 3
findings.count { |f| f.severity == :warning }  # => 1
```

`Reopen` declares `from: "locked"` — a real state, since a `from:`
names it — but nothing in this lifecycle ever transitions a Reliquary
INTO `"locked"`. Nothing reaches it, so it is `unreachable_state`, an
error, derived from the graph without running anything:

```ruby
findings.count { |f| f.kind == :unreachable_state }                                  # => 2
findings.any? { |f| f.kind == :unreachable_state && f.message.include?("locked") }    # => true
findings.any? { |f| f.kind == :unreachable_state && f.message.include?("opened") }    # => true
```

`"opened"` is flagged too, and it cascades from the same hole:
`Reopen`'s only target is reachable exclusively through a `from:`
that is itself never reached, so the target inherits the fate of its
source. Two findings, one cause.

`Reopen` itself earns a second, separate finding — `dead_transition` —
and the distinction is not cosmetic: `"locked"` being unreachable is a
fact about a STATE; `Reopen` never being able to fire is a fact about
the TRANSITION that names it as a precondition. Fixing one without
noticing the other is exactly the mistake this pair exists to catch:

```ruby
dead = findings.find { |f| f.kind == :dead_transition }
dead.subject                    # => "Reliquary"
dead.message.include?("Reopen") # => true
```

Now the one worth being precise about, because it looks like the same
shape and is not. `Consecrate` genuinely reaches `"consecrated"` —
`"sealed"` is the default, `Consecrate`'s `from:` names it, so
`"consecrated"` is reachable, no hole there. But nothing in this
lifecycle ever transitions OUT of `"consecrated"` again. A state a
transition delivers you INTO, with no path declared to leave it by, is
neither unreachable (it was reached) nor dead (nothing about it failed
to fire) — it is `stuck_state`, and it is a WARNING, not an error,
because a state with nothing declared to leave it by is very often
exactly the point: a terminal state is supposed to have nowhere left
to go.

```ruby
stuck = findings.find { |f| f.kind == :stuck_state }
stuck.severity                        # => :warning
stuck.message.include?("consecrated") # => true
```

The full inventory — every finding kind the checker can raise, across
lifecycles, sagas, and policies:

| kind | severity | catches |
|---|---|---|
| `unreachable_state` | error | a state named in a `from:` or a transition target that no path from the default ever reaches |
| `dead_transition` | error | a transition whose own `from:` state(s) are never reached — it can never fire |
| `stuck_state` | warning | a reached state with no transition ever declared to leave it (suppressed entirely if any transition in the lifecycle is unconstrained — a machine with a genuinely free move can idle anywhere on purpose) |
| `unknown_command` | error | a transition names a command the aggregate or entity never declares |
| `deaf_trigger` | error | a saga's `starts_on`/`ends_on` names an event no command in the domain emits |
| `unreachable_pm_state` | error | a declared saga state no handler chain from its first state ever reaches |
| `deaf_handler` | error | a saga handler answers an event nothing emits (the `REFUSED` compensation trigger is exempt — it is not an event) |
| `unknown_dispatch` | error | a saga handler dispatches a command the domain declares no such verb for |
| `dead_compensation` | error | the saga's compensation leaves a `from_state` no handler chain ever reaches — the deadlock class |
| `deaf_policy` | error | a policy's `on` event names something nothing emits |
| `unknown_trigger` | error | a policy's `trigger` resolves to no command the domain declares |

The CLI walks every example, every grammar chapter, and the language's
own two meta-chapters the same way, in one pass:

```sh
bin/model_check                  # everything
bin/model_check examples/banking # one domain
```

One finding in this repo's own corpus is allowed on purpose rather
than fixed: banking's `ExternalSettlement` saga leaves its own
`"sent"` state unreachable through the handler chain the checker
walks, even though the underlying transfer genuinely settles — the
SAGA's own bookkeeping just never closes on it.
`ModelCheck::ALLOWED_FINDINGS` names that entry explicitly, and the
coverage gate in `spec/model_check_spec.rb` — reading the same table
`bin/model_check` does — fails in both directions: a new error nothing
names is a regression, and an allowlisted entry the checker stops
finding is stale and has to be deleted. A finding gets shipped by
being named, never by being silenced.

## `bin/fuzz` and the properties that must hold of any run

`model_check` proves facts about the declared graph before anything
runs. `bin/fuzz` proves facts about what actually happens when
something DOES run — repeatedly, on sequences no one sat down and
wrote. It draws random-but-valid command and query sequences off the
domain's own IR, replays each one in process, and checks whether
anything escaped the interpreter's own per-step refusal handling (a
`DOMAIN_REFUSAL` or an evaluation failure is caught and recorded per
step — anything else propagating out is the interpreter breaking, not
the domain declining), whether every declared property still holds,
and — separately, because it costs a second full replay — whether two
runs of the identical steps produced byte-identical histories.

Four declared properties, in `Hecksagain::Fuzzing::Properties`:
`lifecycle_values_are_declared` (every lifecycle field a replay leaves
an instance holding is one of that aggregate's own declared states),
`saga_advances_follow_declared_handlers` (every saga advance a replay
logged moved along an edge some handler actually names),
`query_answers_match_reference`, and `replay_is_deterministic`, kept
apart from the other three because it needs a second boot to check at
all. This is the canonical example domain for the rest of this
section — pizzas, era 2, the one `docs/guides/AUTHORING.md` points to
whenever a guide needs a real domain rather than an invented one:

```ruby
require "hecksagain/fuzzing"

steps = [
  { "verb" => "Pizzas::Order.CreatePizza",
    "args" => { "name" => { "value" => "Margherita" },
                "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } } } },
  { "verb" => "Pizzas::Order.AddTopping",
    "args" => { "name" => "Margherita", "topping" => { "value" => "Basil" }, "amount" => { "value" => 3 } } },
  { "query" => "Pizzas::Order.Available", "args" => {} }
]

history = Hecksagain::Fuzzing::Replay.call("examples/pizzas", steps)

Hecksagain::Fuzzing::Properties.check(history)
  # => { lifecycle_values_are_declared: true, saga_advances_follow_declared_handlers: true, query_answers_match_reference: true }
```

`query_answers_match_reference` is the newest property, and it is a
genuinely different kind of check from the other two: `"Available"`
above was answered TWICE at the same instant — once through whatever
`Order` is actually bound to (Memory's own query hook, here), once
through the reference interpreter, a second, independent evaluation of
the same `where`/`order_by` vocabulary. `Replay` records both:

```ruby
asked = history[:queries].first
asked[:rows] == asked[:reference_rows]   # => true
```

Two implementations of the same comparator semantics have drifted
before. An adapter that accepts what the reference interpreter refuses,
or orders what it should not, shows up here — and no adapter spec that
only asks the adapter about itself could ever have caught it.

`replay_is_deterministic` runs apart from the other three, and only
once they have already passed — a property violation or a crash is
cheap to find; proving determinism means replaying the SAME steps
against a SECOND fresh boot and diffing two full histories, which is
not cheap, so `bin/fuzz` only pays for it once a sequence is otherwise
clean:

```ruby
Hecksagain::Fuzzing::Properties.replay_is_deterministic("examples/pizzas", steps)   # => true
```

This is the one worth being exact about, because it checks a promise,
not a convenience. `Hecksagain::Runtime` mints nothing: every identity
in this language is declared and derived from what you passed in,
never invented — no random hex, no counter, nothing not reproducible
from the payload was ever allowed into the interpreter, specifically
because it would break this. So the same steps, replayed against a
fresh boot, MUST produce byte-identical events, refusals, and
instances. Any drift — a wall-clock read that leaked into something
compared, a `Hash` iteration order a comparison happened to depend on —
is nondeterminism the runtime promised not to have, and it is caught
by two INDEPENDENT replays, not one compared against a cached copy of
itself, which would only ever agree with its own bug.

When a generated sequence does find something, `bin/fuzz` does not
hand you thirty random steps and a seed number. It shrinks — removing
one step at a time, then one argument within a step at a time, keeping
each removal only while the exact same finding still reproduces — and
saves what is left under `tmp/fuzz-failures/<domain>-seed<N>.json`: a
script shaped exactly like the corpus's own, reproducible with the
tool you already have:

```sh
bin/fuzz examples/banking
bin/run examples/banking tmp/fuzz-failures/banking-seed7.json
```

## The corpus — the refusals you already decided matter

Refusals are not exceptions; they are half the language, and
`spec/corpus/*.json` is where that claim gets tested end to end — a
scripted list of commands and queries per domain, walking successes
and, mainly, every refusal path someone once decided was worth pinning
down permanently. The project states its own stakes for this plainly:
a runtime that ACCEPTS what the corpus says must be refused is the
failure most worth catching — not a missing feature, a silently WRONG
one, the kind that ships because nothing failed loudly enough to stop
it.

Where this sits next to the other two: `model_check` proves things
about the declaration; `fuzz` proves things about arbitrary runs; the
corpus is neither — it is a fixed, curated list of the SPECIFIC paths
a person already decided deserve a permanent regression guard, most of
them refusals. `bin/run <domain> <script.json>` walks one, dispatching
every step, and reports the first expectation that did not hold.

The same check, run in process against an isolated copy of banking —
the flagship corpus member, composite identity, entities, two read
models, three process managers, walking every declared command and
query including its refusal paths:

```ruby
require "json"

script  = JSON.parse(File.read("spec/corpus/banking.json"))
history = Hecksagain::Fuzzing::Replay.call("examples/banking", script.fetch("steps"))

# The same check bin/run performs after every corpus run — every refusal
# the script says must happen, actually happened.
unmet = script.dig("expectations", "refusals").reject do |expected|
  history[:refusals].any? { |r| r[:verb] == expected["verb"] && r[:error].include?(expected["includes"]) }
end

unmet   # => []
```

Eleven refusal paths in banking's own corpus script, every one of them
still refusing. Loosen a `given` by accident, drop a `positive?` check
from a value object's invariant, and this exact `unmet` stops being
`[]` — it names the verb that quietly stopped saying no. The CLI does
the identical walk without a Ruby snippet, against the domain's real
binding:

```sh
bin/run examples/banking spec/corpus/banking.json
```

— printing the full report to stdout and aborting nonzero on the
first unmet expectation, evidence first and complaints after, so a
refusal that merely changed its wording reads differently from one
that stopped happening at all.

## The golden IR — a drift alarm, not a test you write

One more, briefer, because [extending-hecks.md](extending-hecks.md) covers it at more
depth. `spec/ir_golden_spec.rb` freezes what the builder's `to_h`
emits for every corpus member into `spec/golden/ir/*.json`, and
compares today's emission against yesterday's FILE rather than against
anything computed live — because two live-computed sides both miss the
same blind spot the same way, and a frozen file does not. It exists
because that exact shape is load-bearing twice over outside this repo
entirely: `StorageShape.project` reads it by key name to mint era
hashes, and `MetaValidator` hashes it as a verdict-cache key, so a
silently renamed or reordered key corrupts identity with no error
anywhere near the change that caused it. A rewrite is a claim that the
wire format changed, not a routine refresh:

```sh
GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb
```

Read the diff before trusting it — every era ever minted was hashed
against the shape you are about to overwrite.

## What actually blocks a push

The suite and `bin/model_check` are exactly what `.githooks/pre-push`
runs before anything leaves your machine — not `bin/fuzz`, which stays
out deliberately: a random sweep is not a fast loop, and pre-push is
supposed to be one. The suite runs first; then the model checker; and
either one being red blocks the push outright. So the question of
whether verification was sufficient has a mechanical answer at the
moment it matters most — if `git push` went through, the suite passed
and the model checker found nothing new. Install it once —

```sh
git config core.hooksPath .githooks
```

— and bypass it only when you mean to and can say why:
`git push --no-verify`.

## Which one, when

Not all four apply to every change. Reach for `model_check` while
still shaping the domain — it is static, it is fast, and a dead
transition or an unreachable saga state is exactly the mistake most
likely to happen while writing a lifecycle, not after; pre-push runs
it regardless. Reach for `fuzz` before trusting a refactor to the
interpreter itself — the dispatcher, the saga engine, an adapter's
query hook — because that is the one that catches the runtime doing
something no declaration ever sanctioned, and it is too slow to run on
every save. The corpus covers the specific refusal paths already known
to matter, on every change near them — it is not exploratory, it is a
permanent guard against regressing a decision already made. And the
golden IR is not run by hand most weeks; it is the alarm that goes off
when a shape no one was watching moved underneath something that reads
it by name. Four different questions, four different costs — "the
suite is green" was never going to answer all of them at once.
