# ReadModel

<!-- generated:begin id=page -->
Words available inside `read_model do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against `examples/banking`'s five read models, which
between them carry every gathering and reducing shape the word has —
a rooted portfolio, a filtered and capped dashboard, two reductions,
and a rootless `group_by`. `offset`, `authorize` and `nulls` are
declared by no read model in the corpus, so they get one of their own:

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))

Hecks.hecksagon("Banking") do
  uses_framework "Governance"
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
  Banking::ATMCard.persisted_by("Memory")
  Banking::Transfer.persisted_by("Memory")
  Banking::CardPayment.persisted_by("Memory")
  Banking::ExternalTransfer.persisted_by("Memory")
  Banking::ScheduledPayment.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
```

```ruby bluebook
Hecks.bluebook "ReadModelReference" do
  vision "The read-model words the corpus does not yet declare."

  aggregate "Depot" do
    attribute :code, Code

    identified_by :code
    value_object("Code") { attribute :value, String }

    command "OpenDepot" do
      sets :code
      emits "DepotOpened"
    end
  end

  aggregate "Parcel" do
    attribute :label, Label

    identified_by :label
    reference_to Depot
    attribute :region, Region
    attribute :weight, Weight, optional: true

    value_object("Label")  { attribute :value, String }
    value_object("Region") { attribute :value, String }
    value_object("Weight") { attribute :value, Integer }

    command "Accept" do
      attribute :depot,    Depot
      sets :label
      sets :region
      sets :weight
      emits "ParcelAccepted"
    end
  end

  read_model "DepotManifest" do
    description "One depot's parcels, heaviest first, skipping the heaviest of all."
    reference_to Depot
    include Depot
    include Parcel
    order_by :weight, :desc
    nulls :last
    limit 2
    offset 1
    inspect_query :sql
    authorize :depot_access, tenant: :region
  end
end
```

```ruby boot
Hecks.hecksagon("ReadModelReference") do
  ReadModelReference::Depot.persisted_by("Memory")
  ReadModelReference::Parcel.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "rm-1" },
                 name: { given: "Sofia", family: "Kovalevskaya" },
                 email: { address: "sofia@example.com" })
account = Banking::Account.open!(customer: "rm-1", number: { value: "rm-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
Banking::Account.open!(customer: "rm-1", number: { value: "rm-a2" },
                      kind: { name: "savings" }, daily_limit: { cents: 10_000 })

payment = Banking::CardPayment.authorize!(account: "rm-a1", authorisation: { value: "auth-1" },
                                         amount: { cents: 4_200 }, merchant: { value: "Corner Shop" })
payment.capture!
payment.dispute!(disputed_by: "rm-1")

second = Banking::CardPayment.authorize!(account: "rm-a1", authorisation: { value: "auth-2" },
                                        amount: { cents: 900 }, merchant: { value: "Kiosk" })
second.capture!
second.dispute!(disputed_by: "rm-1")

# SEVEN, on the OTHER account (S13, ADR 0025 — ComplianceDashboard
# gained a real `offset 5` alongside its own `limit 5`) — enough for
# the `where`/`order_by`/`offset` sections below to demonstrate a
# genuine second page, without disturbing "rm-a1"'s own two disputes
# that `count`/`median` already rely on above.
[4_200, 900, 500, 400, 300, 200, 100].each_with_index do |cents, index|
  card = Banking::CardPayment.authorize!(account: "rm-a2", authorisation: { value: "auth-page-#{index}" },
                                        amount: { cents: cents }, merchant: { value: "Shop#{index}" })
  card.capture!
  card.dispute!(disputed_by: "rm-1")
end

runtime.dispatch("ReadModelReference::Depot.OpenDepot", code: { value: "dp-1" })
runtime.dispatch("ReadModelReference::Parcel.Accept", label: { value: "p-1" }, depot: "dp-1", region: { value: "north" }, weight: { value: 30 })
runtime.dispatch("ReadModelReference::Parcel.Accept", label: { value: "p-2" }, depot: "dp-1", region: { value: "north" }, weight: { value: 20 })
runtime.dispatch("ReadModelReference::Parcel.Accept", label: { value: "p-3" }, depot: "dp-1", region: { value: "north" }, weight: { value: 10 })
runtime.dispatch("ReadModelReference::Parcel.Accept", label: { value: "p-4" }, depot: "dp-1", region: { value: "north" })
```

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the read model — no rules attached, read by
nothing but a human.

