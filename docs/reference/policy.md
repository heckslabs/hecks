# Policy

<!-- generated:begin id=page -->
Words available inside `policy do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

`on`, `trigger` and `across` run against `examples/banking` and
`examples/compliance`, which wire a real cross-domain reaction between
them. `where` and `for_each` appear nowhere in the corpus, so they get a
chapter of their own here — a card that is blocked whenever its holder
draws a severe enough alert:

```ruby bluebook
Hecks.bluebook "PolicyReference" do
  vision "The two policy modifiers the corpus never needed."

  aggregate "RefCard" do
    identified_by Serial, as: :serial
    attribute :holder, Holder

    value_object "Serial" do
      attribute :value, String
    end

    value_object "Holder" do
      attribute :value, String
    end

    lifecycle :status, default: "active" do
      transition "Block" => "blocked", from: "active"
    end

    command "Issue" do
      attribute :serial, Serial
      attribute :holder, Holder
      then_set :serial, to: :serial
      then_set :holder, to: :holder
      emits "RefCardIssued"
    end

    command "Block" do
      reference_to RefCard
      emits "RefCardBlocked"
    end

    query "ForHolder" do
      attribute :holder, Holder
      where(holder: :holder)
    end
  end

  aggregate "RefAlert" do
    identified_by AlertRef, as: :ref
    attribute :holder,   Holder
    attribute :severity, Severity

    value_object "AlertRef" do
      attribute :value, String
    end

    value_object "Holder" do
      attribute :value, String
    end

    value_object "Severity" do
      attribute :level, Integer, default: 0
    end

    # NOT `command "Raise"` — that door would be spelled `RefAlert.raise`,
    # and `raise` is Kernel's, so the facade never sees the call.
    command "RaiseAlert" do
      attribute :ref,      AlertRef
      attribute :holder,   Holder
      attribute :severity, Severity
      then_set :ref,      to: :ref
      then_set :holder,   to: :holder
      then_set :severity, to: :severity
      emits "RefAlertRaised"
    end
  end

  policy "BlockCardsOnSevereAlert" do
    on       "RefAlertRaised"
    where    { severity.level >= 3 }
    for_each "RefCard.ForHolder"
    # THE ROW, AND NOTHING ELSE. `Block` takes only which card; the
    # alert's own `ref`/`holder`/`severity` are none of its business,
    # and without this projection they would ride along and be refused.
    trigger  "RefCard.Block", with: { ref_card: :ref_card }
  end
end
```

```ruby boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/compliance/bluebook/compliance.bluebook"))

Hecks.hecksagon("Banking") do
  Banking::Customer.persisted_by("Memory")
  Banking::Account.persisted_by("Memory")
end

Hecks.hecksagon("Compliance") do
  Compliance::AccountFreezeReview.persisted_by("Memory")
  Compliance::BoxSurrenderReview.persisted_by("Memory")
end

Hecks.hecksagon("PolicyReference") do
  PolicyReference::RefCard.persisted_by("Memory")
  PolicyReference::RefAlert.persisted_by("Memory")
end
```

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "po-1" },
                 name: { given: "Dorothy", family: "Vaughan" },
                 email: { address: "dorothy@example.com" })
account = Banking::Account.open(customer_id: "po-1", number: { value: "po-a1" },
                                kind: { name: "current" }, daily_limit: { cents: 50_000 })
```

## on

<!-- generated:begin word=on -->
`on on_event` — fills `on_event`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | on_event |
<!-- generated:end -->

The event this policy reacts to. By the time it arrives it is already a
committed fact — `on` names it unconditionally; `where`, below, is
where a policy adds a condition of its own.

`ReviewOnFreeze` names `"Account.AccountFrozen"`. Freezing the account
is the only act here — nothing mentions compliance at the call site:

```ruby
runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "po-a1" })
runtime.registry.reaction_log.last[:on]  # => "AccountFrozen"
```

## trigger

<!-- generated:begin word=trigger -->
`trigger trigger_command, with:` — fills `trigger_command`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | trigger_command |
| `with:` | pairs | false | with_spec |
<!-- generated:end -->

The command `on`'s event fires, named bare — `"Aggregate.Command"`,
never domain-prefixed — because it defaults to this policy's own
domain; see `across` to reach another one. Without `with:`, the event's
whole payload forwards verbatim as the command's arguments, so the two
shapes have to agree before either is written; `with:` is how a trigger
whose shape is not its event's says what it actually needs. A policy
that ends up triggering the event it reacts to does not loop forever:
`Dispatcher::MAX_REACTION_DEPTH` (5) stops the chain and records why.

The triggered command really ran — a review exists that nothing in the
banking call chain asked for:

```ruby
runtime.registry.reaction_log.last[:trigger]    # => "Compliance::AccountFreezeReview.Open"
runtime.registry.reaction_log.last[:delivered]  # => true
Compliance::AccountFreezeReview.find("po-a1").status  # => "open"
```

**`with:` names what the trigger is given.** Same `key => value` shape a
saga's own `dispatch ..., with:` takes, and read the same way: a Symbol
names a field on the triggering event, anything else is a literal the
policy supplies itself.

Left off, the whole payload forwards — which is a real constraint on the
target, not a detail. `FreezeAccountsOnSuspension`, in the same chapter,
reacts to `CustomerSuspended` and triggers `Account.FreezeAccount`;
without a projection, `FreezeAccount` would have to be able to TAKE the
`standing` that event carries, a field a freeze never reads, and Account
would need a value object declared solely to type it. Naming what the
trigger wants is what makes that unnecessary:

```ruby skip
# examples/banking/bluebook/banking.bluebook
policy "FreezeAccountsOnSuspension" do
  on       "CustomerSuspended"
  for_each "Account.OpenForCustomer"
  trigger  "Account.FreezeAccount", with: { account: :account }
end
```

`account` is the key the fan-out merges for each row it answers — the
row is part of the source a projection reads from, not something bolted
on after it, which is what lets a trigger be given the record and
nothing else. See `for_each` below for the fan-out itself.

A target that cannot take every field it is given is refused, the
triggering command still succeeds, and the reason lands in the reaction
log rather than in the caller's lap — which is a good way for a policy
to stay broken for a long time without anyone noticing.

## across

<!-- generated:begin word=across -->
`across target_domain` — fills `target_domain`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | target_domain |
<!-- generated:end -->

Names the domain a `trigger` reaches into when it lives outside this
policy's own. Leave it off and `trigger` is assumed to name a command
in the same domain as the event that fired it — the ordinary case.

`ReviewOnFreeze` declares `across "Compliance"`, and that is the whole
difference between the bare `"AccountFreezeReview.Open"` it writes and
the fully-qualified command the runtime actually dispatched:

```ruby
runtime.registry.reaction_log.first[:trigger]  # => "Compliance::AccountFreezeReview.Open"
```

## where

<!-- generated:begin word=where -->
`where do ... end` — fills `where`
<!-- generated:end -->

A guard on whether this policy fires at all, read against the
triggering event's own payload — `where { amount.cents > 1_000_00 }`.
Same extraction as a command's `given`/`ensures` (the block's source is
read once, at build time, and never called directly — only the
extracted text is evaluated, by the same expression evaluator a
command's own rules run through), but no description argument the way
`given`/`ensures` each carry one: a `given`'s description becomes a
refusal message, and a `where` that does not hold refuses nothing — the
policy is silently a no-op for that event, exactly like an event
qualifier (`on "Account.Frozen"` vs. a `Payment.Frozen`) that does not
match. Nothing is logged either way; a policy that never applies to an
event leaves no more trace than one that was never declared.

`BlockCardsOnSevereAlert` guards on `severity.level >= 3`. A mild alert
raises nothing anywhere — the card stays active and the reaction log
does not grow:

```ruby
PolicyReference::RefCard.issue(serial: { value: "po-c1" }, holder: { value: "po-h1" })
before = runtime.registry.reaction_log.size

PolicyReference::RefAlert.raise_alert(ref: { value: "po-al1" }, holder: { value: "po-h1" }, severity: { level: 1 })
PolicyReference::RefCard.find("po-c1").status  # => "active"
runtime.registry.reaction_log.size == before   # => true
```

## for_each

<!-- generated:begin word=for_each -->
`for_each for_each` — fills `for_each`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | for_each |
<!-- generated:end -->

Fan-out: `trigger` fires once per row a declared query answers, instead
of once for the event — `for_each "Account.OpenForCustomer"`. The named
query runs against the SAME domain the event belongs to, using the
event's own payload as the query's arguments, unless the verb is
itself domain-qualified (`"Domain::Aggregate.query_name"`) — the same
default a saga's own `dispatch` command name already takes. Each
matching row's own id is merged into the forwarded payload under the
iterated aggregate's own reference-key convention (`account_id` for
`Account` — the same name a bare `reference_to Account` would mint), so
`trigger`'s target command addresses the right record without either
side having to say the argument's name twice. `where`, above, still
gates the whole fan-out, evaluated once against the event, not once
per row.

One alert, two cards held by the same person, and the fan-out runs once
per row `ForHolder` answers — the alert never named a card. Each row is
recorded under `for_row:`:

```ruby
PolicyReference::RefCard.issue(serial: { value: "po-c2" }, holder: { value: "po-h1" })

PolicyReference::RefAlert.raise_alert(ref: { value: "po-al2" }, holder: { value: "po-h1" }, severity: { level: 5 })
runtime.registry.reaction_log.last(2).map { |row| row[:for_row] }  # => ["po-c1", "po-c2"]
```

Each row really is delivered to, and both cards moved — nothing at the
call site named a card:

```ruby
runtime.registry.reaction_log.last(2).map { |row| row[:delivered] }.uniq  # => [true]
PolicyReference::RefCard.find("po-c1").status  # => "blocked"
PolicyReference::RefCard.find("po-c2").status  # => "blocked"
```

A card belonging to somebody else is not in the query's answer, so the
fan-out never reaches it — this one was issued before the alert above
and is still untouched:

```ruby
PolicyReference::RefCard.issue(serial: { value: "po-c3" }, holder: { value: "po-h2" })
PolicyReference::RefAlert.raise_alert(ref: { value: "po-al3" }, holder: { value: "po-h2" }, severity: { level: 5 })
runtime.registry.reaction_log.last[:for_row]  # => "po-c3"
```

Only `po-h2`'s own card is in that fan-out — `po-c1` and `po-c2` were
never candidates, because the query answered about a different holder.

The key the row arrives under is `ref_card` — BARE, not `ref_card_id`.
A command referencing its OWN aggregate is addressed by the bare
reference key, and a fan-out is always that case, since it iterates one
aggregate's rows to fire that same aggregate's command. The `_id`
spelling is the FOREIGN one (`Account.Open`'s `reference_to Customer`,
which is how the `Onboarding` saga opens an account), and it is what
this merged unconditionally before — so every fan-out in the language
was refused, per row, into the reaction log.

