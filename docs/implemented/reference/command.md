# Command

<!-- generated:begin id=page -->
Words available inside `command do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against `examples/banking`, whose `Account` commands
carry roles, goals, givens, ensures, multi-fact `emits`, and `sets`
for real. A command-level `provenance` is written nowhere in the
corpus, so it gets a chapter of its own:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby bluebook
Hecks.bluebook "CommandReference" do
  vision "The three command words the corpus does not yet write."

  aggregate "Meter" do
    attribute :serial, Serial

    identified_by :serial
    attribute :reading, Reading
    attribute :marks,   list_of(Mark)

    value_object("Serial")  { attribute :value, Integer }
    value_object("Reading") { attribute :units, Integer, default: 0 }
    value_object("Mark")    { attribute :note,  String }

    command "Install" do
      sets :serial
      emits "MeterInstalled"
    end

    command "Advance" do
      # A COMMAND'S OWN PROVENANCE, one level below the aggregate's.
      provenance from: { source: "HecksCanonical", source_id: "command:meter-advance", source_version: "1.0" }

      reference_to Meter
      attribute :units, Reading
      attribute :note,  Mark
      sets :reading, increment: :units
      sets :marks,   append: { note: :note }
      emits "MeterAdvanced"
    end
  end

  # A SEPARATE AGGREGATE, purely for `delegates_to` — it needs a NESTED
  # ENTITY to hand a dispatch to, which Meter above has no real reason
  # to carry.
  aggregate "Board" do
    attribute :name,   BoardName
    identified_by :name
    attribute :pieces, list_of(Piece)

    value_object("BoardName") { attribute :value, String }
    value_object("Square")    { attribute :file, Integer; attribute :rank, Integer }
    value_object("PieceId")   { attribute :value, String }

    # THE `state` WORD'S OWN LIST — one snapshot of the board's pieces
    # per `Snapshot`, copied off the record itself.
    attribute :positions, list_of(Position)
    value_object("Position") { attribute :pieces, list_of(Piece) }

    command "Open" do
      sets :name
      emits "BoardOpened"
    end

    command "Snapshot" do
      reference_to Board
      sets :positions, append: { pieces: state(:pieces) }
      emits "BoardSnapshotted"
    end

    command "PlacePiece" do
      reference_to Board
      attribute :id,     PieceId
      attribute :square, Square
      sets :pieces, append: { id: :id, square: :square }
      emits "PiecePlaced"
    end

    # THE WORD THIS SECTION EXISTS FOR — a caller dispatches THIS, never
    # "CommandReference::Board.Piece.Move" directly.
    command "MovePiece" do
      reference_to Board
      attribute :id, PieceId
      attribute :to, Square
      delegates_to "Piece.Move", with: { id: :id, to: :to }
    end

    entity "Piece" do
      attribute :id,     PieceId
      attribute :square, Square
      identified_by :id

      command "Move" do
        attribute :to, Square
        given("destination differs from current square") { square.file != to.file || square.rank != to.rank }
        sets :square, to: :to
        emits "PieceMoved"
      end
    end
  end
end
```

```ruby boot
Hecks.hecksagon("CommandReference") do
  CommandReference::Meter.persisted_by("Memory")
  CommandReference::Board.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "cm-1" },
                 name: { given: "Annie", family: "Cannon" },
                 email: { address: "annie@example.com" })
account = Banking::Account.open!(customer: "cm-1", number: { value: "cm-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## role

<!-- generated:begin word=role -->
`role role` — fills `role`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | role |
<!-- generated:end -->

Names who calls this command — "Compliance officer", "Back office". Optional: a command with no declared `role` is never checked against anything. Where it IS declared, enforcement is opt-in on the caller's side too — unchecked by default, real once a caller states one. `Hecks.as_caller(role:, &block)` binds who is dispatching for the block (`Runtime::Caller`, `Thread.current`-backed, safe under nesting); a command whose declared `role` doesn't match refuses with `Unauthorized` (`CommandRules::Authorization#refuse_role_mismatch`, the `role_mismatch` refusal template). A policy or saga reaction never inherits the triggering caller's role — `Dispatcher#reenter` clears it, since a reaction is the system acting, not the original caller.

`Freeze` is declared `role "Compliance officer"`. Unchecked by default —
a caller who states nothing is not refused:

```ruby
runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "cm-a1" })
Banking::Account.find("cm-a1").status  # => "frozen"
```

Real the moment a caller does state one:

```ruby
Hecks.as_caller(role: "Teller") { runtime.dispatch("Banking::Account.Unfreeze", number: { value: "cm-a1" }) }  # ~> Unauthorized: Unfreeze refused
```

