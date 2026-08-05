# Commands

You are about to ship a feature, and the feature is a command: some
actor does something to your domain, and the domain either does it or
says why not. Before you write one, you need three things — the full
inventory of what a command can declare (there is nothing else), the
exceptions your caller has to be ready to catch, and the difference
between a rule you enforce going in and a guarantee you check coming
out. All three are provable in one sitting, against a real domain.

The examples below use `examples/banking/bluebook/banking.bluebook` —
customers hold accounts, accounts move money, cards get disputed,
scheduled payments retry themselves against a limit, and a compliance
officer freezes what needs investigating. It is a real, running
domain, not a rehearsal: every dispatch below is a real command
declared in that file, executed against a real boot of it.

## The declaration

A command is `role`, `goal`, one or more `attribute`s, an optional
`reference_to`, zero or more `given`s, zero or more `ensures`, zero or
more `then_set`s, and one or more `emits` — nothing else, no handler
body to smuggle a side effect into. `Account`'s own commands carry
every piece of that inventory at least once, quoted here directly from
the bluebook (never run as shown — the boot below loads the real file
instead of retyping it):

```ruby skip
command "Open" do
  role "Branch clerk"
  goal "Give a customer somewhere to keep money"

  reference_to Customer
  attribute :number,      AccountNumber
  attribute :kind,        AccountKind
  attribute :daily_limit, DailyLimit

  then_set :number,      to: :number
  then_set :kind,        to: :kind
  then_set :daily_limit, to: :daily_limit

  emits "AccountOpened"
end

command "Credit" do
  role "Teller"
  goal "Put money in"

  reference_to Account
  attribute :amount,    PositiveMoney
  attribute :narrative, Narrative

  given("the account is open")      { status == "open" }
  then_set :balance, increment: :amount
  then_set :ledger,  append: { amount: :amount, narrative: :narrative, direction: { value: "credit" } }

  emits "AccountCredited"
end

command "Debit" do
  role "Teller"
  goal "Take money out, if it is there to take"

  reference_to Account
  attribute :amount,    PositiveMoney
  attribute :narrative, Narrative

  given("the account is open")       { status == "open" }
  given("the balance covers it")     { balance.cents >= amount.cents }
  given("the daily limit allows it") { daily_limit.cents >= amount.cents }

  then_set :balance, decrement: :amount
  then_set :ledger,  append: { amount: :amount, narrative: :narrative, direction: { value: "debit" } }

  ensures("the balance fell by exactly the amount") { old.balance.cents == balance.cents + amount.cents }
  ensures("no debit leaves the balance negative")   { balance.cents >= 0 }

  emits "AccountDebited"
end

command "Freeze" do
  role "Compliance officer"
  goal "Stop an account moving while something is investigated"

  reference_to Account
  emits "AccountFrozen"
end
```

