# Running a runtime

A port is a second implementation of dispatch — a runtime, likely in a
different language, that accepts the same commands and queries a
bluebook declares and produces the same refusals and events a real
boot of it would. One exists: `rust/` (Cargo crate + Ruby generator,
`bin/project_rust` the driver — see `docs/decisions/0011-rust-compiles-types-interprets-dispatch.md`
for the architecture decision, and `docs/HECKS_IMPLEMENTATION_PLAN.md`
§8 for its current, honestly-scoped status). This page is what running
it, extending it to a new domain construct, or starting an analogous
port in a different language actually requires: what the canonical IR
contains, field by field, the exact order a command's dispatch runs
in, and how the `given`/`ensures`/invariant text you'll find in that
IR is supposed to be read. Everything here is either proven live
against a real domain below, or cited against the Ruby source that is
the actual authority, named so you can go verify it yourself rather
than trust a paraphrase.

One architectural choice this page used to leave open, and doesn't
anymore: whether a port INTERPRETS the IR at its own runtime start-up
(read the JSON, hold the AST, dispatch generically against it) or
COMPILES it once, ahead of time, into native dispatch code for each
command (a build step emits real functions; nothing at runtime reads
IR at all). `rust/` does neither purely — it compiles TYPE SHAPES
ahead of time and interprets DISPATCH BEHAVIOR (`given`/`ensures`/
mutations, as data) generically at runtime, through one small,
hand-written kernel. "Interpret data, don't compile source," below, is
the argument for why; it's not a hypothetical anymore, it's what got
built, after a pure-compile first attempt didn't converge. The facts
in the rest of this page hold regardless of which split a NEW port
chooses, because they describe what the IR contains and what order
dispatch runs in, not how any one port consumes that — but "Interpret
data, don't compile source" is no longer just an argument to weigh, it's
also a report from having tried the alternative first.

## Getting the IR

The IR is `Hecksagain::Bluebook#to_h`, per aggregate, per bluebook —
the same shape `spec/golden/ir/*.json` pins and `bin/ir` prints.
`Hecksagain::Projector::Exporter.call(registry)` returns it as a real
Ruby `Hash`, keyed by bluebook name; `.json(registry)` wraps it in
`JSON.pretty_generate` for a file or a pipe. Boot the domain the same
way any other guide does — `Kernel.load` the real bluebook file, wire
every aggregate to `"Memory"` — and read it off `runtime.registry`:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::ATMCard.persisted_by("Memory")
  Banking::Transfer.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
  Banking::ExternalTransfer.persisted_by("Memory")
  Banking::ScheduledPayment.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby
ir = Hecksagain::Projector::Exporter.call(runtime.registry).fetch("Banking")

ir.keys # => [:ir_version, :name, :version, :vision, :classification, :aggregates, :read_models, :policies, :process_managers, :canonical_form]
```

Every key below is a real Ruby `Symbol`, not a JSON string — `Exporter.call`
returns the object graph's own `to_h`, unconverted. Round-trip it
through `Exporter.json` and `JSON.parse` instead and every key becomes
a string; pick whichever your build step wants to consume, but don't
mix assumptions about which one you're holding.

`ir_version` and `version` name two different things, easy to
conflate: `ir_version` is this **export shape's own** version (bump it
when `to_h`'s own keys change in a way a consumer needs to know about,
not when a domain adds a command) — it's the same for every bluebook,
current value `1`. `version` is Banking's own declared business
version (`"v1"`, the DSL's `Hecks.bluebook "Banking", version: "v1"`)
and is `nil` for a domain that never set one, Pizzas among them:

```ruby
ir[:ir_version] # => 1
ir[:version]    # => "v1"
```

If your build step shells out instead of running in-process, `bin/ir
<domain>` prints the same thing — with one trap: booting a domain's
*real* `.hecksagon` (as opposed to the Memory wiring above) may wire a
Postgres-backed adapter, and Postgres's own `NOTICE` lines land on the
same stdout your script is trying to parse as pure JSON. Wire your own
hecksagon against `"Memory"`, the way every doctested example on this
page does, rather than booting the domain's committed one, and this
never comes up.

## The shape: bluebook → aggregate → attribute

An aggregate carries thirteen keys. `lifecycle` is `nil` when the
aggregate declares none; `entities`, `queries`, `commands`,
`value_objects`, `invariants`, `preconditions` are always arrays, empty
when there's nothing to say:

```ruby
account = ir.fetch(:aggregates).find { |a| a[:name] == "Account" }