```ruby
Hecks.as_caller(role: "Compliance officer") { runtime.dispatch("Banking::Account.Unfreeze", number: { value: "cm-a1" }) }
Banking::Account.find("cm-a1").status  # => "open"
```

## goal

<!-- generated:begin word=goal -->
`goal goal` — fills `goal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | goal |
<!-- generated:end -->

A one-line statement of intent — "Bring in one basket and count it toward the tree's yield." Descriptive only, unlike `role`: nothing enforces that the command's body actually does what its `goal` claims.

Carried on the IR and read by nothing at dispatch:

```ruby
freeze = runtime.registry.bluebook("Banking").aggregate("Account").commands.find { |c| c.hecks_name == "FreezeAccount" }
freeze.goal  # => "Stop an account moving while something is investigated"
freeze.role  # => "Compliance officer"
```

## provenance

<!-- generated:begin word=provenance -->
`provenance from:` — fills `provenance`

| argument | kind | required | fills |
|---|---|---|---|
| `from:` | literal | true | provenance |
<!-- generated:end -->

The same fact `Aggregate#provenance` records, one level down — where a
command's own concept came from, when the command itself was adopted from a
canonical source rather than authored here. Same shape, same raw Hash, same
rule: nothing but a human, or future tooling, ever reads it.

```ruby
advance = runtime.registry.bluebook("CommandReference").aggregate("Meter").commands.find { |c| c.hecks_name == "Advance" }
advance.provenance[:source_id]  # => "command:meter-advance"
```

A raw Hash, unvalidated — which is the deliberate part. Nothing coerces
it, so nothing can refuse it either:

```ruby
advance.provenance[:source_version]  # => "1.0"
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:, optional:` — fills `references`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Whether this reference names the command's OWN aggregate decides everything: reference a different aggregate and the command creates, landing as a class method (`Tree.plant`); reference the aggregate it's declared on and the command acts on an existing record, landing as an instance method (`tree.harvest`). See commands.md's "Creating vs. acting" for the full split and the `AlreadyExists`/`NotFound` refusals each side produces.

`Open` references `Customer` — a DIFFERENT aggregate — so it creates,
and lands as a class method on the door:

```ruby
Banking::Account.respond_to?(:open!)  # => true
```

`Freeze` references `Account`, the aggregate it is declared on, so it
acts on a record that must already exist:

```ruby
runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "cm-nothing" })  # ~> NotFound: Account
```

## given

<!-- generated:begin word=given -->
`given description do ... end` — fills `givens`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A precondition, read against the record BEFORE any mutation runs. The first one that reads false refuses the whole dispatch with `GivenNotMet`, message exactly the `description` text — the rest never run. See commands.md for why the cheapest or most-likely-to-fail `given` belongs first.

`Debit` declares three, and the FIRST false one is the whole refusal —
this account is open and the balance is empty, so it is the second that
answers:

```ruby
account.debit!(amount: { cents: 999 }, narrative: { text: "nothing there" })  # ~> GivenNotMet: the balance covers it
```

The description IS the message, verbatim — which is why a `given` is
written as a sentence a caller can act on rather than a name.

## sets

<!-- generated:begin word=sets -->
`sets target, to:, append:, increment:, decrement:, multiply:, clamp:, remove:` — fills `mutations`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | target |
| `to:` | literal | false | source |
| `append:` | literal | false | source |
| `increment:` | literal | false | source |
| `decrement:` | literal | false | source |
| `multiply:` | literal | false | source |
| `clamp:` | literal | false | source |
| `remove:` | literal | false | source |
<!-- generated:end -->