`Open` takes in a customer and gives back a fresh account: a creating
command, no `given`, three `then_set to:`. `Credit` and `Debit` are
where the rest of the inventory earns its place — a `given` guarding
mutation, `then_set increment:`/`decrement:` doing arithmetic,
`then_set append:` growing the ledger, and, on `Debit` alone, two real
`ensures`. `Freeze` is the floor of the inventory: `role`, `goal`,
`reference_to`, `emits`, nothing more — a command needs no `given`, no
`attribute`, no `then_set` to be a complete one, as long as something
downstream (here, the account's own lifecycle) still gates it.

## Wiring

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
  Banking::ScheduledPayment.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
end
```

## What you must handle

Every command you write can fail in a fixed set of ways, and your
caller — a controller action, a saga step, a test — has to be ready for
whichever ones apply to it. This is the complete roster for a command
dispatch; the rest of this page proves each row once, live, against
`Banking`:

| raises | when | shown |
|---|---|---|
| `GivenNotMet` | a declared `given` reads false | debiting a frozen account |
| `EnsuresNotMet` | a declared `ensures` reads false, AFTER the mutation ran | `Debit`'s own two postconditions — discussed below |
| `InvariantViolation` | a value object's own rule rejects the fields it was built from | an account opened with no number |
| `LifecycleRefused` | the command names a transition the current state cannot take | freezing an already-frozen account |
| `AlreadyExists` | a creating command's identity already names a record | opening the same account number twice |
| `NotFound` | an acting command's identity names no record | freezing an account that was never opened |
| `AbsentArgument` | a required attribute never arrived | opening an account with no `kind` |
| `UnknownArgument` | an argument arrived that the command never declared | crediting with a stray `memo:` |
| `TypeMismatch` | an argument arrived in the wrong shape — a reference handed as an object is the case that costs the most in practice | a customer passed as an object instead of an id |

Every one of these is a `StandardError` subclass under
`Hecksagain::Runtime`, and every one is the domain answering, not the
runtime breaking. A refusal is a response, not a malfunction.

## Creating vs. acting

A command either creates a new record or acts on one that already
exists, and the DSL reads this off one fact: does the command
`reference_to` its own aggregate. `Open` doesn't — it references
`Customer`, a different aggregate, to say whose account this is — so
`Open` creates, and the facade installs it as a method on the
aggregate module itself. `Credit`, `Debit`, and `Freeze` all
`reference_to Account`, their own aggregate, so each is a method on
the record in hand. Get this backwards in your own bluebook — add a
stray `reference_to Self` to what should be a creating command — and
it silently stops being callable the way a controller expects.

```ruby
Banking::Account.respond_to?(:open)    # => true
Banking::Account.respond_to?(:credit)  # => false
```

```ruby
customer = Banking::Customer.register(reference: { value: "C-1" },
                                       name: { given: "Ada", family: "Lovelace" },
                                       email: { address: "ada@example.com" })
account  = Banking::Account.open(customer_id: customer.id, number: { value: "AC-1" },
                                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
account.number.to_h  # => { value: "AC-1" }
```

A creating command's identity still has to be FRESH — dispatch `Open`
again with a number you already used and there is no second account,
only a collision with the one you have:

```ruby
Banking::Account.open(customer_id: customer.id, number: { value: "AC-1" }, kind: { name: "current" }, daily_limit: { cents: 100_000 })  # ~> AlreadyExists: Open creates a Account that already exists
```

## `given` — the rule you enforce going in

A `given` reads the record as it stands BEFORE any mutation and refuses
if it doesn't like what it sees. The refusal is `GivenNotMet`, and the
message is exactly the description you wrote — nothing templated, no
translation between what you declared and what the caller reads.
`Freeze` carries no `given` at all — its lifecycle transition is the
only gate it has, and that is enough on its own:

```ruby
account.freeze
account.status  # => "frozen"
```

Call it again and there is no state left for the transition to move
from — the refusal is `LifecycleRefused`, not `GivenNotMet`, because
nothing declared on `Freeze` itself objected:

```ruby
account.freeze  # ~> LifecycleRefused: Freeze refused
```

`Debit` declares three givens, and multiple givens run in the order you
wrote them — the FIRST one that reads false is the one your caller
sees, and the others never run at all. Its order is "the account is
open", then "the balance covers it", then "the daily limit allows it",
so a frozen account with an amount that would also blow both the
balance and the limit still only reports the first:

```ruby
account.unfreeze
account.freeze
account.debit(amount: { cents: 999_999 }, narrative: { text: "frozen debit" })  # ~> GivenNotMet: the account is open
```

That account is also nowhere near covering that amount, which would
fail `Debit`'s second given just as surely — but you will never see
that message from this call, because the first refusal wins and the
dispatch stops there. Unfreeze it and the second given gets its turn:

```ruby
account.unfreeze
account.debit(amount: { cents: 999_999 }, narrative: { text: "too much" })  # ~> GivenNotMet: the balance covers it
```

Write your givens with the cheapest or most-likely-to-fail check first
if you want your callers reading the most useful message; the runtime
will not reorder them for you.

A `given` can also name the record ITSELF as the thing it refuses a
second run of. `ScheduledPayment.Retry` declares `given("a retry is
still allowed") { attempts.value < max_attempts.value }` on a command
that `reference_to ScheduledPayment` — its own aggregate — and whose
own `emits "ScheduledPaymentFailed"` is the SAME event a policy in this
chapter answers by triggering `Retry` again. One failed presentment
already re-enters itself, live, up to its own limit, before your code
ever gets control back:

```ruby
sp = Banking::ScheduledPayment.schedule(account_id: account.id, instruction: { value: "I-1" },
                                         amount: { cents: 5000 }, recipient: { value: "Landlord" },
                                         due_on: { value: "2026-09-01" })
sp.fail
Banking::ScheduledPayment.find(sp.id).attempts.to_h  # => { value: 3 }
```

`max_attempts` defaults to 3, and the reflex ran itself out to exactly
that before this line even returned — a refusal raised INSIDE a
policy's own reaction is caught and recorded there, not thrown back at
whoever dispatched the command that started the chain (see
[Policies and process managers](policies-and-process-managers.md) for
the mechanism). Dispatch `Retry` again yourself, directly, and the same
`given` refuses it the ordinary way:

```ruby
Banking::ScheduledPayment.find(sp.id).retry  # ~> GivenNotMet: a retry is still allowed
```

`Abandon` declares the mirror image — `given("every retry is
exhausted") { attempts.value >= max_attempts.value }` — which only
reads true now that the reflex above has run its course:

```ruby
Banking::ScheduledPayment.find(sp.id).abandon
Banking::ScheduledPayment.find(sp.id).status  # => "abandoned"
```

## `ensures` — the guarantee you check coming out

A `given` reads the record before the mutation runs. An `ensures` reads
it AFTER — against the settled state, with `old` naming the record as
it stood before, so you can assert a relationship between the two
rather than just a fact about one. `enforce_ensures` is the step right
after `apply_mutations` in the dispatch pipeline, and it still sits
before `save` — a failed `ensures` never reaches the store.

`Debit` carries two, and a credit followed by a debit proves both
without either one raising:

```ruby
account.credit(amount: { cents: 500 }, narrative: { text: "paycheck" })
account.debit(amount: { cents: 200 }, narrative: { text: "rent" })
account.balance.to_h  # => { cents: 300, currency: "USD" }
```

Neither of `Debit`'s `ensures` has ever needed to fire here, and that
is not an oversight — it is what the three `given`s above already
bought. "the balance fell by exactly the amount" is arithmetic
`decrement:` guarantees on its own; "no debit leaves the balance
negative" can only be threatened by an amount the SECOND given, "the
balance covers it", already refused before the mutation ran at all.
Written down anyway, it is not a trap waiting to be tripped by THIS
domain's own commands — it is what would catch a later edit that
loosens or removes that given without anyone noticing the postcondition
it was quietly protecting. A `given` is a rule you remembered to write
going in; an `ensures` is a guarantee that holds regardless of what a
future you remembers.

## `then_set` — one op per field, and the op is a real decision

Four operations, and which one you reach for is not stylistic — it is
the difference between overwriting a field, growing a list, and doing
arithmetic on one.

**`to:`** replaces the field outright, from an argument or a literal.
`Open` does it three times over, from arguments:

```ruby
account.kind.to_h  # => { name: "current" }
```

A literal target is legal too — `Customer.Reinstate` sets its standing
back with `then_set :standing, to: { value: "good" }` rather than
reading it off an argument, because a reinstated customer's standing is
always "good", not whatever the caller happened to pass.

**`append:`** grows a list attribute by one value object, built from
the fields you name. `Credit` and `Debit` both append to `Account`'s
`ledger`, and the credit and debit above already proved it grew:

```ruby
account.ledger.map { |entry| entry[:amount].to_h }      # => [{ cents: 500, currency: "USD" }, { cents: 200, currency: "USD" }]
account.ledger.map { |entry| entry[:direction].to_h }    # => [{ value: "credit" }, { value: "debit" }]
```

`direction:` is not an argument at all in either command — `{ value:
"credit" }` and `{ value: "debit" }` are literals baked into the
`then_set` itself, the same way `append:` can take a literal alongside
an argument-sourced field. Hand `append:` a value object with more than
one member for a slot the target entity declares as a bare scalar and
it has no single field to flatten to — that refusal is `TypeMismatch: …
cannot stand in for a scalar`, not shown here because no entity field
in this chapter is declared that way, but worth knowing before you
design one that is.

**`increment:` / `decrement:`** do arithmetic on a numeric field —
either a plain Integer or, as here, the one shared Integer field
between two value objects. `Money#cents` and `PositiveMoney#cents`
share a name and a type, and that shared name is what lets the runtime
know which field to add or subtract — already proven above, alongside
the `ensures` that watches the result. `ScheduledPayment.Retry` does
the same arithmetic on a bare Integer instead of a shared field name:
`then_set :attempts, increment: { value: 1 }` moved `attempts` from 0
to 3 across the reflex proven in the `given` section above.

## `emits` — a promise made after the write, not before

Events are announced only once the record has actually been saved:
`save` runs before `emit` in the dispatch order, so a command that gets
all the way to raising `EnsuresNotMet` never announces anything —
there is nothing after a refusal for a caller to react to. Read them
back off the record — every attempt above that refused left no mark;
only the ones that actually ran show up:

```ruby
account.events.map(&:name)  # => ["AccountOpened", "AccountFrozen", "AccountUnfrozen", "AccountFrozen", "AccountUnfrozen", "AccountCredited", "AccountDebited"]
```

One command can announce more than one fact. `SafeDepositBox.Surrender`
does — the box is given back, and the keys still outstanding against it
are a separate fact worth their own event, not a detail folded into the
first. A composite identity like this one — `branch_code` and
`box_number` together — is addressed by naming both parts directly
rather than through the single-argument facade sugar used above:

```ruby
runtime.dispatch("Banking::SafeDepositBox.Rent", customer_id: customer.id,
                  branch_code: { value: "DT" }, box_number: { value: 12 }, size: { value: "small" })
runtime.dispatch("Banking::SafeDepositBox.Surrender", branch_code: { value: "DT" }, box_number: { value: 12 })
Banking::SafeDepositBox.find("DT:12").events.last(2).map(&:name)  # => ["BoxSurrendered", "KeyReturnDue"]
```

## The argument gate

Before any rule runs, before the record is even hydrated, a command's
arguments are checked for shape. Five things to know before you wire a
caller to one of these:

A required attribute that never arrives refuses before anything else
happens — no partial record, no half-run mutation:

```ruby
Banking::Account.open(customer_id: customer.id, number: { value: "AC-2" }, daily_limit: { cents: 0 })  # ~> AbsentArgument: Open was not given kind
```

An argument the command never declared at all refuses just as early,
the other half of the same gate — a misspelled or stray field does not
ride along in silence:

```ruby
account.credit(amount: { cents: 100 }, narrative: { text: "x" }, memo: "nope")  # ~> UnknownArgument: Credit does not declare memo
```

A value object's own invariant travels with it into every command that
carries one, checked the moment the argument is coerced — before
`Open`'s given, before its identity is even looked up:

```ruby
Banking::Account.open(customer_id: customer.id, number: { value: "" }, kind: { name: "current" }, daily_limit: { cents: 0 })  # ~> InvariantViolation: AccountNumber invariant violated — an account number is present
```

A value object arrives as its fields, plainly — `{ name: "current" }`,
`{ cents: 100 }` — never as a constructed instance. A reference to
another aggregate, by contrast, arrives as a bare id — the string
`customer.id`, not an object describing the customer:

```ruby
Banking::Account.open(customer_id: { reference: customer.id }, number: { value: "AC-4" }, kind: { name: "current" }, daily_limit: { cents: 0 })  # ~> TypeMismatch: a reference is an id, and customer_id arrived as an object
```

`CardPayment.Dispute` is the one command in this chapter carrying BOTH
a self reference and a cross-aggregate one at once — `reference_to
CardPayment` makes it act on the payment in hand, and `reference_to
Customer, as: :disputed_by` names who is challenging the charge, since
neither the payment nor its account says which holder of a joint
account raised the dispute. The same rule about a bare id applies to
that second reference exactly as it did to `Open`'s:

```ruby
cp = Banking::CardPayment.authorize(account_id: account.id, authorisation: { value: "AUTH-1" },
                                     amount: { cents: 4200 }, merchant: { value: "Cafe" })
cp.capture
cp.dispute(disputed_by: { reference: customer.id })  # ~> TypeMismatch: a reference is an id, and disputed_by arrived as an object
cp.dispute(disputed_by: customer.id)
cp.disputed_by  # => "C-1"
```

And a command acting on an identity that names no record refuses with
`NotFound`, not a nil you have to check for yourself:

```ruby
runtime.dispatch("Banking::Account.Freeze", number: "no-such-account")  # ~> NotFound: no Account with number.value
```

## Refusals leave state untouched

A refusal that happens after mutation but before save — an `ensures`,
mainly — never reaches the store. A `given` that refuses, a
`LifecycleRefused`, a dangling reference, all stop the same dispatch
pipeline the same way: a command either completes and persists, or it
refuses and the record you already had stands exactly as it was. The
account above still holds exactly what its last SUCCESSFUL debit left
it at, not whatever a refused call tried to write:

```ruby
account.debit(amount: { cents: 999_999 }, narrative: { text: "nope" })  # ~> GivenNotMet: the balance covers it
Banking::Account.find(account.id).balance.to_h  # => { cents: 300, currency: "USD" }
```