account.keys # => [:name, :description, :identified_by, :attributes, :value_objects, :commands, :invariants, :preconditions, :projected_fields, :lifecycle, :entities, :queries, :ports, :provenance]
```

`invariants` and `preconditions` are the aggregate-level rules (S10,
ADR 0025 — see [commands.md](commands.md#given--the-rule-you-enforce-going-in)):
`invariants` is checked after every command, before save, the same way
a value object's own `invariants` are; `preconditions` holds the
aggregate's own NAMED `given`s — the ones a command references back by
description rather than re-declaring:

```ruby
account[:invariants].map { |i| i[:description] }    # => ["the balance never goes negative"]
account[:preconditions].map { |p| p[:description] } # => ["customer is active", "customer is not closed"]
```

`identified_by` is always an array of dotted paths, even for a single
scalar field — `["reference.value"]` for `Customer`, one entry per
identity component. A composite identity is more than one entry,
joined by `:` at dispatch time; `SafeDepositBox` is the real one in
this corpus:

```ruby
account[:identified_by] # => ["number.value"]

safe_deposit_box = ir.fetch(:aggregates).find { |a| a[:name] == "SafeDepositBox" }
safe_deposit_box[:identified_by] # => ["branch_code.value", "box_number.value"]
```

Every `attributes` entry — on an aggregate, a value object, a command,
or an entity, the shape never varies — carries the same six keys:

```ruby
balance_attr = account[:attributes].find { |a| a[:name] == :balance }
balance_attr # => { name: :balance, type: "Money", list: false, default: nil, optional: false, pattern: nil, admits: nil }
```

An attribute's `name` is a `Symbol` (the DSL takes `attribute :balance,
Money`); an aggregate's, a command's, and a value object's own `name`
are all plain `String`s (the DSL takes those as quoted chapter/verb
names) — the export does not normalize the two onto one type, so match
each key with the kind it actually is, not the kind that reads more
consistently.

`type` is one of three things: a scalar (`"String"`, `"Integer"`,
`"Float"`), the name of a value object declared on the same aggregate
(resolve it against that aggregate's own `value_objects`, not a global
namespace — two aggregates may each declare a `Money`), or
`"Reference<AggregateName>"` for a pointer at another aggregate's
identity:

```ruby
account[:attributes].find { |a| a[:name] == :customer }[:type] # => "Reference<Customer>"
```

`list` marks a repeated attribute (a command's `list_of` field) — a
`Vec`/array of `type`, never
`Option`-wrapped the way a scalar attribute might be in a language
that distinguishes the two. `pattern` is a regex string when a value
object's field was declared with `pattern:` (an email address, for
instance); `admits` is set only when an attribute's closed set is
borrowed from a DIFFERENT aggregate's value object rather than its
own:

```ruby
external_transfer = ir.fetch(:aggregates).find { |a| a[:name] == "ExternalTransfer" }
external_transfer[:attributes].find { |a| a[:name] == :direction }[:admits] # => "Account::LedgerDirection"
```

`default` is `nil` when nothing was declared, the literal value when
it's a scalar, and a nested `Hash` when the default is itself a value
object — `SafeDepositBox`'s `size` defaults to `Size`, not to a bare
string:

```ruby
safe_deposit_box[:attributes].find { |a| a[:name] == :size }[:default] # => { value: "small" }
```

## Value objects: fields, invariants, closed sets

A `value_objects` entry is `name`, `attributes` (the same six-key
shape as above, recursively — a value object can nest another one),
`invariants`, `closed_set`, `members`. A ordinary value object has
`closed_set: false` and an empty `members`; its `invariants` are the
rules your port has to check at construction time, each one already
reduced to the same canonical text the expression grammar section
below reads:

```ruby
account[:value_objects].find { |vo| vo[:name] == "DailyLimit" }
# => { name: "DailyLimit", attributes: [{ name: :cents, type: "Integer", list: false, default: 0, optional: false, pattern: nil, admits: nil }], invariants: [{ description: "a daily limit is non-negative", canonical: "!cents.negative?" }], closed_set: false, members: [] }
```

A closed set inverts that: `invariants` is empty (membership IS the
rule) and `members` lists every admitted value, one row per member, a
row being an array of `[field, value]` pairs — almost always one pair,
`[["value", "small"]]`, because most closed sets wrap a single scalar,
but the shape doesn't assume that:

```ruby
size_vo = safe_deposit_box[:value_objects].find { |vo| vo[:name] == "Size" }
size_vo[:closed_set] # => true
size_vo[:members]    # => [[["value", "small"]], [["value", "medium"]], [["value", "large"]]]
```

The natural target for a closed set in a language with real enums is a
real enum, not a string your port compares by hand — one variant per
member row, named from its value.

## Commands: the roster and what each key means

A command carries `name`, `role`, `goal`, `references`, `attributes`,
`givens`, `ensures`, `mutations`, `emits`. `role` and `goal` are prose,
not load-bearing for dispatch itself (role-checking, when a command
declares one, is a separate opt-in rule — see
[commands.md](commands.md)). `references` is the field that decides
creating vs. acting, and it decides it exactly the way
`IR::Command#creates?` is actually implemented — `references.nil?`,
nothing more:

