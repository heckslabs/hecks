# Query

<!-- generated:begin id=page -->
Words available inside `query do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecksagain/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Most of these run against `examples/banking`, whose `Account` and
`SafeDepositBox` queries carry ordering, limits, and a real tenant
boundary. `reference_to`, `offset` and `nulls` are written nowhere in
the corpus, so they get a chapter of their own:

```ruby boot
Hecksagain::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

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

```ruby bluebook
Hecks.bluebook "QueryReference" do
  vision "The query words the corpus does not yet write."

  aggregate "Warden" do
    attribute :badge, Badge

    identified_by :badge
    value_object("Badge") { attribute :value, String }

    lifecycle :status, default: "on_duty" do
      transition "StandDown" => "off_duty", from: "on_duty"
    end

    command "Appoint" do
      sets :badge
      emits "WardenAppointed"
    end

    command "StandDown" do
      reference_to Warden
      emits "WardenStoodDown"
    end
  end

  aggregate "Sighting" do
    attribute :tag, Tag

    identified_by :tag
    reference_to Warden
    attribute :species, Species
    attribute :count,   Count, optional: true

    value_object("Tag")     { attribute :value, String }
    value_object("Species") { attribute :value, String }
    value_object("Count")   { attribute :value, Integer }

    command "Log" do
      attribute :warden,    Warden
      sets :tag
      sets :species
      sets :count
      emits "SightingLogged"
    end

    query "ByWarden" do
      description "Every sighting one warden logged."
      reference_to Warden, as: :warden
      where(warden: :warden)
      order_by :tag
    end

    query "Paged" do
      description "The second page of two."
      order_by :tag
      limit 2
      offset 1
    end

    query "ByCount" do
      description "Ordered by count, with the uncounted ones last."
      order_by :count
      nulls :last
    end

    # A HOP — a field on the warden, not on the sighting.
    query "ByOffDutyWarden" do
      description "Sightings still filed against a warden who has stood down."
      where(:"warden/status" => "off_duty")
      order_by :tag
    end
  end
end
```

```ruby boot
Hecks.hecksagon("QueryReference") do
  QueryReference::Warden.persisted_by("Memory")
  QueryReference::Sighting.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "qy-1" },
                 name: { given: "Nancy", family: "Roman" },
                 email: { address: "nancy@example.com" })
account = Banking::Account.open!(customer: "qy-1", number: { value: "qy-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
account.credit!(amount: { cents: 9_000 }, narrative: { text: "funding" })

runtime.dispatch("QueryReference::Warden.Appoint", badge: { value: "w-1" })
runtime.dispatch("QueryReference::Warden.Appoint", badge: { value: "w-2" })
runtime.dispatch("QueryReference::Sighting.Log", tag: { value: "s-1" }, warden: "w-1", species: { value: "heron" }, count: { value: 3 })
runtime.dispatch("QueryReference::Sighting.Log", tag: { value: "s-2" }, warden: "w-1", species: { value: "egret" })
runtime.dispatch("QueryReference::Sighting.Log", tag: { value: "s-3" }, warden: "w-2", species: { value: "ibis" }, count: { value: 1 })
```

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the query — no rules attached, read by nothing but a human.

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").queries.find { |q| q.hecks_name == "Open" }.description  # => "Accounts that can transact today."
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, default:, optional:, pattern:, admits:, one_of:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | true | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
| `one_of:` | list | false | one_of |
<!-- generated:end -->

Declares an argument this query accepts at ask-time, not a field on the
aggregate — the `:symbol` a `where` value can resolve from
(`attribute :ceiling, Draft` backs `where(draft: { lt: :ceiling })`). A
`:symbol` naming no such attribute is refused when the bluebook builds.

`Overdrawn` declares `attribute :floor, Money`, and the caller supplies
it at ask-time — it is a parameter, not a field on `Account`:

```ruby
runtime.query("Banking::Account.Overdrawn", floor: { cents: 10_000 }).map { |row| row[:number][:value] }  # => ["qy-a1"]
```

Raise the floor and the same query answers differently, because the
argument is the whole of what changed:

```ruby
runtime.query("Banking::Account.Overdrawn", floor: { cents: 1_000 })  # => []
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:, optional:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Declares a query parameter that names another aggregate's own
identity, not a free string that only happens to look like one —
`reference_to Camper, as: :owner` inside `query "ByOwner" do ... end`
gives `owner` the same reference typing a real relationship deserves,
usable in `where(owner: :owner)` exactly as any other attribute would
be. Only the cross-reference shape: a query has no root of its own to
act on, so there is no self-reference form here the way `Command`'s
own `reference_to` has two of (see command.md) — just a plain
attribute typed as a reference, `as:` naming it (bare, it would default
to `camper_id`) and `optional:` working the same way it does anywhere
else `attribute` accepts it.

`ByWarden` takes a warden's own identity rather than a string that
happens to look like one, and uses it in `where` the same as any other
argument:

```ruby
runtime.query("QueryReference::Sighting.ByWarden", warden: "w-1").map { |row| row[:tag][:value] }  # => ["s-1", "s-2"]
runtime.query("QueryReference::Sighting.ByWarden", warden: "w-2").map { |row| row[:tag][:value] }  # => ["s-3"]
```

## where

<!-- generated:begin word=where -->
`where wheres` — fills `wheres`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | wheres |
<!-- generated:end -->

Filters on `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, and `contains` — a
bare value is shorthand for `eq`. The seal requires the field to be a
declared attribute or the lifecycle field, reached through any depth of
dotted path as long as it lands on a scalar (landing on a value object
is refused, and so is a field the aggregate never declared at all); the
ordered comparators additionally require that scalar to hold a number.
`contains` means real element membership on a `list_of` field and plain
substring on anything else — identically on every engine, including a
field whose own text carries a comma.

