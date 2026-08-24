# Queries and read models

An aggregate refuses invalid input and emits events for what changed.
Reading that data back — accounts below a floor, every customer who
isn't in good standing, a dashboard that gathers one account's status
and the charges disputed against it in one read — is what `query` and
`read_model` are for. This guide covers what the vocabulary can carry,
what the build refuses before a read model reaches an adapter that
would otherwise silently disagree with itself, and the two-reading
rule `contains` follows depending on the field it's asked about.

Both constructs are built on the same option vocabulary
(`QuerySpecification::Common::DSL`) — `where`, `order_by`, `limit`, and
`offset` are what you'll reach for first, and this guide runs every
comparator `where` accepts against a real domain, plus
`authorize`/`tenant:`. `read_model` adds `reference_to`/`include` on
top, for a read model that gathers more than one aggregate at once.

## The domain

The example domain is banking — customers, the accounts they hold, and
the transfers, cards, and charges that move money through them. This
guide runs against the real `examples/banking/bluebook/`,
loaded directly rather than invented for this page — the same file
`docs/implemented/guides/verification.md` and every adapter spec in this repo
exercise, kept honest by the same build the moment it changes:

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::ATMCard.persisted_by("Memory")
  Banking::Transfer.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
  Banking::ExternalTransfer.persisted_by("Memory")
  Banking::ScheduledPayment.persisted_by("Memory")
  Banking::SafeDepositBox.persisted_by("Memory")
  Banking::OnboardingCase.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

Everything below quotes the bluebook's own declarations verbatim
(shown, never re-run — the file above already declared them for real)
alongside real dispatches against the boot above.

## Asking a declared query

Seed two customers and four accounts, then look at the everyday roll:

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                  name: { given: "Ada", family: "Voss" }, email: { address: "ada@example.com" })
runtime.dispatch("Banking::Customer.Register", reference: { value: "c2" },
                  name: { given: "Bo", family: "Reyes" }, email: { address: "bo@example.com" })

runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: { value: "a" }, amount: { cents: 300, currency: "USD" },
                  narrative: { text: "Opening" })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "b" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: { value: "b" }, amount: { cents: 500, currency: "USD" },
                  narrative: { text: "Opening" })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "c" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Account.Credit", number: { value: "c" }, amount: { cents: 1000, currency: "USD" },
                  narrative: { text: "Opening" })
runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "d" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })

runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "c" })
runtime.dispatch("Banking::Account.CloseAccount", number: { value: "d" })
```

Four accounts: `a` at 300 cents, `b` at 500, `c` at 1000 (later frozen),
`d` at 0 (later closed) — the corners an ordered-comparator family
needs: strictly below a floor, exactly at one, strictly above, and the
zero balance `CloseAccount`'s own `given` requires.

`eq`, spelled the short way — a plain value is always `eq` — is what
`Account`'s own `Open` query declares:

```ruby skip
# Account, in examples/banking/bluebook/
query "Open" do
  description "Accounts that can transact today."
  where(status: "open")
  order_by :number
end
```

A declared query is asked the way a command is dispatched — a fully
qualified verb, through the same `runtime` — and it answers an Array of
Hashes, each one the record's id merged with its state:

```ruby
runtime.query("Banking::Account.Open").map { |row| row[:number].value }
# => ["a", "b"]
```

`c` and `d` are missing — frozen and closed are not `"open"`. Notice
`row[:number]` came back a `Value`, the same object a command argument
would build — read it with `.value`, not `.inspect`, the same rule
`AUTHORING.md` holds every claim on this page to. A row is not a plain
hash the whole way down; only `read_model` flattens that far, and the
difference matters later in this guide.

One more account, opened for `c2` WHILE `c2` is still active —
`Account.Open` carries its own `given("customer is active")`, so this
has to happen before what comes next, not after:

```ruby
runtime.dispatch("Banking::Account.Open", customer: "c2", number: { value: "e" },
                  kind: { name: "current" }, daily_limit: { cents: 100_000 })
runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c2" },
                  standing: { value: "chargeback investigation" })
