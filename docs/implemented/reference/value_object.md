# ValueObject

<!-- generated:begin id=page -->
Words available inside `identified_by do ... end` / `value_object do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example runs against `examples/banking`'s `Account`, whose value
objects carry each of these three words for real:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

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
account = Banking::Account.open!(customer: "vo-1", number: { value: "vo-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## The single-attribute rule: `.value`

A value object with exactly ONE declared attribute is a NAME for a
scalar, not a genuine group — and the language treats that as a rule,
not a convention: every single-attribute value object answers `.value`,
aliasing whatever its real sole field is actually called. A
shorthand-declared `StickerRef{value}` and an author-named
`DailyLimit{cents}` answer it identically:

```ruby
account.number.value       # => "vo-a1"
account.daily_limit.value  # => 50000
account.daily_limit.cents  # => 50000
```

The alias covers indexed access (`[:value]`, `key?(:value)`) and
`with(:value, ...)` the same way — a write through the alias lands in
the REAL field, never mints a literal `:value` key. Serialization is
NOT aliased: `to_h`/`to_json` keep the real field name, so nothing
stored or exported changes shape.

A MULTI-attribute value object refuses `.value` exactly as it always
has — with two or more fields there is no single value it could
honestly mean:

```ruby
account.balance.respond_to?(:value)  # => false
```

The same rule collapses call sites: wherever a command or query
argument (or an aggregate attribute) is typed as a single-attribute
value object, a bare scalar wraps into that sole field automatically —
`daily_limit: 50_000` and `daily_limit: { cents: 50_000 }` build the
identical `DailyLimit`. The explicit field-named spelling always keeps
working; a multi-field value object still requires its fields spelled
out. The Rust runtime reads the same rule (`Fielded::as_scalar` — a
generated struct with one attribute reads as that attribute's value,
whatever its name), so a predicate comparing a single-attribute value
against a bare literal agrees across engines.

The bare declaration shorthand for this shape — `value_object
"DailyLimit", Integer`, no block — is documented with the word itself
(aggregate.md's own `value_object` section).

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

Declares a field on the value object: a name, a type (scalar or another
value object), and the usual `default:`/`optional:`/`pattern:`/`admits:`
modifiers — same word, same rules, as inside an aggregate. See
aggregates-and-value-objects.md for what each modifier promises.

`Money` is two fields, one of them defaulted:

```ruby skip
# examples/banking/bluebook/
value_object "Money" do
  attribute :cents,    Integer, default: 0
  attribute :currency, String,  default: "USD"

  invariant("a currency is a three-letter code") { currency.to_s.size == 3 }
end
```

A caller naming only `cents:` still gets a whole `Money` — `default:`
fills the rest at the door, not at read time:

```ruby
account.credit!(amount: { cents: 2_500 }, narrative: { text: "opening deposit" })
account.balance.cents     # => 2500
account.balance.currency  # => "USD"
```

Nothing at the call site names a direction — `Credit` and `Debit` each
append their own, and the closed set (`LedgerDirection`'s own
`one_of:`, above) is what makes the two readable apart:

```ruby
account.debit!(amount: { cents: 500 }, narrative: { text: "lunch" })
account.ledger.map { |entry| entry[:direction][:value] }  # => ["credit", "debit"]
```

## one_of

<!-- generated:begin word=one_of -->
`one_of do ... end` — fills `rows`
<!-- generated:end -->

The block form is gone — a single-field closed set is `attribute`'s own
`one_of:` keyword now, and a multi-field one is bare `member` lines,
both shown above. This row stays admitted only because frozen era text
still writes it (`EraGuard.shadow_parse`'s own S0a bridge reads it);
writing it in live source refuses:

```ruby
Hecks.bluebook("LedgerDirectionAgain") { aggregate("Thing") { identified_by :thing_id; value_object("Kind") { attribute :value, String; one_of { member value: "a" } } } }  # ~> Malformed: one_of do ... end wrapper is gone
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
account.credit!(amount: { cents: -1 }, narrative: { text: "negative" })  # ~> InvariantViolation: an amount is positive
```

NO BLOCK is a REFERENCE, not a fresh declaration — the same move `given`
(command.md) already makes for a shared precondition, one level over: a
rule shared across SIBLING value objects on the same aggregate,
declared once, on the first one that needs it. `Money` and
`PositiveMoney` (both on `Account`) used to both retype `invariant("a
currency is a three-letter code") { currency.to_s.size == 3 }`, byte
for byte — `Money` still declares it with a block, `PositiveMoney` now
just names it back:

```ruby
account_ir = Banking::Account.ir
money          = account_ir.value_objects.find { |vo| vo.hecks_name == "Money" }
positive_money = account_ir.value_objects.find { |vo| vo.hecks_name == "PositiveMoney" }
money.invariants.map(&:description)          # => ["a currency is a three-letter code"]
positive_money.invariants.map(&:canonical)    # => ["cents.positive?", "currency.to_s.size == 3"]
```

The currency rule fires from the same value, in the same command,
without either being mentioned where the money is spent:

```ruby
account.credit!(amount: { cents: 100, currency: "DOLLARS" }, narrative: { text: "wrong currency" })  # ~> InvariantViolation: a currency is a three-letter code
```

"Travels with the value" is literal — `Debit` never declares these
rules, and gets both anyway because it takes a `PositiveMoney` too:

```ruby
account.debit!(amount: { cents: -1 }, narrative: { text: "negative" })  # ~> InvariantViolation: an amount is positive
```

## member

<!-- generated:begin word=member -->
`member members` — opens a `Member` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | members |
<!-- generated:end -->

One legal row of a closed set, written directly in the value object's
own body — no wrapper around it. A single-field set has the shorter
`one_of:` keyword (see `attribute`, above); `member` is for when each
admitted value carries MORE than one field, so there is no single field
`one_of:` could name.

`StatementFrequency` is three fields per member — a cadence names both
how long records are kept and what a paper copy costs:

```ruby skip
# examples/banking/bluebook/
value_object "StatementFrequency" do
  attribute :cadence,          String
  attribute :retention_months, Integer
  attribute :paper_fee_cents,  Integer

  member cadence: "monthly",   retention_months: 84,  paper_fee_cents: 0
  member cadence: "quarterly", retention_months: 120, paper_fee_cents: 0
  member cadence: "annual",    retention_months: 240, paper_fee_cents: 500
end
```

Each `member` line stays exactly that — three named fields together,
never split across rows the way a single-field `one_of:` array is:

```ruby
frequency = runtime.registry.bluebook("Banking").aggregate("Statement").value_object("StatementFrequency")
frequency.closed_set?  # => true
frequency.members      # => [{ cadence: "monthly", retention_months: 84, paper_fee_cents: 0 }, { cadence: "quarterly", retention_months: 120, paper_fee_cents: 0 }, { cadence: "annual", retention_months: 240, paper_fee_cents: 500 }]
```