`/` CROSSES INTO ANOTHER RECORD through a `reference_to` attribute, `.`
WALKS FIELDS INSIDE THIS ONE (ADR 0025, "References") — the operator
alone says which kind of path this is. `where(:"customer/status" =>
"suspended")` on an aggregate that `reference_to Customer` filters on
Customer's own field, not anything the querying aggregate declares
itself; `where(:"customer.status" => ...)` never hops, whatever
`customer` names — it dead-ends the same way any dotted path onto a
non-value-object does. The hop's own segment name is the same one
`Facade::Handle`'s reference accessors answer to (`account.customer` in
Ruby, `:"customer/status"` in a query — one name, both places),
multi-hop chains read left to right (`:"engagement/client/status"`),
and a hop is `where`-only — `order_by` through a hop is refused
outright, since an ask is ordered by what its own rows hold and a hop
answers with a candidate set, not a sort key. See the
queries-and-read-models guide for the exact refusal wording, including
the existential-negation case (a nil or dangling reference never
satisfies a hop clause, whatever the comparator).

A bare value is `eq` — `Open` is `where(status: "open")`:

```ruby
runtime.query("Banking::Account.Open").size  # => 1
```

An ordered comparator reads the caller's argument. `HighBalance` is
`where(balance: { gte: :floor })`:

```ruby
runtime.query("Banking::Account.HighBalance", floor: { cents: 9_000 }).size  # => 1
runtime.query("Banking::Account.HighBalance", floor: { cents: 9_001 }).size  # => 0
```

A dotted path hops through a reference and reads a field on the TARGET.
`ByOffDutyWarden` asks about the warden, not the sighting — nothing on
a `Sighting` says anything about duty:

```ruby
runtime.query("QueryReference::Sighting.ByOffDutyWarden")  # => []
runtime.dispatch("QueryReference::Warden.StandDown", warden: "w-1")
runtime.query("QueryReference::Sighting.ByOffDutyWarden").map { |row| row[:tag][:value] }  # => ["s-1", "s-2"]
```

Nothing about the sightings changed — the hop read the warden, and the
sightings filed against the warden still on duty are not in the answer:

```ruby
runtime.query("QueryReference::Sighting.ByOffDutyWarden").map { |row| row[:warden] }.uniq  # => ["w-1"]
```

Banking carries the same shape in `OpenForSuspendedCustomers` — open
accounts whose customer has since been suspended. It now answers
nothing, ever, and that is the domain working rather than the query
failing: `FreezeAccountsOnSuspension` freezes every open account the
moment its customer is suspended, so the dangerous state this query
exists to surface can no longer be reached.

```ruby
Banking::Customer.find("qy-1").suspend!(standing: { value: "under-review" })
Banking::Account.find("qy-a1").status  # => "frozen"
runtime.query("Banking::Account.OpenForSuspendedCustomers")  # => []
```

Put back, so the sections below start where this one found things — a
reference page runs top to bottom against one boot:

```ruby
Banking::Customer.find("qy-1").reinstate!.status  # => "active"
```

## order_by

<!-- generated:begin word=order_by -->
`order_by order_field, order_way` — fills `order_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | order_field |
| positional 2 | symbol | false | order_way |
<!-- generated:end -->

Names the field to sort by, ascending unless the second argument is
`:desc`. The runtime always breaks ties by record identity underneath
whatever you declare, so an ask never silently falls back to store
order.

`ByWarden` orders by tag, and the rows come back in that order rather
than the order they were logged:

```ruby
runtime.query("QueryReference::Sighting.ByWarden", warden: "w-1").map { |row| row[:tag][:value] }  # => ["s-1", "s-2"]
```

`HighBalance` is the descending case — `order_by :balance, :desc`:

```ruby
high = runtime.registry.bluebook("Banking").aggregate("Account").queries.find { |q| q.hecks_name == "HighBalance" }
high.order_by.direction  # => :desc
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
(`Runtime::TenantScope`), and every returned row — on every engine,
Memory, Sqlite, Postgres, and the entity/sub-list path alike — is
scoped to the value given, regardless of what other filters were
declared.

`SafeDepositBox.Rented` declares `authorize :vault_access, tenant:
:branch_code`. Two boxes, in two branches:

```ruby
Banking::SafeDepositBox.rent!(customer: "qy-1", branch_code: { value: "DT" }, box_number: { value: 1 }, size: { value: "small" })
Banking::SafeDepositBox.rent!(customer: "qy-1", branch_code: { value: "UP" }, box_number: { value: 1 }, size: { value: "large" })
```