```

`ne` is the opposite direction — everyone the everyday roll leaves out:

```ruby skip
# Customer, in examples/banking/bluebook/
query "NotGoodStanding" do
  description "Everyone who is not in the everyday roll — suspended, under review, or anything else that is not simply \"good\"."
  where(standing: { ne: "good" })
  order_by :reference
end
```

```ruby
runtime.query("Banking::Customer.NotGoodStanding").map { |row| row[:reference].value }
# => ["c2"]
```

## Hopping through a reference

Every field so far has been the querying aggregate's own. `/` CROSSES
INTO ANOTHER RECORD through a `reference_to` attribute, where `.`
WALKS FIELDS INSIDE THIS ONE (ADR 0025, "References") — the operator
alone says which kind of path it is. `Account` already
`reference_to Customer`, so a live account can be filtered by a fact
about its OWN customer, not anything `Account` declares itself:

```ruby skip
# Account, in examples/banking/bluebook/
query "OpenForSuspendedCustomers" do
  description "Open accounts whose customer has since been suspended — live money movement nobody should be approving right now."
  where(status: "open")
  where(:"customer/status" => "suspended")
  order_by :number
end
```

`c2` opened `e` back in the first example, while still active, and was
suspended right after — the account itself was never touched, so it's
exactly the shape this query exists to catch: a live account behind a
customer nobody should be letting transact, reachable only because
suspension happens to an existing customer, not retroactively to the
accounts they already hold.

```ruby
runtime.query("Banking::Account.OpenForSuspendedCustomers").map { |row| row[:number].value }
# => ["e"]
```

`a`, `b`, `c`, and `d` all belong to `c1`, who is fine — the hop is
what keeps them out, not `status`, since all four (well, the two still
open) would otherwise pass the local half of this ask too. The hop
segment's own name — `customer` — is the exact word `account.customer`
would hydrate to as a Ruby accessor (`Facade::Handle`'s own reference
accessors): one rule names both.

The hop is EXISTENTIAL — worth stating precisely, since it's the one
place a reader's intuition could go the other way. "Points at a
customer who is NOT active" has to mean exactly that, never "or has no
customer to point at, either kind of missing counts." Banking has no
account this page can show the second half with — `Account`'s own
`reference_to Customer` is required, so there's no way to construct an
account with no customer at all in this real domain — but the rule
still holds, and `spec/runtime/query_hop_spec.rb` proves it directly:
a nil or dangling reference never satisfies a hop clause, whatever the
comparator, positive or negated.

A hop is `where`-only. `order_by` still means "by what this ask's own
answering rows hold" — a hop answers with a candidate set, not a sort
key — so ordering by one is refused at the seal, not silently ignored
or silently expensive:

```ruby
seal_hop = lambda do
  Hecks.with_registry(Hecks::Runtime::Registry.new) do
    Hecks.bluebook("QueriesHopOrder") do
      aggregate "Client" do
        value_object("ClientName") { attribute :value, String }
        attribute :name, ClientName
        lifecycle(:status, default: "active") { transition "Churn" => "churned", from: "active" }
      end
      aggregate "Proposal" do
        reference_to Client
        value_object("ProposalNumber") { attribute :value, String }
        attribute :number, ProposalNumber
        query("Bad") { order_by :"client/status" }
      end
    end
  end
end
seal_hop.call   # ~> Malformed: a hop answers with a candidate set, not a sort key
```

## The rest of `where`'s comparators

`lt`, through a query argument resolved with `:symbol` — the caller
supplies the floor, never a value baked into the declaration — and, on
the same query, every metadata option this guide covers stacked in one
place:

```ruby skip
# Account, in examples/banking/bluebook/
query "Overdrawn" do
  description "Accounts below a floor the caller supplies — the morning risk report."
  attribute :floor, Money
  where(balance: { lt: :floor })
  order_by :balance
  limit 100
