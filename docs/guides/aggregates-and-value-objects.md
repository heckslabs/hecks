# Aggregates and value objects

This guide covers the decisions involved in modeling domain state:
whether a concept gets an identity of its own or is just a value two
records might share, and whether an invalid shape is refused at the
point a caller sends it or only discovered later against production
data. Each section below covers one such decision, along with a
demonstration of what happens when it is made incorrectly.

The domain used throughout is the real one this project ships:
`examples/banking/bluebook/banking.bluebook`, a bank's customers,
accounts, cards, and transfers. It is large enough to carry a composite
key, several closed vocabularies, a reference that is deliberately
misused to demonstrate a refusal, and the `belongs_to` sugar — every
construct this guide needs except one: banking's own value objects are
all exactly one field deep, so the final section — a value object
holding another value object — draws instead from
`examples/pizzas/bluebook/pizzas.bluebook`'s `Order`, and says so where
it happens.

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
  Banking::ATMCard.persisted_by("Memory")
  Banking::ExternalTransfer.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
end
```

## Identity: one field, or several — and why that is not a style choice

The first decision, before any attribute, is whether a concept has a
lifecycle of its own, addressable by a key that never changes meaning —
an aggregate — or is just a value, interchangeable with any other
instance carrying the same fields — a value object. Getting this wrong
means either building CRUD around something that was never more than a
number, or letting two genuinely different records collide because
nothing told the runtime how to tell them apart.

`identified_by` is where an aggregate declares which field answers
"which one is this." A single path reads back exactly as written —
`Customer` is identified by its reference:

```ruby skip
# examples/banking/bluebook/banking.bluebook
aggregate "Customer" do
  identified_by :reference
  attribute :reference, CustomerNumber
  ...
end
```

```ruby
customer = Banking::Customer.register(reference: { value: "CUST-1000" },
                                       name: { given: "Ada", family: "Byron" },
                                       email: { address: "ada@example.com" })

customer.id   # => "CUST-1000"
```

A composite identity reads back as its parts joined by `:`, in the
order declared — `SafeDepositBox` needs one because a box number by
itself does not say which vault it is in:

```ruby skip
# examples/banking/bluebook/banking.bluebook
aggregate "SafeDepositBox" do
  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber

  identified_by :branch_code, :box_number
  ...
end
```

```ruby
box = Banking::SafeDepositBox.rent(customer_id: customer.id,
                                    branch_code: { value: "downtown" },
                                    box_number: { value: 12 },
                                    size: { value: "small" })

box.id   # => "downtown:12"
```

This is the actual purpose of `identified_by`: two boxes with the same
branch and number are not two boxes that happen to agree — they are the
same record, and a second `Rent` against that pair is not a fresh box,
it is a duplicate:

```ruby
Banking::SafeDepositBox.rent(customer_id: customer.id, branch_code: { value: "downtown" }, box_number: { value: 12 }, size: { value: "medium" })   # ~> AlreadyExists: already exists
```

That refusal is the whole reason `identified_by` exists. If two records
can carry the same fields and still be two different things (a customer
and their twin), you need a field that actually distinguishes them, or
your aggregate silently collapses cases the business considers
distinct. If two records with the same fields ARE the same thing (a
box, known by where it is), `identified_by` is what lets the runtime
catch a caller who tries to open it twice. This is not a modelling
nicety — it is the difference between a domain that notices a duplicate
and one that quietly overwrites a record because two callers happened
to agree on a name.

## What an attribute actually promises

Every `attribute` line is a promise about what a field can hold and
what happens when a caller gets it wrong. The first decision is scalar
or value object: a bare `String` or `Integer` carries no rules of its
own, so any invariant, pattern, or closed set has to live wherever the
attribute is declared — and if you forget it on one command, that
command is the hole. A value object carries its rules once, wherever it
is used. If a field means something on its own (an amount that can't go
negative, an address that must look a certain way), give it a value
object; if it is really just a scalar with a name, a `String` is honest
about that. Guess wrong here and you either write the same validation
four times (and eventually forget one), or you wrap a plain string in
ceremony nothing ever checks.

`optional:` and `default:` are two separate promises, easy to conflate.
`optional:` only says a caller may leave an argument out — it says
nothing about what the field becomes; `default:` is the separate,
explicit promise that fills a gap. `Account::DailyLimit` declares one
on its own field:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "DailyLimit" do
  attribute :cents, Integer, default: 0
  invariant("a daily limit is non-negative") { !cents.negative? }
end
```