```ruby
credit = account[:commands].find { |c| c[:name] == "Credit" }
open   = account[:commands].find { |c| c[:name] == "Open" }

credit[:references] # => "Account"
open[:references]   # => nil
```

A creating command derives its own identity from its own arguments (no
record exists yet to look one up on); an acting command's `references`
names the aggregate its identity is derived against instead — for
`Credit`, `"Account"`, matched by the addressing key
`docs/guides/commands.md` calls `reference_to`.

`givens` and `ensures` are both arrays of `{ description:, canonical: }`
— `description` is the human-readable prose you'd show in a refusal
message, `canonical` is the normalized boolean expression text the
next section walks in full:

```ruby
debit = account[:commands].find { |c| c[:name] == "Debit" }

debit[:givens].map { |g| g[:canonical] }
# => ["customer.status == \"active\"", "balance.cents >= amount.cents", "daily_limit.cents >= amount.cents"]

debit[:ensures].map { |e| e[:canonical] }
# => ["old.balance.cents == balance.cents + amount.cents", "ledger.size == old.ledger.size + 1"]
```

`mutations` is the one worth being careful with, because its shape
branches on `op`. A `set`/`increment`/`decrement` entry carries
`source`, itself a small tagged union — `{ kind: "argument", name: }`
when the mutation reads a command argument (the overwhelming majority
of real mutations), `{ kind: "literal", value: }` when the bluebook
wrote a bare literal instead:

```ruby
credit[:mutations].find { |m| m[:target] == :balance }
# => { target: :balance, op: :increment, source: { kind: "argument", name: "amount" } }
```

An `append` entry carries `fields` instead of `source` — and here is
the one real gotcha in the whole export: a field whose value is a bare
argument name serializes as that name's plain string, but a field
whose value is a LITERAL nested value object (as `Credit`'s own
`sets :ledger, append: { ..., direction: { value: "credit" } }`
does) serializes as that literal `Hash`'s `Kernel#inspect` string, not
as structured JSON — because `IR::Command::Mutation#appended_fields`
calls `.inspect` on anything that isn't a bare `Symbol`, not a second
recursive `to_h`:

```ruby
credit[:mutations].find { |m| m[:target] == :ledger }
# => { target: :ledger, op: :append, fields: { amount: "amount", narrative: "narrative", direction: "{:value=>\"credit\"}" } }
```

A port that wants that literal back as data, not as a string to
re-parse, has to special-case it — walk the ORIGINAL declaration
instead of the exported field, or teach your codegen to recognize a
`{:key=>"value", ...}`-shaped string and treat it as the literal it
came from. This is a real shape a real bluebook writes (`Credit` and
`Debit` both do it, for `direction`), not an edge case you can defer.

**A `set`/`increment`/`decrement` mutation's own literal `source` gets
none of that treatment.** `Mutation#classified_source` wraps any
non-`Symbol` source as `{ kind: "literal", value: source }` — the
ORIGINAL Ruby object, untouched, not a second call to `.inspect`. A
literal value object there arrives as a real, structured `Hash` your
port can build from directly:

```ruby
customer = ir.fetch(:aggregates).find { |a| a[:name] == "Customer" }
customer[:commands].find { |c| c[:name] == "Reinstate" }[:mutations]
# => [{ target: :standing, op: :set, source: { kind: "literal", value: { value: "good" } } }]
```

Keep the two straight, because they look identical at a glance and
resolve oppositely: `append`'s literal `fields` are text to re-parse;
`set`/`increment`/`decrement`'s literal `source` is already the
structured value, keyed by the SAME field names the target value
object declares — build the target type straight from the `Hash`'s own
keys, no string handling involved.

`emits` is the plain array of event name strings a successful dispatch
raises, in the order they were declared — one for almost every command
in this corpus, but the shape does not assume exactly one.

## Arithmetic mutations: what `increment`/`decrement` actually change

`increment`/`decrement`'s own `source` follows the identical tagged
union `set` does (`argument` or `literal`), but applying one is not
"add source to target." `CommandRules::Arithmetic#arithmetic`/
`#arithmetic_value_object`, read directly, coerce the source into the
TARGET ATTRIBUTE's OWN type FIRST (`Value.for_attribute(aggregate,
attribute, amount)`), then find the ONE field that's `Integer` in BOTH
the target's current value and the now-coerced amount, and change ONLY
that field — every other field the target value object carries passes
through the mutation untouched:

```ruby
scheduled_payment = ir.fetch(:aggregates).find { |a| a[:name] == "ScheduledPayment" }
scheduled_payment[:commands].find { |c| c[:name] == "Retry" }[:mutations]
# => [{ target: :attempts, op: :increment, source: { kind: "literal", value: { value: 1 } } }]
```

`Retry`'s own amount is the raw literal `Hash` `{ value: 1 }` —
`RetryCount`'s one field, matched by name, not a bare integer your
port has to guess a shape for. `Account.Debit`'s own `decrement` on
`balance` is the other real shape:

```ruby
debit[:mutations].find { |m| m[:target] == :balance }
# => { target: :balance, op: :decrement, source: { kind: "argument", name: "amount" } }
```

The source there is an argument declared `PositiveMoney`, decrementing
a target declared plain `Money` — different value-object TYPES,
bridged only by both sharing one `Integer`-typed field, `cents`.
`Money`'s OTHER field, `currency`, is untouched by the mutation —
`balance.currency` staying `"USD"` after a debit is not an accident
your port has to special-case, it's this rule.

## Lifecycles

An aggregate with a `lifecycle` block exports `field`, `default`,
`transitions` — the last one a flat array, one entry per `transition`
line, `{ command:, to_state:, from_state: }`. A `from:` naming more
than one source state in the bluebook flattens into more than one
transition row here, one per source, all sharing the same `command`
and `to_state`:

```ruby
account[:lifecycle][:field]   # => "status"
account[:lifecycle][:default] # => "open"
account[:lifecycle][:transitions].select { |t| t[:command] == "CloseAccount" }
# => [{ command: "CloseAccount", to_state: "closed", from_state: "open" }, { command: "CloseAccount", to_state: "closed", from_state: "frozen" }]
```

A command not named in any `transitions` row runs with no lifecycle
gate at all — dispatch's own `admissible_transition` step (next
section) simply finds nothing to check and moves on.

## Entities

`entities` is an array of the same aggregate shape, one level down —
`name`, `description`, `identified_by`, `attributes`, plus its own
`lifecycle` when it declares one. [entities.md](entities.md) is where
an entity's OWN commands and their caller-supplied identity live — a
port generating THOSE (an entity's own `Amend`/`Reverse`-shaped
dispatch, addressing one element of a list by an identity a CALLER
supplies) is a separate, larger feature this page does not walk.

What this page's own build order needs is narrower: an `append` onto
an entity list, the one thing every entity-bearing aggregate's OWN
creating/acting commands actually do (`Account.Credit`/`Debit` append
a `LedgerEntry`; neither ever supplies its identity or its lifecycle
field). Two fields on the element `MutationApplier#entity_element`
fills in that a `sets append:` binding never names, because Ruby
never asks the caller to:

```ruby
account[:entities].find { |e| e[:name] == "LedgerEntry" }[:identified_by]
# => ["sequence.value"]

credit[:mutations].find { |m| m[:target] == :ledger }[:fields].keys
# => [:amount, :narrative, :direction]
```

`sequence` is nowhere in that field list. It's minted from the list's
own CURRENT LENGTH, one-indexed (`Array(current).size + 1`), wrapped
into whichever single-field value object its own dotted path names —
the exact same "bare-declared, single-field-VO" shape a composite
AGGREGATE identity's own components resolve through, one level down.
`LedgerEntry`'s own `lifecycle` (`state`, default `"posted"`) fills the
same way, from its own declared `default:`, when the fields don't name
it either. Both are genuinely absent from what the command declares —
not a gap in what got exported, an intentional case a port's `append`
codegen has to fill in on its own, the same place Ruby fills it.

## Dispatch, in the order it actually runs

Fourteen steps, hand-typed in `Runtime::CommandInterpreter::DISPATCH_ORDER`
and held equal to the language's own declared vocabulary by
`spec/vocabulary_conformance_spec.rb` — this is not a summary, it is
the literal list:

```ruby skip
refuse_unknown_arguments   # every arg key must be a declared attribute or an addressing key (id/identity/reference)
refuse_absent_arguments    # every non-optional declared attribute must be present
normalize_args             # coerce raw hashes into typed Values — invariant checks fire HERE
refuse_role_mismatch       # only if the command declares role: and the caller opted into role checking
resolve_references         # a reference argument (bare id string) is checked to actually exist
hydrate                    # creating: derive identity, refuse AlreadyExists; acting: look up, refuse NotFound
enforce_givens              # every given must read true against the hydrated instance + args
admissible_transition       # if the command names a lifecycle transition, its from: must match the current state
assign_creation_attributes  # creating commands only — see below
apply_mutations              # every declared sets, in declared order
advance_lifecycle            # if a transition was found, write the target state
enforce_ensures               # every ensures must read true, args merged with old: the pre-mutation state
save                          # write the instance back through the aggregate's repository
emit                          # build and return the declared events
```

Two facts about that list are true and not written down anywhere else
in this repository's guides, because nothing before this page needed
a second runtime to know them:

**`assign_creation_attributes` and `apply_mutations` are two different
steps, and only the first is implicit.** A creating command's
attributes are copied onto the fresh instance by NAME MATCH alone —
every command attribute whose name matches one of the aggregate's own
attribute names is assigned, unconditionally, with no `sets`
required to say so. `Pizzas::Order.CreatePizza` never declares a
single `sets`, and its exported `mutations` array is empty — the
whole record is built by this implicit step alone:

```ruby
open[:mutations].map { |m| m[:target] }
# => [:number, :kind, :daily_limit]
```

