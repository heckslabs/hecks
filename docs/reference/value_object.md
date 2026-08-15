# ValueObject

<!-- generated:begin id=page -->
Words available inside `value_object do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example runs against `examples/banking`'s `Account`, whose value
objects carry each of these three words for real:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "vo-1" },
                 name: { given: "Melba", family: "Roy" },
                 email: { address: "melba@example.com" })
account = Banking::Account.open(customer: "vo-1", number: { value: "vo-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| positional 2 | text | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

Declares a field on the value object: a name, a type (scalar or another
value object), and the usual `default:`/`optional:`/`pattern:`/`admits:`
modifiers — same word, same rules, as inside an aggregate. See
aggregates-and-value-objects.md for what each modifier promises.

`Money` is two fields, one of them defaulted:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "Money" do
  attribute :cents,    Integer, default: 0
  attribute :currency, String,  default: "USD"

  invariant("a currency is a three-letter code") { currency.to_s.size == 3 }
end
```

A caller naming only `cents:` still gets a whole `Money` — `default:`
fills the rest at the door, not at read time:

```ruby
account.credit(amount: { cents: 2_500 }, narrative: { text: "opening deposit" })
account.balance.cents     # => 2500
account.balance.currency  # => "USD"
```

## one_of

<!-- generated:begin word=one_of -->
`one_of do ... end` — fills `rows`
<!-- generated:end -->

Opens the closed-set block form: a value object whose only legal values
are the `member`s declared inside. This is a DIFFERENT `one_of` from the
inline type-position shorthand documented on type.md — calling that
shorthand from inside a nested `value_object` block reaches THIS `one_of`
instead, with the wrong arity, and crashes. See type.md's `one_of`
section and aggregates-and-value-objects.md for the full trap.

`Account`'s own `LedgerDirection` is the block form, and it is what
decides whether a movement reads as a credit or a debit:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "LedgerDirection" do
  attribute :value, String

  one_of do
    member value: "credit"
    member value: "debit"
  end
end
```

Nothing at the call site names a direction — `Credit` and `Debit` each
append their own, and the closed set is what makes the two readable
apart:

```ruby
account.debit(amount: { cents: 500 }, narrative: { text: "lunch" })
account.ledger.map { |entry| entry[:direction][:value] }  # => ["credit", "debit"]
```

## invariant

<!-- generated:begin word=invariant -->
`invariant description do ... end` — fills `invariants`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A rule that travels with the value, not with any one command — it fires
in every command that carries this value object, not just the one where
it was declared. See command.md for where an invariant sits relative to
a command's other checks.

`PositiveMoney` carries two, and neither belongs to any one command:

```ruby
account.credit(amount: { cents: -1 }, narrative: { text: "negative" })  # ~> InvariantViolation: an amount is positive
```

The currency rule fires from the same value, in the same command,
without either being mentioned where the money is spent:

```ruby
account.credit(amount: { cents: 100, currency: "DOLLARS" }, narrative: { text: "wrong currency" })  # ~> InvariantViolation: a currency is a three-letter code
```

"Travels with the value" is literal — `Debit` never declares these
rules, and gets both anyway because it takes a `PositiveMoney` too:

```ruby
account.debit(amount: { cents: -1 }, narrative: { text: "negative" })  # ~> InvariantViolation: an amount is positive
```