end
```

```ruby
runtime.query("Banking::Account.Overdrawn", floor: { cents: 500 }).map { |row| [row[:number].value, row[:balance].cents] }
# => [["d", 0], ["a", 300]]
```

`:floor` is not a value baked into the declaration — it's an argument
named on the query (`attribute :floor, Money`) and resolved from
whatever the caller passes at ask-time. `limit` and `order_by` both sit
on this one declaration: `order_by :balance` runs ascending first, and
`limit 100` never trims this seed (only two accounts qualify) — more on
the vocabulary's one genuinely enforced option once `SafeDepositBox
.Rented` introduces `authorize`/`tenant:`, below.

`gte`, on the same field, the other direction:

```ruby skip
# Account, in examples/banking/bluebook/
query "HighBalance" do
  description "Accounts holding at least a floor the caller supplies — the private-banking referral list."
  attribute :floor, Money
  where(balance: { gte: :floor })
  order_by :balance, :desc
end
```

```ruby
runtime.query("Banking::Account.HighBalance", floor: { cents: 500 }).map { |row| [row[:number].value, row[:balance].cents] }
# => [["c", 1000], ["b", 500]]
```

`b`, sitting exactly at 500, is included — `gte` is inclusive of the
boundary, `gt` is not:

```ruby skip
# Account, in examples/banking/bluebook/
query "StrictlyAbove" do
  description "Accounts holding MORE than a floor the caller supplies — the referral list without the accounts sitting exactly on the line."
  attribute :floor, Money
  where(balance: { gt: :floor })
  order_by :balance, :desc
end
```

```ruby
runtime.query("Banking::Account.StrictlyAbove", floor: { cents: 500 }).map { |row| [row[:number].value, row[:balance].cents] }
# => [["c", 1000]]
```

`b` drops out — `gt` is the boundary excluded. `lte` is `gte`'s own
mirror, at the bottom end:

```ruby skip
# Account, in examples/banking/bluebook/
query "AtMost" do
  description "Accounts holding no more than a cap the caller supplies — the small-balance closure candidates."
  attribute :cap, Money
  where(balance: { lte: :cap })
  order_by :balance
end
```

```ruby
runtime.query("Banking::Account.AtMost", cap: { cents: 500 }).map { |row| [row[:number].value, row[:balance].cents] }
# => [["d", 0], ["a", 300], ["b", 500]]
```

`in`, with the comma convention:

```ruby skip
# Account, in examples/banking/bluebook/
query "Reachable" do
  description "Accounts that still exist as far as a caller is concerned — anything short of closed."
  where(status: { in: "open,frozen" })
  order_by :number
end
```

```ruby
runtime.query("Banking::Account.Reachable").map { |row| row[:number].value }
# => ["a", "b", "c"]
```

`d` is closed, so it's the one account this query is built to leave
out — `c`, frozen, still counts as reachable.

`contains`, over a `list_of` field — real element membership, covered
in full at the end of this guide:

```ruby skip
# CardPayment, in examples/banking/bluebook/
query "Flagged" do
  description "Charges carrying a risk tag, for the fraud queue."
  where(tags: { contains: "high_risk" })
end
```

```ruby
runtime.dispatch("Banking::CardPayment.Authorize", account: "a", authorisation: { value: "auth-1" },
                  amount: { cents: 4200 }, merchant: { value: "Risky Co" }, tags: [{ value: "high_risk" }])
runtime.dispatch("Banking::CardPayment.Authorize", account: "b", authorisation: { value: "auth-2" },
                  amount: { cents: 1500 }, merchant: { value: "Ordinary Co" })

runtime.query("Banking::CardPayment.Flagged").map { |row| row[:authorisation].value }
# => ["auth-1"]
```

`auth-2` carries no tags at all — `contains` over an empty list matches
nothing, the same as over a list that holds the wrong value.

## `authorize`/`tenant:` — the one option that is actually enforced

`SafeDepositBox.Rented` is the query in this domain that declares a
tenant boundary:

```ruby skip
# SafeDepositBox, in examples/banking/bluebook/
query "Rented" do
  description "Boxes currently assigned to a customer, for the annual access audit."
  where(status: "rented")
  order_by :branch_code
  # A VAULT RECORD IS NOT A CASUAL READ. Named against the branch a caller
  # is standing in.
  authorize :vault_access, tenant: :branch_code
