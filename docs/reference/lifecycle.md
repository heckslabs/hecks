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
runtime.dispatch("Banking::Customer.Register", reference: { value: "lc-1" },
                 name: { given: "Ada", family: "Byron" },
                 email: { address: "ada@example.com" })
account = Banking::Account.open(customer: "lc-1", number: { value: "lc-a1" },
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

```ruby
account.status  # => "open"
account.freeze_account
account.status  # => "frozen"
```

The transition's own `from:` is enforced, not decorative — a second
`freeze_account` is refused rather than silently repeated:

```ruby
account.freeze_account  # ~> LifecycleRefused: FreezeAccount refused — status is "frozen", and FreezeAccount moves it only from "open"
```

The refusal names `FreezeAccount` itself, not the transition, because
this corpus declares the command as `command "FreezeAccount", from:
"open"` (a Command-context word — see command.md — added by S10, ADR
0025). That guard is checked in the SAME dispatch step every `given`
already runs at, which is BEFORE `admissible_transition` — the
transition's own check — ever gets a turn, so it is what a caller
actually sees. It used to take two independent declarations to say
"open" here: a free-text `given("account is open") { status == "open"
}` alongside the transition's own `from: "open"`, each able to drift
out of sync with the other. Now there is one: the command's `from:`
names the SAME lifecycle field the transition does, so there is
nothing left to disagree. `CardPayment`, elsewhere in this corpus,
still carries the older, given-shaped guard on every one of its own
commands — see lifecycles.md, which walks that overlap in full.

Given a list, the command may fire from any of several states —
`transition "CloseAccount" => "closed", from: ["open", "frozen"]`
closes an account whether or not it was frozen first:

```ruby
runtime.dispatch("Banking::Account.CloseAccount", number: { value: "lc-a1" })
Banking::Account.find("lc-a1").status  # => "closed"
```