The tenant boundary is mandatory — an ask that does not say which branch
it is standing in is refused rather than answered broadly:

```ruby
runtime.query("Banking::SafeDepositBox.Rented")  # ~> Unauthorized: pass branch_code:
```

Name it, and every row is scoped to it. The other branch's box is not
in the answer, and no `where` said so:

```ruby
runtime.query("Banking::SafeDepositBox.Rented", branch_code: { value: "DT" }).map { |row| row[:branch_code][:value] }  # => ["DT"]
```

The policy name beside it is the half that is NOT checked — nothing in
this runtime knows what `:vault_access` would mean:

```ruby
rented = runtime.registry.bluebook("Banking").aggregate("SafeDepositBox").queries.find { |q| q.hecks_name == "Rented" }
rented.authorization.policy  # => "vault_access"
```

## inspect_query

<!-- generated:begin word=inspect_query -->
`inspect_query mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | false | mode |
<!-- generated:end -->

Asks to inspect the compiled query rather than (or alongside) its
rows. In practice this is a capability gate more than a feature —
`Ports::Query.validate!` only refuses when an adapter neither
implements its own `inspect_query` hook nor exposes a native `query`
method under the default `:sql` mode. No adapter in this codebase
defines the former, so today declaring it never changes what comes
back; it can only ever refuse.

Nothing in the corpus declares it, and the reason is in the sentence
above — against the Memory adapter it is a capability gate with nothing
behind it:

```ruby
runtime.registry.bluebook("Banking").aggregate("Account").queries.map(&:inspection).compact  # => []
```

Which is the whole of what it does today. The rows are the same rows
either way — a hint nobody reads is a comment with a syntax.

**Written exemption (ADR 0025 principle 4)** — a real corpus use would
be vacuous by construction: no adapter here implements the hook this
declares, so declaring it on a real query would change nothing the
query itself does and would not exercise any path this doctest above
doesn't already. The honest gap is upstream of the DSL word — an
adapter that actually implements `inspect_query` is what would give
this a real corpus use worth having.

## limit

<!-- generated:begin word=limit -->
`limit limit` — fills `limit`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | limit |
<!-- generated:end -->

Caps how many rows survive after ordering runs. Declare `order_by`
first if you mean to keep a particular slice — limit trims what
ordering already sorted, it doesn't decide which rows those are.

`Paged` declares `limit 2` over three sightings, so only two survive:

```ruby
runtime.query("QueryReference::Sighting.Paged").size  # => 2
```

## offset

<!-- generated:begin word=offset -->
`offset value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Skips that many rows after ordering, for paging. Refused together with
`cursor` on the same query — see `cursor`.

`Paged` declares `limit 2` and `offset 1` over three sightings, so it
skips the first and takes the two after it — the order SQL's own
`LIMIT n OFFSET m` reads, and now what every engine here answers:

```ruby
runtime.query("QueryReference::Sighting.Paged").map { |row| row[:tag][:value] }  # => ["s-2", "s-3"]
```

Skip-then-take is the part that matters, and it is the difference
between a second page and an empty one: taking two and THEN skipping one
would answer a single row here, and nothing at all at `limit 10, offset
10`.

## cursor

<!-- generated:begin word=cursor -->
`cursor value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | value |
<!-- generated:end -->

Refused at build (`QueryBuilder#seal_cursor`, raises `Malformed`). No
interpreter implements cursor pagination — declaring `cursor` here is
always an error, not a silent no-op. Use `limit`/`offset` instead.

There is no working example to write, and that is the documentation —
the word refuses where it is written, before anything can boot:

```ruby
Hecksagain::Bluebook::DSL::QueryBuilder.build("Paged") { cursor :tag }  # ~> Malformed: no interpreter implements cursor pagination
```

**Written exemption (ADR 0025 principle 4)** — ADR 0025's own table
asked for corpus use here, with no exemption listed, but a WORD that
refuses unconditionally at build has no corpus use to give: any
declaration anywhere would refuse the bluebook that carried it, so
"a real chapter uses `cursor`" and "the corpus builds" are mutually
exclusive claims. S15 (ADR 0026, "the Paging sub-language") is where
this gets resolved for real — `cursor`/`offset`/`nulls`/`limit` leave
the core grammar into their own attachment — landing a real corpus use
here first would be work S15 immediately throws away.

## nulls

<!-- generated:begin word=nulls -->
`nulls mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
<!-- generated:end -->

Sets how nulls sort relative to real values. This one is genuinely
enforced: both the in-memory ordering path and compiled SQL read it to
place nulls consistently rather than leaving it to whatever the store
happens to do.

`count` is optional on a `Sighting`, so one of the three has none.
`ByCount` declares `nulls :last`, and the uncounted sighting sorts
after the counted ones rather than wherever the store would have put
it:

```ruby
runtime.query("QueryReference::Sighting.ByCount").map { |row| row[:tag][:value] }  # => ["s-3", "s-1", "s-2"]
```

`s-2` is the one with no count, and it is last — the two real values
sort among themselves first.