end
```

`authorize :vault_access, tenant: :branch_code` declares two things, and
only one of them this runtime can actually check. `:vault_access` is a
policy name — recorded on the query, round-tripped through the IR, and
checked against nothing, because verifying that THIS caller actually
holds `:vault_access` needs real caller-identity infrastructure this
runtime does not have. That stays a named, open gap, not something
quietly pretended to be covered. `tenant: :branch_code` is different:
it makes `branch_code:` a mandatory argument, enforced as a synthetic
`eq` where-clause on every engine that already reads `.wheres` — no
per-adapter code, no way for one engine to forget it.

```ruby
rented = runtime.registry.bluebooks.values.first.aggregate("SafeDepositBox").queries.find { |q| q.hecks_name == "Rented" }

rented.authorization.to_h   # => { policy: "vault_access", tenant: "branch_code" }
```

Rent a box, then ask without naming a branch:

```ruby
runtime.dispatch("Banking::SafeDepositBox.Rent", customer: "c1", branch_code: { value: "DOWNTOWN" },
                  box_number: { value: 12 }, size: { value: "medium" })

runtime.query("Banking::SafeDepositBox.Rented")   # ~> Unauthorized: declares authorize with tenant: branch_code — pass branch_code: to name which branch_code this ask is scoped to
```

Named, it answers:

```ruby
runtime.query("Banking::SafeDepositBox.Rented", branch_code: "DOWNTOWN").map { |row| row[:id] }
# => ["DOWNTOWN:12"]
```

`:vault_access` above is the other half of that same shape — declared,
carried in the IR, and checked by nothing, a signal to whoever reviews
the bluebook next about what a caller is meant to hold, not a promise
this runtime keeps today. `tenant:` is the one exception in this whole
family: it is the only option in `QuerySpecification::Common::DSL`
enforced at dispatch time rather than merely carried.

## The seal — what you don't have to catch by hand

Four mistakes never reach an adapter. They are caught the moment the
bluebook builds, not the first time a caller runs the query and gets a
suspiciously empty result. That is the value of the seal: a report that
would otherwise have been silently wrong since it shipped instead causes
the domain not to build. Everything past these four still has to be
verified by hand.

Reaching the seal directly needs the same ambient registry a `.bluebook`
file gets from the boot loader — `Hecks.bluebook` refuses to run
outside one — so each attempt below opens its own with
`Hecks.with_registry` by hand, wrapped in a `lambda` so the build
only runs, and only refuses, at the point this guide claims it does.
Most of these throwaway aggregates skip `identified_by`: the seal
each one trips runs before identity would ever matter, so there's no
reason to declare one just to reach it. `seal_c` (below) is the one
exception — it no longer trips a seal at all, and building a bluebook
all the way through to a readable IR needs a real identity declared.

A `where` over a field the aggregate never declared — the report would
otherwise match nothing and refuse nothing, forever, on every adapter:

```ruby
seal_a = lambda do
  Hecks.with_registry(Hecks::Runtime::Registry.new) do
    Hecks.bluebook("QueriesSealA") do
      aggregate "Ledger" do
        value_object("EntryLabel") { attribute :value, String }
        attribute :label, EntryLabel
        query("BelowFloor") { where(balance: { lt: 5 }) }
      end
    end
  end
end
seal_a.call   # ~> Malformed: which Ledger never declares
```

An ordered comparator (`lt`/`lte`/`gt`/`gte`) over a field that holds no
number — the reference interpreter would quietly match no rows while
SQL compared the text lexicographically, two answers for one query:

```ruby
seal_b = lambda do
  Hecks.with_registry(Hecks::Runtime::Registry.new) do
    Hecks.bluebook("QueriesSealB") do
      aggregate "Ledger" do
        value_object("EntryLabel") { attribute :value, String }
        attribute :label, EntryLabel
        query("ByLabel") { where(label: { gt: "A" }) }
      end
    end
  end