Open an account and hand `daily_limit` an empty hash — the field itself
is required, but nothing says `cents` has to be in it, and `default:`
fills that gap the moment the record is built:

```ruby
account = Banking::Account.open(customer_id: customer.id, number: { value: "ACC-1000" },
                                 kind: { name: "current" }, daily_limit: {})

account.daily_limit.to_h   # => { cents: 0 }
```

Now the other half of the promise. `CardPayment.Authorize` marks its
`tags` optional:

```ruby skip
# examples/banking/bluebook/banking.bluebook
command "Authorize" do
  reference_to Account
  attribute :authorisation, AuthorisationCode
  attribute :amount, PaymentAmount
  attribute :merchant, MerchantName
  attribute :tags, list_of(Tag), optional: true
  ...
end
```

Authorize a payment without ever mentioning `tags` — the command
accepts the call, no refusal for one missing:

```ruby
payment = Banking::CardPayment.authorize(account_id: account.id,
                                          authorisation: { value: "AUTH-1000" },
                                          amount: { cents: 500 }, merchant: { value: "Cafe" })

payment.tags   # => nil
```

Worth sitting with: `tags` did not become `[]`. `optional:` only
promises the argument gate won't refuse a missing key — it never
promises a fallback value. `Authorize` reads the missing key straight
through `then_set :tags, to: :tags`, and an absent key resolves to
`nil` the same way any other unread hash key would — `DailyLimit`,
above, only got its fallback because it declared one explicitly.

`default:` can also sit on an attribute typed as a whole value object,
not just on one of that value object's own fields — `SafeDepositBox`'s
`size` is declared the inline-shorthand way, and its default fills
`Size`'s own field, not the bare string a first instinct might reach
for:

```ruby skip
# examples/banking/bluebook/banking.bluebook
attribute :size, one_of("small", "medium", "large"), default: { value: "small" }
```

```ruby
box.size.to_h   # => { value: "small" }
```

`Rent` requires `size` on every call, so that default never actually
fires through ordinary traffic here — but the SHAPE is what the checker
validates the moment the bluebook loads, whether or not any command
path ever exercises it. Writing a bare scalar instead of a fields-hash
still lets the bluebook load — it fails later, at every single create,
because the value object wants its fields and gets a number instead:

```ruby
def banking_bad_default
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    code = <<~RUBY
      Hecks.bluebook("BankingBadDefault") do
        aggregate "Thing" do
          identified_by :thing_id
          value_object("Price") { attribute :cents, Integer }
          attribute :price, Price, default: 0
        end
      end
    RUBY
    file = Tempfile.new(["banking-bad-default-", ".bluebook"])
    file.write(code)
    file.flush
    Kernel.eval(code, TOPLEVEL_BINDING, file.path, 1)
  end
end

banking_bad_default   # ~> Malformed: a default fills its FIELDS
```

That refusal fires the moment the bluebook is declared, not the moment
someone forgets to pass `price`. A default that cannot describe the
type it defaults is a bug you would otherwise ship and discover only
when every create using it fails.

A pattern is refused the same way — at declaration, not at the first
bad value. `pattern:` only admits regexes every engine reads
identically (explicit ranges, alternation, anchors); lookahead and the
`\d`/`\w` perl classes are refused outright, because they mean
different things — ASCII here, Unicode there — depending on which
engine reads them:

```ruby
def banking_bad_pattern
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    code = <<~RUBY
      Hecks.bluebook("BankingBadPattern") do
        aggregate "Thing" do
          identified_by :thing_id
          value_object("Code") { attribute :value, String, pattern: '^(?=.*[A-Z]).+$' }
          attribute :code, Code
        end
      end
    RUBY
    file = Tempfile.new(["banking-bad-pattern-", ".bluebook"])
    file.write(code)
    file.flush
    Kernel.eval(code, TOPLEVEL_BINDING, file.path, 1)
  end
end

banking_bad_pattern   # ~> Malformed: uses a lookahead
```

A pattern that IS admitted still refuses a value that does not match
it — that check runs at the door, when a caller actually offers an
address, not buried inside a predicate three commands later.
`Customer::EmailAddress` declares one:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "EmailAddress" do
  attribute :address, String, pattern: '^[^@ ]+@[^@ ]+\.[^@ ]+$'