```ruby
runtime.registry.bluebook("Banking").read_model("CustomerPortfolio").description  # => "A customer's cross-account position, rebuilt from aggregate heads."
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to reference_target, as:` — fills `reference_target`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | reference_target |
| `as:` | symbol | false | reference_name |
<!-- generated:end -->

Names the aggregate this read model is anchored to — the one record
every row centers on, everything else in `include` comes back a
collection around it (see `include`). A read model declares only one;
a second `reference_to` is refused when the bluebook builds.

Optional: a read model with no `reference_to` at all is ROOTLESS — no
id argument at dispatch, every `include`d head reads its own aggregate
whole rather than being matched against a root. At least one `include`
is still required (a read model naming neither refuses). See
`group_by`, which this exists for.

`CustomerPortfolio` is rooted on a `Customer`, so the ask names one and
the answer is that customer's own position:

```ruby
portfolio = runtime.query("Banking.CustomerPortfolio", customer: "rm-1").first
portfolio[:customer][:reference][:value]  # => "rm-1"
```

## include

<!-- generated:begin word=include -->
`include aggregate, as:` — fills `aggregate_heads`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | aggregate |
| `as:` | symbol | false | as |
<!-- generated:end -->

Gathers another aggregate into the read model alongside the reference.
Cardinality is inferred, not declared: the reference target comes back
as the one record, any other included aggregate comes back as a list
— there's no `many:` to spell out yourself. Declaring the same `as:`
name twice is refused. See the queries-and-read-models guide for the
full `ComplianceDashboard` example.

Each included aggregate becomes its own key on the row, pluralised for
the many side and singular for the root:

```ruby
portfolio.keys.first(3)  # => [:customer, :accounts, :atm_cards]
portfolio[:accounts].map { |row| row[:number][:value] }  # => ["rm-a1", "rm-a2"]
```

The root is one record, not a list — which is the difference `include`
is drawing:

```ruby
portfolio[:customer][:status]  # => "active"
```

## group_by

<!-- generated:begin word=group_by -->
`group_by group_by` — fills `group_by`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | group_by |
<!-- generated:end -->

Nests the eligible collection's own rows into a Hash keyed by one or
more of its own field values, in the order named — `group_by :agg,
:state` on a `StateStyle` head comes back `{"Board" => {"open" =>
{...}, "archived" => {...}}}`, not a flat array. Held to the same
"exactly one many-side head" rule `where`/`order_by`/etc already are
(`ReadModelBuilder#seal_group_by`) — grouping is a question about ONE
collection's own rows. Requesting it also unwraps every single-
attribute value object on that head's own rows to its bare scalar
(`Runtime::Value.materialize_unwrapped`, not the plain `materialize`
every other head still gets) — grouping needs a real scalar to key by
regardless, so a read model already asking for that gets the unwrap
for free. Refuses at DISPATCH time (not build time — the aggregate
this read model targets isn't known until then) if a named field isn't
one the eligible collection's own aggregate actually declares.

This is also what makes `reference_to` optional: a read model with no
root — every `include`d head reading its own aggregate whole, no id
argument at dispatch — is `group_by`'s own real use (nesting a whole
table by its own field values has no root record to hang off).

`AccountsByKind` groups by two fields, and the result nests one level
per field rather than flattening:

```ruby
by_kind = runtime.query("Banking.AccountsByKind").first[:accounts]
by_kind.keys  # => ["current", "savings"]
by_kind["savings"].keys  # => ["rm-a2"]
```

Grouping also unwraps single-attribute value objects to their bare
scalar — `daily_limit` reads as a number here, where the same field on
an ungrouped row is still a `{ cents: }`:

```ruby
by_kind["savings"]["rm-a2"][:daily_limit]  # => 10000
```

## count

<!-- generated:begin word=count -->
`count` — fills `count`
<!-- generated:end -->

Reduces the eligible collection's own (already `where`-filtered)
rows to a single Integer — how many match, not which ones. A bare
word, no argument: its presence in the read model IS the value. Held
to the same "exactly one many-side head" rule `group_by`/`where`/etc
already are (`ReadModelBuilder#seal_aggregation`), and refused
together with `group_by` or with `median` — a read model reports one
shape. See `Banking::DisputedPaymentCount` for the real corpus
example.

