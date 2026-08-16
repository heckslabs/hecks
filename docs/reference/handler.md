# Handler

<!-- generated:begin id=page -->
Words available inside `transition do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

## dispatch

<!-- generated:begin word=dispatch -->
`dispatch command_name, command_name, with:` — opens a `Dispatch` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | command_name |
| positional 1 | text | true | command_name |
| `with:` | pairs | false | with_spec |
<!-- generated:end -->

Fires a command from inside a handler leg, mapping the saga instance's
own fields onto the command's arguments via `with:`. A bare command
constant, same as a policy's `trigger` — `Aggregate::Command` — resolved
same-domain by default, or `Domain::Aggregate::Command` to reach another
domain directly; there is no separate `across` here, the qualified
constant carries it.

`examples/banking`'s `Onboarding` saga carries one dispatching leg, and
`with:` is where the saga's own memory of the opening event becomes the
command's arguments — `customer: :customer` reads the field the
saga remembered, and `kind:`/`daily_limit:` are literals the saga
supplies itself:

```ruby skip
# examples/banking/bluebook/banking.bluebook
transition "OnboardingCleared" => "cleared", from: "screening" do
  dispatch Account::Open, with: {
    customer: :customer, number: :account_number,
    kind: { name: "current" }, daily_limit: { cents: 0 }
  }
end
```

Nothing at the call site names an account. Clearing the case is the
whole act, and the account exists afterwards:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "hd-1" },
                 name: { given: "Annie", family: "Easley" },
                 email: { address: "annie@example.com" })
kase = Banking::OnboardingCase.open!(customer: "hd-1", reference: { value: "hd-c1" },
                                    account_number: { value: "hd-a1" })
kase.clear!

Banking::Account.find("hd-a1")[:customer]  # => "hd-1"
```

The delivery is recorded, so a leg that fired and a leg that never ran
are distinguishable after the fact:

```ruby
runtime.registry.saga_log.last[:dispatch]   # => "Account.Open"
runtime.registry.saga_log.last[:delivered]  # => true
```