end
```

```ruby
Banking::Customer.register(reference: { value: "CUST-BAD" }, name: { given: "X", family: "Y" }, email: { address: "not-an-email" })   # ~> TypeMismatch: must match
```

And `admits:` refuses the same way, for a set declared somewhere else
entirely. `ExternalTransfer`'s `direction` names `Account::LedgerDirection`
rather than restating `credit`/`debit` a second time — once on the
head, once again on the `Request` command that fills it — so a caller
who ships a direction the ledger doesn't recognise is refused with the
SAME vocabulary `Account` itself enforces:

```ruby skip
# examples/banking/bluebook/banking.bluebook
attribute :direction, MovementDirection, admits: "Account::LedgerDirection"
# ... and again, on Request:
attribute :direction, MovementDirection, admits: "Account::LedgerDirection"
```

```ruby
ext = Banking::ExternalTransfer.request(account_id: account.id, end_to_end: { value: "E2E-1000" },
                                         amount: { cents: 1000 }, beneficiary: { value: "Someone" },
                                         direction: { value: "debit" })

ext.direction.to_h   # => { value: "debit" }

Banking::ExternalTransfer.request(account_id: account.id, end_to_end: { value: "E2E-1001" }, amount: { cents: 1000 }, beneficiary: { value: "Someone" }, direction: { value: "sideways" })   # ~> InvariantViolation: got "sideways"
```

## Where a rule actually belongs

A value object's `invariant` is not a validation attached to one
command — it travels with the type, into every command that carries
it. That is what `invariant` provides: the rule is written once, on the
value, and every future command that accepts that value inherits it
whether the author remembers to add it or not. The alternative — a
`given` repeated on each command that touches an amount — can hold for
the first several commands and silently stop holding on a later one
added without noticing the pattern.

`PositiveMoney` declared its invariant once — `cents.positive?` — and
it fires on two commands that have nothing else in common: `Credit`
puts money in, `Debit` takes it out, and both merely accept a
`PositiveMoney`:

```ruby skip
# examples/banking/bluebook/banking.bluebook
value_object "PositiveMoney" do
  attribute :cents,    Integer
  attribute :currency, String, default: "USD"
  invariant("an amount is positive") { cents.positive? }
  ...
end
```

```ruby
funded = Banking::Account.open(customer_id: customer.id, number: { value: "ACC-2000" },
                                kind: { name: "current" }, daily_limit: { cents: 5000 })

funded.credit(amount: { cents: 0 }, narrative: { text: "bad" })   # ~> InvariantViolation: an amount is positive

funded = funded.credit(amount: { cents: 1000 }, narrative: { text: "deposit" })

funded.balance.to_h   # => { cents: 1000, currency: "USD" }

funded.debit(amount: { cents: -5 }, narrative: { text: "bad" })   # ~> InvariantViolation: an amount is positive

funded = funded.debit(amount: { cents: 400 }, narrative: { text: "withdrawal" })

funded.balance.to_h   # => { cents: 600, currency: "USD" }
```

Neither command wrote that rule, and neither command could get it
wrong — the rule lives on the value, not on its callers. Nor is `Credit`
and `Debit` the whole story: `ApplyFee`, `AccrueInterest`,
`CorrectFee`, and `CorrectInterest` all accept `PositiveMoney` too, and
none of them had to restate a thing — every one of them was written
after `Credit` and `Debit` already existed, and every one of them
inherited the rule for free.

## Closed vocabularies, and the one that will not nest

`one_of` ships a fixed vocabulary — a field that can only ever be one
of the values named, refused at the door for anything else. It has two
spellings, and using the wrong one in the wrong place produces a crash
while the bluebook is still being written, rather than a clean
declaration.

The block form lives ON the value object — `Account::AccountKind` is
one:

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
Banking::Account.open(customer_id: customer.id, number: { value: "ACC-BAD" }, kind: { name: "gold" }, daily_limit: { cents: 0 })   # ~> InvariantViolation: got "gold"
```

The inline shorthand skips the ceremony — `SafeDepositBox`'s `size`,
seen already above, synthesises a `Size` value object without you
naming it anywhere else:

```ruby
Banking::SafeDepositBox.rent(customer_id: customer.id, branch_code: { value: "uptown" }, box_number: { value: 99 }, size: { value: "huge" })   # ~> InvariantViolation: got "huge"
```

Reach for this one when the set is small, local, and not worth a name
anyone else will ever reuse.

