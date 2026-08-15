# OneOf

<!-- generated:begin id=page -->
Words available in the OneOf body.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Both examples run against `examples/banking`'s `Account`, whose closed
sets are written the long way — a `value_object` with a `one_of` block:

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
runtime.dispatch("Banking::Customer.Register", reference: { value: "oo-1" },
                 name: { given: "Mary", family: "Jackson" },
                 email: { address: "mary@example.com" })
```

## member

<!-- generated:begin word=member -->
`member members` — opens a `Member` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | members |
<!-- generated:end -->

One legal value of the closed set, e.g. `member value: "small"`. Every
`member` inside a `one_of do ... end` block adds one more admitted value;
a value not named by any `member` is refused at the door.

`AccountKind` declares three, and an account may be opened as any of
them:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "AccountKind" do
  attribute :name, String

  one_of do
    member name: "current"
    member name: "savings"
    member name: "reserve"
  end
end
```

```ruby
account = Banking::Account.open(customer: "oo-1", number: { value: "oo-a1" },
                                kind: { name: "savings" }, daily_limit: { cents: 50_000 })
account.kind.name  # => "savings"
```

A fourth value is refused where it arrives, naming the whole admitted
set rather than only the offending value — the refusal is the closed
set read back:

```ruby
gold = { customer: "oo-1", number: { value: "oo-a2" }, kind: { name: "gold" }, daily_limit: { cents: 1 } }
Banking::Account.open(**gold)  # ~> InvariantViolation: AccountKind admits "current", "savings", "reserve"
```

