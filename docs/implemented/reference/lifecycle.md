# Lifecycle

<!-- generated:begin id=page -->
Words available in the Lifecycle body.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example on this page runs against `examples/banking`, whose
`Account` carries a three-move lifecycle:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  attaches "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", with: { reference: { value: "lc-1" },
                                                       name: { given: "Ada", family: "Byron" },
                                                       email: { address: "ada@example.com" } })
account = Banking::Account.open!(customer: "lc-1", number: { value: "lc-a1" },
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
enforcement, the refusal it produces, and what `hecks model_check` flags
when a transition can never fire.

`Account`'s own lifecycle declares `transition "FreezeAccount" => "frozen",
from: "open"`. Nothing assigns `:status` — firing the command IS the
assignment:

```ruby
account.status  # => "open"
account.freeze_account!
account.status  # => "frozen"
```

The transition's own `from:` is enforced, not decorative — a second
`freeze_account` is refused rather than silently repeated:

```ruby
account.freeze_account!  # ~> LifecycleRefused: FreezeAccount refused — status is "frozen", and FreezeAccount moves it only from "open"
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
runtime.dispatch_flat("Banking::Account.CloseAccount", number: { value: "lc-a1" })
Banking::Account.find("lc-a1").status  # => "closed"
```

## mark

<!-- generated:begin word=mark -->
`mark name, state` — fills `marks`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | text | true | state |
<!-- generated:end -->

Names a meaning and the states that carry it: `mark :holds_seat, "pending",
"succeeded"`. A reader outside the domain (a host counting seats, a launcher
deciding what counts as a failure) asks the lifecycle for the states instead
of keeping its own copy of the list. The meaning is a lowercase word; every
state must be the default or a transition target, and a state may be named
once per mark. A lifecycle with no marks writes no `marks` into its IR.

Any lifecycle can carry marks, on an aggregate or on a nested entity.

```ruby
payment = Hecks::Bluebook::DSL::LifecycleBuilder.build(:status, default: "pending") do
  mark :holds_seat, "pending", "succeeded"
  transition "Succeed" => "succeeded", from: "pending"
end
payment.marked(:holds_seat)  # => ["pending", "succeeded"]
payment.to_h[:marks]  # => {"holds_seat"=>["pending", "succeeded"]}
```

A state the lifecycle does not have is refused when the lifecycle is built:

```ruby
Hecks::Bluebook::DSL::LifecycleBuilder.build(:status, default: "pending") { mark :holds_seat, "pending", "paid" }  # ~> Malformed: lifecycle :status mark :holds_seat names "paid", which is not a state of the lifecycle (states: pending)
```


A host reads a mark through a capability. The `payments` capability may add
an optional `holds_seat: "Payment.holds_seat"` entry (spelled
`Aggregate.mark_name`) to the chapter's `provides "payments"` row. It must name
a mark declared on that aggregate's lifecycle, or the chapter is refused when it
is built. The exported `ir.json` then carries the states in its `payments` fact
as `holds_seat: ["pending", "succeeded"]`, and the Rust host counts seats from
that list. A chapter that leaves the entry out exports exactly what it did
before, and the host falls back to its built-in default list with one warning.

The `newsletter` capability takes three such entries, all optional, over the
subscriber's lifecycle: `awaiting_confirmation:` (states waiting for the emailed
confirm link), `receives_issues:` (states that are sent each issue) and `left:`
(states of someone who has unsubscribed):

```text
provides "newsletter",
         subscribe: "Subscriber.Subscribe", add_name: "Subscriber.AddName",
         confirm: "Subscriber.Confirm", unsubscribe: "Subscriber.Unsubscribe",
         awaiting_confirmation: "Subscriber.awaiting_confirmation",
         receives_issues:       "Subscriber.receives_issues",
         left:                  "Subscriber.left"
```

Each is exported in the `newsletter` fact as a state list. The host falls back
per mark to `pending`, `confirmed` and `unsubscribed` with one warning when a
chapter leaves it out.