`sets` is the word — ADR 0025 reverts `then_set` (the language's own grammar already declared `sets` before the DSL implementation caught up). `then_set` (below) keeps booting only for frozen era text under the legacy grammar; live source refuses it, naming `sets`. One call, one op: `to:` overwrites the field, `append:` grows a list attribute by one value object built from the pairs you name, `increment:`/`decrement:` do arithmetic on a numeric field. `to:` is omittable when it would only repeat the target — `sets :serial` alone already means `to: :serial` — and writing the redundant form out is refused. See commands.md's "`sets` — one op per field" for the flattening rule `append:` applies to a single-member value object.

`to:` overwrites, `increment:` does arithmetic, `append:` grows a list —
one op per call, three calls across two commands here:

```ruby
meter = CommandReference::Meter.install!(serial: { value: 7 })
meter.reading.units  # => 0

meter.advance!(units: { units: 12 }, note: { note: "first read" })
meter.reading.units  # => 12
meter.marks.map { |mark| mark[:note] }  # => ["first read"]
```

Arithmetic accumulates rather than replacing, which is the difference
between `increment:` and `to:`:

```ruby
meter.advance!(units: { units: 5 }, note: { note: "second read" })
meter.reading.units  # => 17
```

## then_set

<!-- generated:begin word=then_set -->
`then_set target, to:, from:, append:, increment:, decrement:, multiply:, clamp:, remove:` — fills `mutations`, **status: deprecated**

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | target |
| `to:` | literal | false | source |
| `from:` | literal | false | source |
| `append:` | literal | false | source |
| `increment:` | literal | false | source |
| `decrement:` | literal | false | source |
| `multiply:` | literal | false | source |
| `clamp:` | literal | false | source |
| `remove:` | literal | false | source |
<!-- generated:end -->

GONE — see `sets` above, the word ADR 0025 reverts to. Refuses live, unconditionally:

```ruby
Hecks.bluebook("MeterGone") { aggregate("Meter") { identified_by :serial; attribute :serial, Serial; value_object("Serial") { attribute :value, String }; command("Bump") { role "Owner"; then_set :serial, to: "x" } } }  # ~> Malformed: then_set is gone
```

## delegates_to

<!-- generated:begin word=delegates_to -->
`delegates_to target, with:` — fills `mutations`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | target |
| `with:` | literal | false | source |
<!-- generated:end -->

An AGGREGATE-level command that hands its own dispatch to ONE nested
entity command, checked and applied within the SAME atomic dispatch
rather than a separate one — the synchronous cousin of a policy's own
`trigger` or a saga's own `dispatches`. Both of those REACT to an
already-committed command and rescue the target's own refusal rather
than raising it back to the original caller, which is correct for an
eventually-consistent process that can compensate and wrong for a
caller who needs a synchronous yes/no on whether the thing they asked
for actually happened. `delegates_to` fills that gap: the target
entity command's own `given`/`ensures` are enforced as real, unrescued
exceptions, so a refusal deep in the entity's own rules is the
delegating command's own refusal too, and nothing from either side is
saved unless both sides pass. `target` is always one hop,
`"Entity.Command"`; `with:` maps this command's own arguments onto the
target's, the same way `sets ..., append: {...}`'s own field map
already does. A delegating command declares no `sets`/`emits` of its
own — its result IS the target's.

```ruby
board = CommandReference::Board.open!(name: { value: "b1" })
board.place_piece!(id: { value: "p1" }, square: { file: 3, rank: 3 })
board.move_piece!(id: { value: "p1" }, to: { file: 5, rank: 5 })

board = runtime.registry.repository("CommandReference", runtime.registry.bluebook("CommandReference").aggregate("Board")).find("b1")
board[:pieces].first[:square].to_h  # => {:file=>5, :rank=>5}
```

The caller above never names `Piece` at all — `MovePiece` is the only
door.

## emits

<!-- generated:begin word=emits -->
`emits emits` — fills `emits`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | emits |
<!-- generated:end -->

Names an event announced once the record is actually saved — `save` runs before `emit`, so a command that refuses after mutating never announces anything. One command may declare `emits` more than once, when a single act is really two facts worth reacting to separately.

`SafeDepositBox.Surrender` is the corpus's own two-fact command — the
surrender itself, and the keys it leaves outstanding. (A handle
accumulates the events of every command run through it, so the rent that
created this box is still in the list — the last two are `Surrender`'s.)

```ruby
box = Banking::SafeDepositBox.rent!(customer: "cm-1", branch_code: { value: "DT" },
                                   box_number: { value: 4 }, size: { value: "small" })
box.surrender!.events.map(&:name)  # => ["BoxRented", "BoxSurrendered", "KeyReturnDue"]
```

## state

<!-- generated:begin word=state -->
`state source` — fills `mutations`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | source |
<!-- generated:end -->

A mutation source that reads the RECORD'S OWN FIELD rather than an argument — `sets :positions, append: { pieces: state(:pieces) }` copies the pieces as they stand into the new element; `sets :last, to: state(:current)` copies one field onto another. A bare Symbol in a source always names an argument (and imports it as one when the element's field carries the same name), so before this word a command could not snapshot its own record at all: the caller would have had to hand the snapshot in, and nothing could verify it. The field must be one the aggregate declares; a name it does not is refused at build.

`Board.Snapshot` above declares no argument and records the board as it stands. A later move does not rewrite what was recorded — the copy is by value.

```ruby
board = CommandReference::Board.open!(name: { value: "b-1" })
board.place_piece!(id: { value: "p1" }, square: { file: 1, rank: 1 })
board.snapshot!
board.move_piece!(id: { value: "p1" }, to: { file: 2, rank: 2 })

board[:positions].first[:pieces].first[:square].to_h  # => {:file=>1, :rank=>1}
board[:pieces].first[:square].to_h  # => {:file=>2, :rank=>2}
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, default:, optional:, pattern:, admits:, one_of:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | true | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
| `one_of:` | list | false | one_of |
<!-- generated:end -->

Declares an argument this command needs, scalar or value object — same word, same modifiers, as an aggregate's own `attribute`. See the Type and ValueObject context pages for what each type position and modifier does.

Omittable when it would only retype what the owner already declared: a bare `sets :field` (no `to:` naming a different source) already says the command takes an argument named `:field`, so when the command itself declares no `attribute :field`, it imports the owning aggregate's (or entity's) own attribute of that name verbatim — type, pattern, `optional:`, `admits:`, all of it. `Install` above never declares `attribute :serial` — it imports `Meter`'s own `serial` — and still takes it as an argument:

```ruby
CommandReference::Meter.install!(serial: { value: 9 }).serial.value  # => 9
```

An explicit local `attribute :field` is never clobbered by this — it is checked first, so a command narrowing or retyping its own argument still wins.

A command takes the arguments it declares — all of them, and no others.
Missing one refuses:

```ruby
account.credit!(narrative: { text: "no amount" })  # ~> AbsentArgument: Credit was not given amount
```

And so does a name it never declared, rather than the value riding along
unread:

```ruby
account.credit!(amount: { cents: 1 }, narrative: { text: "ok" }, memo: "extra")  # ~> UnknownArgument: Credit does not declare memo
```

## ensures

<!-- generated:begin word=ensures -->
`ensures description do ... end` — fills `ensures`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A postcondition, read AFTER the mutation runs but before `save` — `old` names the record as it stood before, so the check can assert a relationship between the two states, not just a fact about one. A false read raises `EnsuresNotMet` and the write never reaches the store. See commands.md for why this catches what a forgotten `given` doesn't.

`Debit` declares two, and `old` is what lets the first say something a
`given` structurally cannot — a relationship between before and after:

```ruby skip
# examples/banking/bluebook/
ensures("the balance fell by exactly the amount") { old.balance.cents == balance.cents + amount.cents }
ensures("no debit leaves the balance negative")   { balance.cents >= 0 }
```

Both hold on an ordinary debit, so nothing is visible but the result —
which is what a postcondition looks like when the code is right:

```ruby
account.credit!(amount: { cents: 5_000 }, narrative: { text: "funding" })
account.debit!(amount: { cents: 2_000 }, narrative: { text: "rent" })
account.balance.cents  # => 3000
```

## corrects

<!-- generated:begin word=corrects -->
`corrects target, as:, reason:, reverses:` — fills `mutations`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | target |
| `as:` | symbol | false | source |
| `reason:` | text | false | source |
| `reverses:` | flag | false | source |
<!-- generated:end -->

A command declaring what past event it amends, rather than acting fresh — the append-only answer to "this record's history turns out to have been wrong": the original event is never rewritten, a new one is always appended on top. `target` names the event this command corrects; `as:` optionally binds the located instance for a `given`/`ensures` to reference (not yet wired into the expression evaluator — recorded for a future round); `reason:` is carried as data, not descriptive-only the way `goal` is, because an audit trail needs to say why, and a blank one is refused the moment the command is declared. `reverses: true` asks the runtime to derive the corrective `sets` itself from the original command's own mutations — see the `sets` word's own closed verb set: only `increment`/`decrement` are structurally invertible with no runtime data (the same argument, the opposite verb), so `reverses: true` against a `to:`/`multiply:`/`clamp:` original is refused at BUILD time rather than silently guessing.

Two refusals fire before any dispatch runs at all: `corrects` naming an event nothing in the aggregate ever `emits` is refused the moment the aggregate finishes building (a real event this domain never announces is an authoring mistake, not a business rule), and so is `reverses: true` against an original that used a non-invertible verb. A THIRD refusal is a dispatch-time fact about the record in hand, not the declaration — `CorrectFee` corrects `FeeApplied`, so correcting an account that was never charged a fee refuses with `NothingToCorrect`, never silently applying a correction with nothing behind it:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "cf-1" },
                 name: { given: "Annie", family: "Cannon" },
                 email: { address: "annie@example.com" })
account = Banking::Account.open!(customer: "cf-1", number: { value: "cf-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
account.correct_fee!(amount: { cents: 500 })  # ~> NothingToCorrect: CorrectFee refused — corrects FeeApplied, but Banking::Account #cf-a1 has never emitted it
```

`ApplyFee` first is what makes `CorrectFee` admissible — the correction hands the fee straight back:

```ruby
account.credit!(amount: { cents: 10_000 }, narrative: { text: "funding" })
account.apply_fee!(amount: { cents: 500 }, narrative: { text: "monthly maintenance" })
account.balance.cents      # => 9_500
account.fees_cents.cents   # => 500

account.correct_fee!(amount: { cents: 500 })
account.balance.cents      # => 10_000
account.fees_cents.cents   # => 0
```