Two disputed charges on this account, and the answer is the number
rather than the rows:

```ruby
counted = runtime.query("Banking.DisputedPaymentCount", account: "rm-a1").first
counted[:card_payments]  # => 2
```

The reduction rides the report's own `where` — only disputed charges
were counted, and nothing at the call site said so.

## median

<!-- generated:begin word=median -->
`median median_field` — fills `median_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | median_field |
<!-- generated:end -->

Reduces the eligible collection's own (already `where`-filtered) rows
to the median of one numeric field — a bare number, or a value object
carrying one (the same "numeric" `where`/`order_by` already lean on).
An ODD number of rows answers the one true middle value ; an EVEN
number answers the AVERAGE of the two middle values, sorted (not the
lower or the upper of the two). An empty collection answers `nil`, not
zero — "nothing to average" is a different fact from "the values
averaged to zero." Refused at DISPATCH time if the named field doesn't
exist, or exists but isn't numeric — same timing as `group_by`'s own
field check, for the same reason (the aggregate this read model
targets isn't known until then). Same `seal_aggregation` rule `count`
carries: exactly one many-side head, never combined with `group_by` or
with `count`. See `Banking::DisputedPaymentMedian` for the real corpus
example.

The same two charges — 4,200 and 900 — reduced to the middle of them
rather than counted:

```ruby
runtime.query("Banking.DisputedPaymentMedian", account: "rm-a1").first[:card_payments]  # => 2550.0
```

An even number of values has no single middle, so the two nearest are
averaged — which is why this answers a Float where `count` answers an
Integer.

## where

<!-- generated:begin word=where -->
`where pairs` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
<!-- generated:end -->

Same eight comparators as a query's `where` (`eq`, `ne`, `gt`, `gte`,
`lt`, `lte`, `in`, `contains`), including the same real-membership-vs-
substring split on `contains` (see query.md's `where`). Applied for
real (`ReadModelInterpreter#project` and `SqliteProjection#query_read_model`
both run `Ports::Query::InMemory.execute` against it) — but only
against ONE collection: `ReadModelBuilder#seal_query_options` refuses
at build unless the read model includes exactly one many-side
aggregate, since `where`/`order_by`/`limit`/`offset`/`authorize`'s
tenant all have to mean the same collection or naming which one is
ambiguous. The "one" side (the reference target itself) is never
filtered — a single row has nothing to filter.

`ComplianceDashboard` declares `where(status: "disputed")`, and it
confines itself to the one many-side head — the account it is rooted on
comes back whatever its own status:

```ruby
dashboard = runtime.query("Banking.ComplianceDashboard", account: "rm-a2").first
dashboard[:card_payments].map { |row| row[:status] }  # => ["disputed", "disputed"]
dashboard[:account][:status]  # => "open"
```

## order_by

<!-- generated:begin word=order_by -->
`order_by field, direction` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | field |
| positional 2 | symbol | false | direction |
<!-- generated:end -->

Same shape as a query's `order_by`, applied to the same one many-side
collection `where` is (see `where`). Without it, that collection still
comes back in a stable order (record id) — not because ordering is
optional, but because the underlying fetch has to answer in SOME
order, and id is the fallback every engine agrees on.

`ComplianceDashboard` orders its disputes by amount, largest first —
which is what makes `dashboard` (above) the SECOND page rather than an
arbitrary two: the five biggest (4200, 900, 500, 400, 300) are the ones
`offset 5` skips, and 200/100 are what's left:

```ruby
dashboard[:card_payments].map { |row| row[:amount][:cents] }  # => [200, 100]
```

## authorize

<!-- generated:begin word=authorize -->
`authorize policy, tenant:` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | policy |
| `tenant:` | symbol | false | tenant |
<!-- generated:end -->

Declares a policy name (recorded, never checked — no caller-identity or
grant system exists to check it against) and, when `tenant:` is given,
a mandatory tenant boundary that IS enforced: a caller must pass that
field as an argument or the ask refuses with `Unauthorized`
(`Runtime::TenantScope`), and every returned row is scoped to the
value given, regardless of what other filters were declared. `tenant:`
must name the same collection `where`/`order_by`/`limit`/`offset`
would (`ReadModelBuilder#seal_query_options` holds it to the same
"exactly one many-side head" rule).

`DepotManifest` declares `authorize :depot_access, tenant: :region`, so
naming the depot is not enough — an ask that does not say which region
it is scoped to is refused:

```ruby
runtime.query("ReadModelReference.DepotManifest", depot: "dp-1")  # ~> Unauthorized: pass region:
```

Every ask further up this page passed one, which is why they answered
at all. The policy name beside it is the half nothing checks:

```ruby
runtime.registry.bluebook("ReadModelReference").read_model("DepotManifest").authorization.policy  # => "depot_access"
```

## inspect_query

<!-- generated:begin word=inspect_query -->
`inspect_query mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | false | mode |
<!-- generated:end -->

Asks to inspect the compiled query. On the aggregate-`query` path this
is a capability gate through `Ports::Query.validate!`; the read model
runtime never reaches that code at all, so declaring it here has no
effect, refusal or otherwise.

`DepotManifest` declares it, and every ask above answered ordinary rows
regardless — no inspection came back, and nothing refused either:

```ruby
runtime.registry.bluebook("ReadModelReference").read_model("DepotManifest").inspection.mode  # => :sql
```

**Written exemption (ADR 0025 principle 4)** — the sentence above is
the reason: the read model runtime never reaches the code this word
gates at all, so a real corpus declaration would be strictly inert —
even less than `Query`'s own version, which is at least a live
capability gate against `Ports::Query.validate!`.

## limit

<!-- generated:begin word=limit -->
`limit value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `limit`, applied to the same one many-side
collection `where` is (see `where`).

`DepotManifest` declares `limit 2` over four parcels, and only the many
side is capped — the depot itself is still one whole record:

```ruby
manifest = runtime.query("ReadModelReference.DepotManifest", depot: "dp-1", region: { value: "north" }).first
manifest[:parcels].size  # => 2
manifest[:depot][:code][:value]  # => "dp-1"
```

## offset

<!-- generated:begin word=offset -->
`offset value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `offset`, applied to the same one many-side
collection `where` is (see `where`).

`DepotManifest` orders four parcels heaviest first, skips one, and
takes two — so the heaviest is deliberately not in the answer:

```ruby
manifest[:parcels].map { |row| row[:label][:value] }  # => ["p-2", "p-3"]
```

Skip-then-take, the same reading SQL gives `LIMIT n OFFSET m`. Taking
first and skipping after would have answered a single parcel here, and
nothing at all one page further on.

Real, not only synthetic — banking's own `ComplianceDashboard`
declares it for the same reason: the sixth-through-tenth worst
disputes, a genuine second page once the first five are reviewed:

```ruby
runtime.registry.bluebook("Banking").read_model("ComplianceDashboard").offset.value  # => 5
```

## cursor

<!-- generated:begin word=cursor -->
`cursor value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | value |
<!-- generated:end -->

Refused at build (`ReadModelBuilder#seal_cursor`, raises `Malformed`). No
interpreter implements cursor pagination — declaring `cursor` here is
always an error, not a silent no-op. Use `limit`/`offset` instead.

There is no working example to write, and that is the documentation —
the word refuses where it is written:

```ruby
Hecksagain::Bluebook::DSL::ReadModelBuilder.build("Paged") { include ReadModelReference::Parcel; cursor :label }  # ~> Malformed: no interpreter implements cursor pagination
```

**Written exemption (ADR 0025 principle 4)** — same reasoning as
`Query`'s own `cursor` section: a word that refuses unconditionally at
build has no corpus use to give, and S15 removes it from the core
grammar regardless.

## nulls

<!-- generated:begin word=nulls -->
`nulls mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
<!-- generated:end -->

Sets how nulls sort relative to real values, for the same one
many-side collection `order_by` sorts (see `order_by`). Same reading
on every engine as a `query`'s `nulls`.

`weight` is optional on a `Parcel`, so one of the four has none.
`nulls :last` puts it after every real weight rather than wherever the
store would have left it — which is what keeps the offset above meaning
the same thing twice running:

```ruby
runtime.registry.bluebook("ReadModelReference").read_model("DepotManifest").null_semantics.mode  # => :last
```

**Written exemption (ADR 0025 principle 4)** — the one real read model
here shaped for `where`/`order_by`/`limit`/`offset` at all
(`ComplianceDashboard`, above) orders by `CardPayment#amount`, which
is not optional; no read model in this corpus has an ordered single-
collection view whose ordering field can genuinely be absent, so
there is nothing real to demonstrate `nulls` sorting against yet.