`Account.Open` DOES declare `sets :number` and its
siblings, even though every name already matches — legal, and not a
no-op collision: `assign_creation_attributes` runs first and sets
`number` from `args[:number]`; `apply_mutations` runs after and sets
it again, from the identical source, to the identical value. Redundant
in this specific case, but the two steps are not the same step wearing
two names — a `sets` whose source is NOT a plain pass-through (an
`increment:`, a literal, a differently-named argument) only ever runs
through the second step, never the first.

**Every `given`/`ensures`/invariant expression resolves a bare name
against the command's ARGUMENTS first, the INSTANCE second, and raises
if neither has it** — `Bluebook::Expression::Resolver#fetch`, read
directly:

```ruby skip
def fetch(name, state, attrs)
  key = name.to_sym
  return attrs[key] if attrs.key?(key)
  return state[key] if known?(state, key)
  raise EvaluationError, "cannot resolve #{name.inspect} — no such attribute or argument"
end
```

That's why `Debit`'s own given, `"balance.cents >= amount.cents"`, can
mix `balance` (an instance field) and `amount` (a command argument) in
one comparison with no marker distinguishing them in the text — the
resolver tries the argument hash first, by design, so an argument name
that happens to collide with an instance field name always wins as the
argument. A dotted path (`balance.cents`) resolves its head the same
way, then walks the rest with plain `[]`, on whatever the head
resolved to.

## The expression grammar

`given`, `ensures`, and every value-object `invariant` are strings —
already normalized at DSL-build time (whitespace collapsed, `.length`
rewritten to `.size`), so the SAME text you see in the IR is exactly
what a real dispatch evaluates, byte for byte. The grammar is small
and closed, projected from `lib/hecksagain/bluebook/expression/projection.json`
and held equal to it by `spec/operator_conformance_spec.rb`:

| symbol | category | arity | notes |
|---|---|---|---|
| `\|\|` | logical | 2 | lowest precedence |
| `&&` | logical | 2 | |
| `.include?` | membership | 2 | `haystack.include?(needle)`; haystack must resolve to `Array` or `String` |
| `>=`, `<=`, `<`, `>`, `==`, `!=` | comparison | 2 | reduced to two primitives, next section |
| `!` | logical | 1 | prefix negation of the whole remaining expression |
| `+` | arithmetic | 2 | |
| `.modulo` | arithmetic | 2 | |
| `.positive?`, `.negative?`, `.zero?` | sign_test | 1 | sugar for comparing the receiver against literal `0` |
| `.empty?`, `.size` | sized | 1 | `Array`, `String`, `Hash` only |
| `.to_s` | to_string | 1 | `String`, `Integer`, `Float`, `Boolean`, `nil` only — raises `EvaluationError` on anything else |

Every one of the six comparison operators reduces to two primitives —
`less_than` and `equal` — combined with a boolean algebra rather than
six separate code paths: each operator's row says which primitive(s)
OR together and whether the result negates.

```ruby
ops = Hecksagain::Bluebook::Expression::Evaluator::OPERATORS
ops.map { |op| [op.symbol, op.compares_less_than, op.compares_equal, op.negated] }.sort
# => [["!=", false, true, true], ["<", true, false, false], ["<=", true, true, false], ["==", false, true, false], [">", true, true, true], [">=", true, false, true]]
```

Read `>=` off that table: `compares_less_than: true`,
`compares_equal: false`, `negated: true` — `a >= b` is computed as
`!(a < b)`, not as its own comparison. A sign test is sugar over the
identical primitives, against a literal `0` — `x.positive?` parses to
exactly the same shape `x > 0` would.

