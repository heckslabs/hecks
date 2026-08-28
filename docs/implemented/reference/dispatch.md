# Dispatch

<!-- generated:begin id=page -->
Words available inside `dispatch do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

## compensates

<!-- generated:begin word=compensates -->
`compensates command_name, command_name, with:`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | command_name |
| positional 1 | text | true | command_name |
| `with:` | pairs | false | with_spec |
<!-- generated:end -->

Per-dispatch saga compensation, opened by an optional block on
`dispatch` itself — takes the exact same two arguments `dispatch` does
(a bare command constant, an optional `with:`), because it resolves
through the identical scope (the current event's payload, the opening
event's own memory, the correlation binding) any saga dispatch already
does.

Real, live bug this closes — `examples/banking`'s own `Settlement` saga
declares `compensates` on its own `Account.Debit` leg:

```ruby skip
# examples/banking/bluebook/transfers_and_payments.bluebook
transition "TransferRequested" => "requested", from: "requested" do
  dispatch Account::Debit, with: { number: :source, amount: :amount, narrative: { text: "transfer out" }, reference: :reference } do
    compensates Account::Credit, with: { number: :source, amount: :amount, narrative: { text: "transfer reversed" } }
  end
end
```

Before this, the compensation for a debit whose matching credit refused
lived in one hand-written list at the bottom of the saga, keyed to an
event (`"TransferReversed"`) that only arrived if someone dispatched the
reversal by hand — a destination that would not take the money left
the debit standing, the settlement stuck, and the amount nowhere: the
reversal was written and never armed. The runtime now tracks which of
an instance's own dispatches actually completed and derives
compensation from `compensates` directly:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::Transfer.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

Fund a source account, freeze the destination, and ask for a transfer —
`Account.Credit` on the destination refuses partway through, after the
money already left the source:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                  name: { given: "Nils", family: "Voss" }, email: { address: "nils@example.com" })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "src" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "dst" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: "src", amount: { cents: 1000 }, narrative: { text: "opening balance" })
runtime.dispatch("Banking::Account.FreezeAccount", number: "dst")

runtime.dispatch("Banking::Transfer.Request", reference: { value: "t1" }, amount: { cents: 200 },
                  narrative: { text: "rent" }, source: "src", destination: "dst")

Banking::Account.find("src").balance.to_h  # => { cents: 1000, currency: "USD" }
```

1000, not 800 — `Account.Debit`'s own declared `compensates` fired the
moment `Account.Credit` refused, giving the source its money back. The
saga log names it distinctly (`compensation: true`), not folded into an
ordinary dispatch entry:

```ruby
runtime.sagas.select { |s| s[:instance] == "t1" && s[:compensation] }.map { |s| [s[:dispatch], s[:delivered]] }  # => [["Account.Credit", true]]
```

`Account.Credit`'s own leg — the one that refused — declares no
`compensates` at all, and needs none: a leg that never completed has
nothing of its own to undo. See
`docs/implemented/guides/policies-and-process-managers.md`'s own
"Compensation" section for the full walkthrough, including the
unconditional `Transfer.Reverse` mark that stays hand-written on the
saga's own `on :refused` leg rather than becoming a second `compensates` —
it does not undo any one dispatch's own effect.