end
seal_b.call   # ~> Malformed: holds no number
```

A `:symbol` value used to name no declared query argument, and refuse
for it — resolving to `nil` at dispatch and matching nothing, the same
silent failure as the undeclared field above. It is not a seal any
more: a bare symbol in a `where` clause now MINTS the query argument it
names, typed from whichever field it is compared against — `:floor`
becomes a real, `Money`-typed `BelowFloor` attribute here, the same
inference `dsl_spec.rb`'s own "infers a symbolic query argument from
the compared field" pins directly:

```ruby
seal_c = lambda do
  Hecks.with_registry(Hecks::Runtime::Registry.new) do
    Hecks.bluebook("QueriesSealC") do
      aggregate "Ledger" do
        identified_by :balance
        value_object("Money") { attribute :cents, Integer }
        attribute :balance, Money
        query("BelowFloor") { where(balance: { lt: :floor }) }
      end
    end
  end
end
QueriesSealC = seal_c.call
QueriesSealC.aggregate("Ledger").query("BelowFloor").attribute(:floor).type.to_s   # => "Money"
```

A dotted path that lands on a value object instead of a scalar — SQL
would hand back a JSON object where the reference interpreter unwraps a
hash, and the two would disagree about what the row even holds:

```ruby
seal_d = lambda do
  Hecks.with_registry(Hecks::Runtime::Registry.new) do
    Hecks.bluebook("QueriesSealD") do
      aggregate "Ledger" do
        value_object("Money") { attribute :cents, Integer }
        value_object("Balance") { attribute :money, Money }
        attribute :balance, Balance
        query("ByBalance") { where(:"balance.money" => { lt: 5 }) }
      end
    end
  end
end
seal_d.call   # ~> Malformed: lands on a value object
```

`examples/pizzas/bluebook/pizzas.bluebook`'s `Order.CostingLessThan`/
`Expensive` queries show the path that IS allowed:
`:"pizza.price_cents.cents"` reaches through two levels and lands on a
number — nested value objects were, for a while, simply unreachable by
a query at all, until one field-path walk
(`QuerySpecification::FieldPath`) replaced three different readings of
what a dotted path means.

`Account.Overdrawn`/`Account.HighBalance` above show the other legal
shape worth naming: a bare, one-level value object with a single
numeric member — `balance` is a `Money`, not an Integer, and `lt`/`gte`
still work on it directly. The convention stops at one level — a dotted
path has to land ON the number itself, it doesn't get to reach through
a named path AND unwrap a bare value object at the end.

## `read_model` — reading across aggregates

`query` never crosses an aggregate boundary. `ComplianceDashboard` does,
on purpose — a SECOND root, deliberately not the same one
`CustomerPortfolio` gathers around:

```ruby skip
# Banking, in examples/banking/bluebook/
read_model "ComplianceDashboard" do
  description "One account, its own status, and any card charges disputed against it — the working set for a compliance review."
  reference_to Account
  include Account
  include CardPayment

  # THE FILTERED, ORDERED, CAPPED VIEW — the one shape seal_query_options
  # allows on a read model with more than one included aggregate: it names
  # exactly one many-side collection (CardPayment; Account is the
  # reference itself) and confines where/order_by/limit to it. A reviewer
  # does not want the account's whole card history, just the disputes
  # that matter — the five largest, since that is where a false dispute
  # costs the bank the most first.
  where(status: "disputed")
  order_by :amount, :desc
  limit 5
end
```

`reference_to Account` names the root, `include Account` and
`include CardPayment` gather around it, and cardinality is inferred
rather than declared — the reference target is the one record,
everything else comes back a collection (`many: target !=
reference_target`). You do not say `include CardPayment, many: true`
anywhere; naming a second aggregate is enough. `where`/`order_by`/
`limit` apply to exactly one collection, and this read model's own
comment names why that is unambiguous here: `Account` is the reference
itself (a single row, nothing to filter), so `CardPayment` is the only
many-side head there is to mean — a read model with two INCLUDED
many-side aggregates and a `where` would instead trip
`seal_query_options`, the same build-time refusal family as the four
above, for the identical reason: an option with no single collection to
apply to is ambiguous, not merely unwritten.

Six disputed charges against account `a`, to see the cap actually cut
something:

```ruby
[["auth-10", 9000], ["auth-11", 7000], ["auth-12", 5000],
 ["auth-13", 3000], ["auth-14", 2000], ["auth-15", 1000]].each do |auth, cents|
  runtime.dispatch("Banking::CardPayment.Authorize", account: "a", authorisation: { value: auth },
                    amount: { cents: cents }, merchant: { value: "Merchant #{auth}" })
  runtime.dispatch("Banking::CardPayment.Capture", authorisation: { value: auth })
  runtime.dispatch("Banking::CardPayment.Dispute", authorisation: { value: auth }, disputed_by: "c1")