A `given`/`ensures` string parses into one of six node kinds —
`Or`, `And`, `Not`, `Compare`, `Include`, `Resolve` — parsed once (per
distinct string, cached) and interpreted fresh against every dispatch,
against two inputs: `state` (the instance, or for an `ensures`, the
instance PLUS the merged key `old:` holding the pre-mutation snapshot)
and `attrs` (the command's arguments). Every real leaf in this
corpus's own commands, walked directly rather than invented:

```ruby
Hecksagain::Bluebook::Expression::Evaluator.parse("status == \"open\"").class.name.split("::").last
# => "Compare"

Hecksagain::Bluebook::Expression::Evaluator.parse("toppings.size < 10").class.name.split("::").last
# => "Compare"

Hecksagain::Bluebook::Expression::Evaluator.parse("old.balance.cents == balance.cents + amount.cents").class.name.split("::").last
# => "Compare"
```

Below `Compare`, the left and right sides are `Resolver` leaves — a
smaller grammar for the non-boolean part: integer/float/string/bool/nil
literals, `+` addition, `.modulo`, a sign test, `.empty?`/`.size`,
`.to_s`, and the true leaf, `Lookup` — a bare or dotted name resolved
against `attrs` then `state`, per `fetch` above. A `given` that only
ever reads a bare instance field, no operator at all, still parses —
into a `Resolve` node, whose value is checked for Ruby truthiness
(`!nil? && != false`), not equality against literal `true`:

```ruby
node = Hecksagain::Bluebook::Expression::Evaluator.parse("some_flag")
node.class.name.split("::").last # => "Resolve"
```

## Interpret data, don't compile source

There are two ways to turn a `given`/`ensures`/invariant string into
something your target language runs. **Compile it**: parse the real
text once, walk the AST, and emit bespoke boolean SOURCE CODE in your
target language for that one expression — a different function body
for `"cents >= 0"` than for `"toppings.size < 10"`. **Interpret it**:
parse the real text once, but instead of emitting source, emit the
AST itself as DATA in your target language, and write ONE generic
function — once, by hand — that walks any `Expr` tree this grammar can
produce. The first approach is a natural place to start (it's what
value-object invariant checking looks like before you need anything
past a value object's own scalar fields), and it's also where the
problems below actually show up — not as edge cases, but on the very
first `given` a real command needs.

**Compiling forces you to solve, statically, two problems the grammar
itself never has.** First, a fixed type vocabulary: a `given` can read
ANY of the aggregate's own attributes, not just scalar ones —
`Order.AddTopping`'s own `"toppings.size < 10"` reads a LIST
attribute, and `"status == \"open\""`-shaped text reads the lifecycle
field, which is NOT one of the aggregate's own `attributes` in the
exported IR at all (see "Lifecycles" above — it's its own top-level
key):

```ruby
account[:attributes].map { |a| a[:name] }.include?(account[:lifecycle][:field].to_sym) # => false
```

A compiler emitting typed source has to know every one of these
categories in advance and pick correctly-typed literals to match (is
the `0` in `"cents >= 0"` an integer or a float literal in your target
language? — it depends on `cents`'s own declared type, which the
compiler has to look up before it can even emit the comparison).
Second, a fixed receiver: a value-object invariant only ever reads
that value object's own fields, so a compiler built for invariants can
hard-code one receiver name. `given`/`ensures` run against a hydrated
AGGREGATE instance instead, addressed by whatever local variable your
generated dispatch function happens to call it — a choice YOUR codegen
makes, not a fact the IR states.

**An interpreter has neither problem, because both are really the same
problem: baking a decision into generated SOURCE that a genuinely
dynamic evaluation would rather make at the moment it's needed.** A
runtime `interpret(expr, state)` keeps values dynamically typed until
the instant two of them are actually compared — no advance type lookup
for a numeric literal, because comparison coerces then, not at codegen
time. And `state` is an ordinary function PARAMETER, not something
baked into which name a piece of generated source happens to use — the
same interpreter serves a value object checking itself and a command
evaluating a `given` against a looked-up record, because both are just
"whatever `state` was passed this call."

**This generalizes past expressions, to dispatch itself.** A generator
that emits one bespoke function per command SHAPE — one for a plain
creating command, another for an acting command with a given and an
append mutation, a third once a lifecycle transition shows up — never
converges, because the real dispatch algorithm isn't shaped that way
either: `CommandInterpreter#call` is ONE method walking
`DISPATCH_ORDER` over whatever IR a command carries, not one method
per command in the domain. A port's dispatcher should mirror that: one
hand-written, generic function, driven by a small amount of per-command
DATA (which givens, which mutations, whether it creates or acts) —
not N generated functions each hardcoding one shape's control flow.

**Name the one place this genuinely can't be pushed all the way down.**
READING a named field generalizes cleanly — implement one small
lookup/field-access interface per type, the identical shape for every
type, and a generic interpreter can read anything through it. WRITING
into a `sets` target does not, in a statically-typed target
language: appending a value object to a list means CONSTRUCTING one of
a specific, differently-shaped type per aggregate, which has no
generic equivalent without runtime reflection. That still needs a
small amount of per-command generated glue — real, worth being honest
about, and a much smaller boundary than "generate the whole dispatch
function by hand" was.

This is exactly the split `rust/` runs on, not a hypothetical: `Expr`
and `interpret()` (`rust/src/kernel/expr.rs`) are the generic
READING/behavior half, hand-written once; `dispatch()`
(`rust/src/kernel/dispatch.rs`) is the generic per-command orchestration,
also hand-written once; `bin/project_rust` (driving `rust/project.rb`)
is the small, per-command WRITING glue this paragraph names as the one
place generation still earns its keep — real Rust struct literals and
`Vec::push` calls, generated because constructing a specific type has
no generic equivalent, nothing more.

## The persistence contract

A port needs somewhere to put and find records, exactly the shape a
Ruby adapter needs. That contract — which methods are required, which
are delegated without a presence check, which are optional passthroughs,
and the one method (`delete`) whose return value is explicitly NOT part
of the contract — is already documented in full, with a worked example
against the smallest real adapter, in
[writing-an-adapter.md](writing-an-adapter.md). Nothing about that
contract is Ruby-specific; read it there rather than here.

## A build order that keeps every intermediate state honest

Roughly the order the facts above unlock capability, smallest first —
and, for `rust/`, the order things actually happened in, not just a
plan: types and empty-mutation creating commands first (against
Pizzas), then invariants/`given`/mutations, then lifecycle, then
`ensures` (needed a real kernel change — see
`docs/decisions/0011-rust-compiles-types-interprets-dispatch.md`), then
entities last, against Banking, once Pizzas alone stopped exercising
new shapes:

1. **Types.** Every `value_objects` entry (closed sets as real enums),
   every aggregate's own record shape from `attributes`.
2. **Creating commands with empty `mutations`.** `assign_creation_attributes`
   alone — no `given`, no invariant check yet, just identity derivation
   and the `AlreadyExists` refusal.
3. **Invariant checking.** Every value object's `invariants` — this is
   what turns step 2 from "always accepts" into a real refusal path,
   and it's the expression grammar above, applied to a value object's
   own fields as `state` with an empty `attrs`.
4. **`given` evaluation and `apply_mutations`.** Unlocks acting
   commands with no lifecycle — `enforce_givens`, the `source`
   tagged-union walk (`argument` vs `literal`), `append`'s `fields`
   gotcha from above.
5. **Lifecycle.** `admissible_transition` + `advance_lifecycle`,
   against the flattened `transitions` array.
6. **`ensures`, with `old:`.** Needs the pre-mutation snapshot kept
   around across step 4's mutation.
7. **Entities.** `append`-typed mutations whose element type is
   another aggregate-local record, with its own identity-minting rule.

Sagas, policies, and the query DSL are real parts of the IR
(`process_managers`, `policies`, and each aggregate's own `queries`
key) that this page does not walk — they're
[policies-and-process-managers.md](policies-and-process-managers.md)
and [queries-and-read-models.md](queries-and-read-models.md)'s
subjects, written for a domain author rather than a port author, but
the IR shapes those pages describe are the same ones
`Hecksagain::Projector::Exporter` emits, not a second format.
