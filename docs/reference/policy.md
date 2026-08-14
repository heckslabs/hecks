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
    trigger  "RefCard.Block"
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
`trigger trigger_command` — fills `trigger_command`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | trigger_command |
<!-- generated:end -->

The command `on`'s event fires, named bare — `"Aggregate.Command"`,
never domain-prefixed — because it defaults to this policy's own
domain; see `across` to reach another one. The event's whole payload
forwards verbatim as the command's arguments, so the two shapes have to
agree before either is written. A policy that ends up triggering the
event it reacts to does not loop forever: `Dispatcher::MAX_REACTION_DEPTH`
(5) stops the chain and records why.

The triggered command really ran — a review exists that nothing in the
banking call chain asked for:

```ruby
runtime.registry.reaction_log.last[:trigger]    # => "Compliance::AccountFreezeReview.Open"
runtime.registry.reaction_log.last[:delivered]  # => true
Compliance::AccountFreezeReview.find("po-a1").status  # => "open"
```

"The event's whole payload forwards verbatim" is the part to write
against, and it is a real constraint on the target rather than a
detail. `FreezeAccountsOnSuspension`, in the same chapter, reacts to
`CustomerSuspended` and triggers `Account.FreezeAccount` — so
`FreezeAccount` has to be able to TAKE `standing`, a field a freeze
never reads, purely because the event carries it. It declares it
optional for exactly that reason.

There is no projection between the two: a policy's `trigger` has no
`with:` the way a saga's own `dispatch` does. A target that cannot
take every field the event carries is refused, the triggering command
still succeeds, and the reason lands in the reaction log rather than in
the caller's lap — which is a good way for a policy to be broken for a
long time without anyone noticing.

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

A card belonging to somebody else is not in the query's answer, so the
fan-out never reaches it:

```ruby
PolicyReference::RefCard.issue(serial: { value: "po-c3" }, holder: { value: "po-h2" })
PolicyReference::RefAlert.raise_alert(ref: { value: "po-al3" }, holder: { value: "po-h1" }, severity: { level: 5 })
runtime.registry.reaction_log.last(2).map { |row| row[:for_row] }  # => ["po-c1", "po-c2"]
```

**The delivery itself does not currently arrive.** `Block` addresses
its own aggregate — `reference_to RefCard` — and a command referencing
its OWN aggregate takes the bare reference key (`ref_card:`), while
`PolicyInterpreter#reference_key_for` merges the row id as
`ref_card_id:` unconditionally:

```ruby
runtime.registry.reaction_log.last[:delivered]  # => false
PolicyReference::RefCard.find("po-c1").status   # => "active"
```

Both spellings are real elsewhere — `customer_id:` addresses a FOREIGN
reference (`Account.Open`'s `reference_to Customer`, which is how the
`Onboarding` saga opens an account), and `account:` addresses a SELF
reference (`Account.FreezeAccount`). `for_each` is always the self-referencing
case, since it fans out over one aggregate's rows to fire that same
aggregate's command, so the `_id` suffix is wrong for every use of it.