end
```

A read model is asked differently from an aggregate query — bare domain
name, dot, the model's own name, no aggregate in between — because no
single aggregate owns it:

```ruby
dashboard = runtime.query("Banking.compliance_dashboard", account: "a")

dashboard.size                                                      # => 1
dashboard.first[:account][:number]                                  # => { value: "a" }
dashboard.first[:card_payments].map { |cp| [cp[:authorisation][:value], cp[:amount][:cents]] }
# => [["auth-10", 9000], ["auth-11", 7000], ["auth-12", 5000], ["auth-13", 3000], ["auth-14", 2000]]
```

`auth-15`, the smallest of the six disputes at 1000 cents, is the one
`limit 5` cut — `order_by :amount, :desc` ran first, so the cap kept the
five LARGEST rather than an arbitrary five. Declare them in the order
you mean, because the adapter doesn't guess which one you wanted kept.

That `[:value]` is not a typo for `.value` — a read model row is fully
materialized, every nested value object walked down to a plain Hash,
where an aggregate-query row above kept `Value` objects you read with a
method. Know which one you're holding before you write the line that
reads it; the two do not respond to the same calls.

`CustomerPortfolio` is the read model with nothing to filter — no
`where`, no `order_by`, no `limit`, gathering a customer and every
aggregate that references one:

```ruby skip
# Banking, in examples/banking/bluebook/
read_model "CustomerPortfolio" do
  description "A customer's cross-account position, rebuilt from aggregate heads."
  reference_to Customer
  include Customer
  include Account
  include ATMCard
  include Transfer
  include CardPayment
  include ExternalTransfer
  include ScheduledPayment
end
```

```ruby
portfolio = runtime.query("Banking.customer_portfolio", customer: "c1")

portfolio.size                                          # => 1
portfolio.first.keys
# => [:customer, :accounts, :atm_cards, :transfers, :card_payments, :external_transfers, :scheduled_payments]
portfolio.first[:accounts].map { |row| row[:number][:value] }
# => ["a", "b", "c", "d"]
```

`d`, closed, still shows up — `CustomerPortfolio` has no `where` to
leave it out, unlike `ComplianceDashboard`'s deliberately narrowed
`card_payments`. Same shape (one root, several `include`s), opposite
choice about how much of it to filter — the contrast is the point:
`where`/`order_by`/`limit` are there when a report needs a working set,
and absent entirely when a report is meant to gather everything.

## The gate that makes any of this trustworthy

None of the above means much if Memory answers one way and Sqlite
answers another the day you switch adapters. `spec/adapters/
query_agreement_spec.rb` exists because none of the ordinary adapter
specs ever checked that — each proves an adapter self-consistent, asking
it a question and checking its own answer looks sane, which cannot see
two adapters quietly disagreeing. That gate runs the same declared query
against Memory, Sqlite, and Postgres over the same seeded records, and
asserts every engine against one independent, hand-computed expected id
list — not merely that the adapters agree with each other, since three
engines sharing the same bug would still "agree" under that weaker
check. When you ship a query that must mean the same thing on whichever
adapter a deployment binds, that file is where the guarantee actually
lives, not in this guide's prose.

## `contains`: two readings, chosen by the field's own shape

`contains` means one of two things, decided by what the field holds —
never guessed, and identical on every engine (Memory, Sqlite, Postgres,
the reference interpreter). On a `list_of` field (`CardPayment.tags`
above) it is real ELEMENT membership: `contains: "high_risk"` asks
whether any element's own scalar equals `"high_risk"`, exactly. On any
other field it is a plain SUBSTRING search over that field's text —
including a comma the field's own content happens to carry, which is
not treated as a separator the way `in`'s comma-separated argument
convention is. `spec/adapters/query_agreement_spec.rb`'s "carries a
comma" case is the cross-engine proof; that is where the guarantee
actually lives, not in this guide's prose.
