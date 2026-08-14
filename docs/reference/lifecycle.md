# Lifecycle

<!-- generated:begin id=page -->
Words available in the Lifecycle body.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example on this page runs against `examples/banking`, whose
`Account` carries a three-move lifecycle:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "lc-1" },
                 name: { given: "Ada", family: "Byron" },
                 email: { address: "ada@example.com" })
account = Banking::Account.open(customer_id: "lc-1", number: { value: "lc-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## transition

<!-- generated:begin word=transition -->
`transition pairs, from:, from:` — fills `transitions`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
| `from:` | text | false | from_state |
| `from:` | list | false | from_state |
<!-- generated:end -->

One legal move: `"Command" => "state", from: "state"` — the command may
fire only when the field is at `from:` (or, given an array, at one of
several), and lands at the target state after. See lifecycles.md for
enforcement, the refusal it produces, and what `bin/model_check` flags
when a transition can never fire.

`Account`'s own lifecycle declares `transition "FreezeAccount" => "frozen",
from: "open"`. Nothing assigns `:status` — firing the command IS the
assignment:

The command is dispatched by name rather than through the door's
`account.freeze_account` sugar — `Freeze` snake-cases to `freeze`, which is
also `Object`'s, and an example is a poor place to lean on a collision
even though `Handle#define_verb_methods` resolves it:

```ruby
account.status  # => "open"
runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "lc-a1" })
Banking::Account.find("lc-a1").status  # => "frozen"
```

`from:` is enforced, not decorative — a second `Freeze` is refused
rather than silently repeated:

```ruby
runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "lc-a1" })  # ~> GivenNotMet: FreezeAccount refused — account is open
```

The refusal names a `given`, not the transition, and that is not an
accident: banking states the rule twice on purpose. `Freeze` carries
its own `given("account is open") { status == "open" }` alongside
`from: "open"`, so the given answers first and says so in business
language. The transition is still the enforcement of last resort — see
lifecycles.md, which walks the same overlap on `CardPayment`.

Given a list, the command may fire from any of several states —
`transition "CloseAccount" => "closed", from: ["open", "frozen"]`
closes an account whether or not it was frozen first:

```ruby
runtime.dispatch("Banking::Account.CloseAccount", number: { value: "lc-a1" })
Banking::Account.find("lc-a1").status  # => "closed"
```