The trap: the inline shorthand desugars by calling `one_of` on
whichever builder currently has `self` — and a nested `value_object`
block already defines its own `one_of`, for closed-set members. Writing
the shorthand inside a `value_object` block does not synthesize a
closed set — it calls the wrong `one_of`, with the wrong arity, and the
bluebook does not load:

```ruby
def banking_bad_one_of
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    code = <<~RUBY
      Hecks.bluebook("BankingBadOneOf") do
        aggregate "Thing" do
          identified_by :thing_id
          attribute :box, Box

          value_object "Box" do
            attribute :size, one_of("small", "large")
          end
        end
      end
    RUBY
    file = Tempfile.new(["banking-bad-one-of-", ".bluebook"])
    file.write(code)
    file.flush
    Kernel.eval(code, TOPLEVEL_BINDING, file.path, 1)
  end
end

banking_bad_one_of   # ~> ArgumentError: wrong number of arguments
```

## A field that grows

`list_of` declares a repeating field — not set once, but appended to by
whichever commands say so. A fresh card starts with no withdrawals at
all:

```ruby skip
# examples/banking/bluebook/banking.bluebook
attribute :withdrawals, list_of(Withdrawal)
...
value_object "WithdrawalAmount" do
  attribute :cents, Integer
  invariant("a withdrawal amount is positive") { cents.positive? }
end
```

```ruby
card = Banking::ATMCard.issue(account_id: account.id, serial: { value: "CARD-1000" },
                               daily_fee: { amount: 0.0 })

card.withdrawals   # => []
```

`WithdrawalAmount` carries its own invariant, and `list_of` does not
exempt an appended element from it. Every element built by `append:`
goes through the same construction a bare value would, invariant
included:

```ruby
card = card.withdraw(cents: { cents: 4000 }, narrative: { text: "ATM run" })

card.withdrawals.size                       # => 1
card.withdrawals.first[:cents].to_h         # => { cents: 4000 }

card.withdraw(cents: { cents: -100 }, narrative: { text: "bad" })   # ~> InvariantViolation: a withdrawal amount is positive
```

The rule you declared once on `WithdrawalAmount` holds for withdrawal
one and for withdrawal four hundred — a `list_of` field is not a place
invariants quietly stop applying.

## Pointing at another aggregate

A reference is how one aggregate names another, and getting the shape
wrong here does not fail loudly at declaration — it fails silently
later, when code reads a field expecting an id and gets something it
cannot use instead.

`reference_to Target` is the base form — it mints an attribute named
`target_id` by default, or whatever you pass as `as:`. `ExternalTransfer`
uses the base form for its account:

```ruby skip
# examples/banking/bluebook/banking.bluebook
aggregate "ExternalTransfer" do
  identified_by :end_to_end
  reference_to Account
  ...
end
```

```ruby
ext.account_id   # => "ACC-1000"
```

