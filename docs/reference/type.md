# Type

<!-- generated:begin id=page -->
Words available in the type position of an `attribute`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Both examples run against `examples/banking`, which uses each spelling
once deliberately — `Account`'s ledger for the repeating field, and
`SafeDepositBox`'s size for the inline closed set:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

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

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "ty-1" },
                 name: { given: "Grace", family: "Hopper" },
                 email: { address: "grace@example.com" })
```

## list_of

<!-- generated:begin word=list_of -->
`list_of constant`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true |  |
<!-- generated:end -->

Wraps a type as a repeating field — `attribute :tags, list_of(Tag)` — a
list of `Tag` value objects, each built (and checked) the same way a
single `Tag` would be.

`Account` declares `attribute :ledger, list_of(LedgerEntry)`. The field
starts empty and each `append:` adds one more, in the order posted:

```ruby
account = Banking::Account.open(customer: "ty-1", number: { value: "ty-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
account.ledger  # => []

account.credit(amount: { cents: 2_500 }, narrative: { text: "opening deposit" })
account.credit(amount: { cents: 1_000 }, narrative: { text: "transfer in" })
account.ledger.size  # => 2
```

Each element is a whole `LedgerEntry`, checked the same way a single one
would be — its own invariants, its own closed sets:

```ruby
account.ledger.last[:narrative][:text]   # => "transfer in"
account.ledger.last[:direction][:value]  # => "credit"
```

## one_of

<!-- generated:begin word=one_of -->
`one_of literal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | literal | true |  |
<!-- generated:end -->

The inline closed-set shorthand — `attribute :finish, one_of("matte",
"glossy")` — synthesises a fresh value object for just this attribute.
It CANNOT be used inside a `value_object` block: it desugars by calling
`one_of` on the enclosing builder, and a nested `value_object` already
defines its own DIFFERENT `one_of` (the block form, see one_of.md) —
wrong arity, and the bluebook fails to load. Give the set its own
sibling `value_object` instead when it needs to live inside another
value object. Full story in aggregates-and-value-objects.md.

`SafeDepositBox` uses the shorthand for its size — no hand-written
`value_object "Size"` anywhere in the chapter, the type synthesises one:

```ruby
box = Banking::SafeDepositBox.rent(customer: "ty-1", branch_code: { value: "DT" },
                                   box_number: { value: 12 }, size: { value: "large" })
box.size.value  # => "large"
```

The set is closed, and a value outside it is refused at the door rather
than stored and discovered later:

```ruby
huge = { customer: "ty-1", branch_code: { value: "DT" }, box_number: { value: 13 }, size: { value: "enormous" } }
Banking::SafeDepositBox.rent(**huge)  # ~> InvariantViolation: Size admits "small", "medium", "large"
```