That is a bare id — a String — not a nested object. A reference IS an
id, so an id is the only shape it is stored as; hand it an object
instead (the shape you would reach for reflexively, wrapping "the
account" the way you would wrap any other field) and the runtime
refuses it at the door, by name, rather than let a wrapped reference
travel quietly into storage:

```ruby
Banking::ExternalTransfer.request(account_id: { value: account.id }, end_to_end: { value: "E2E-1002" }, amount: { cents: 1000 }, beneficiary: { value: "Someone" }, direction: { value: "debit" })   # ~> TypeMismatch: arrived as an object
```

`as:` renames what the base form would otherwise mint. `CardPayment`'s
`Dispute` carries a cross-reference to `Customer` named `disputed_by`,
not `customer_id`:

```ruby skip
# examples/banking/bluebook/banking.bluebook
command "Dispute" do
  reference_to CardPayment
  reference_to Customer, as: :disputed_by
  ...
end
```

```ruby
disputed = payment.capture.dispute(disputed_by: customer.id)

disputed.disputed_by   # => "CUST-1000"
```

`has_one` and its alias `belongs_to` are sugar over the same
`reference_to` — the only difference is the attribute name: no `_id`
suffix, because the field already reads as a relationship. `OnboardingCase`
is banking's only user of the sugar, and it reaches for `belongs_to`:

```ruby skip
# examples/banking/bluebook/banking.bluebook
aggregate "OnboardingCase" do
  identified_by :reference
  belongs_to Customer
  ...
end
```

```ruby
onboarding = Banking::OnboardingCase.open(customer: customer.id, reference: { value: "ONB-1000" },
                                           account_number: { value: "ACC-3000" })

onboarding.customer   # => "CUST-1000"
```

Not `customer_id` — `customer`. And it is bound by the same rule as
every other reference: an id, never an object, refused at the door the
same way `ExternalTransfer`'s was above:

```ruby
Banking::OnboardingCase.open(customer: { value: customer.id }, reference: { value: "ONB-1001" }, account_number: { value: "ACC-3001" })   # ~> TypeMismatch: arrived as an object
```

One direction only: if `Customer` were to declare `reference_to Account`
back — on top of `Account`'s own `reference_to Customer` — the bluebook
would refuse to build. Two aggregates pointing at each other is not a
modelling choice this language leaves open, since neither side would be
a boundary a caller could reason about alone. `spec/dsl_spec.rb`'s
"refuses two aggregates that reference each other" is where that
refusal is proven; not reproduced here, since demonstrating it live
would mean breaking this very domain to show it.

One case to note in particular, absent from banking entirely — no
aggregate here reaches for `has_many`, so this is a small ad hoc
domain rather than the real corpus. `has_many` reads like it should
produce a list — it is spelled with the plural of the target — but it
singularizes the target back down to the aggregate it actually names
and mints a single scalar reference under the plural attribute name. It
is sugar for exactly one relationship, not a one-to-many: a real list
of references has no precedent in this language, because `list_of` is
checked everywhere as a list of value objects, not references:

```ruby
def banking_has_many_demo
  Hecksagain.with_registry(Hecksagain::Runtime::Registry.new) do
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    code = <<~RUBY
      Hecks.bluebook("HasManyDemo") do
        aggregate "Slip" do
          identified_by :code
          value_object("SlipTag") { attribute :value, String }
          attribute :code, SlipTag
          command("Open") { attribute :code, SlipTag; emits "SlipOpened" }
        end

        aggregate "Vault" do
          identified_by :tag
          value_object("VaultTag") { attribute :value, String }
          attribute :tag, VaultTag
          has_many Slips
          command("Install") { attribute :tag, VaultTag; emits "VaultInstalled" }
        end
      end
    RUBY
    file = Tempfile.new(["has-many-demo-", ".bluebook"])
    file.write(code)
    file.flush
    Kernel.eval(code, TOPLEVEL_BINDING, file.path, 1)
    Hecks.hecksagon("HasManyDemo") do
      HasManyDemo::Slip.persisted_by("Memory")
      HasManyDemo::Vault.persisted_by("Memory")
    end

    registry = Hecksagain.current_registry
    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    HasManyDemo::Vault.install(tag: { value: "v1" })
  end
end

vault = banking_has_many_demo

vault.slips   # => nil
```

`has_many` looks like the collection form and is not one — the field it
produces is `nil` until set, the same as any other unset reference,
never `[]`. If what you actually need is a one-to-many, `has_many` will
not give it to you — that is a real relationship this language does
not have a direct spelling for yet, and reaching for the sugar here
just hides the gap behind a name that sounds right.

## A value object holding a value object

Every value object in banking is exactly one field deep — nothing here
nests one value object inside another. For that shape, this one example
draws from pizzas instead, since it is real and banking's own value
objects simply never need it:

```ruby skip
# examples/pizzas/bluebook/pizzas.bluebook
value_object "Pizza" do
  attribute :price_cents, Price
  attribute :size,        Size
end
```

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))

Hecks.hecksagon("Pizzas") { Pizzas::Order.persisted_by("Memory") }
```

```ruby
order = Pizzas::Order.create_pizza(name: { value: "Margherita" },
                                    pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })

order.pizza.to_h   # => { price_cents: { cents: 1200 }, size: { value: "large" } }
```

Nesting is ordinary: an attribute can be typed as another value object
just as easily as a scalar, and the nested shape travels with it, all
the way into storage and back out — `price_cents` is a `Price`, not a
bare integer, and `size` is a `Size`, not a bare string, and both
arrive and leave as the objects they were declared to be.

Reaching a nested scalar from a query — `pizza.price_cents.cents`, in
the language's own corpus — is its own small topic, with its own rules
about where a dotted path is allowed to land; see
[queries and read models](queries-and-read-models.md) for the full
treatment.

## Where to go next

- **[Getting started](getting-started.md)** — the whole shape of the language in one sitting,
  if you have not read it yet.
- **[Commands](commands.md)** — everything a command may do and refuse, including
  postconditions.
- **[Wiring](wiring.md)** — the hecksagon and world in full: adapters, ports,
  per-deployment values.
