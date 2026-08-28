# ProcessManager

<!-- generated:begin id=page -->
Words available inside `process_manager do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example on this page runs against `examples/banking`'s `Onboarding`
saga — the one that carries no compensating leg, because a KYC case that
does not clear has nothing to put back:

```ruby skip
# examples/banking/bluebook/
process_manager "Onboarding" do
  correlates_by :"reference.value"
  starts_on "OnboardingOpened"
  ends_on   "AccountOpened"

  transition "OnboardingCleared" => "cleared", from: "screening" do
    dispatch Account::Open, with: {
      customer: :customer, number: :account_number,
      kind: { name: "current" }, daily_limit: { cents: 0 }
    }
  end

  transition "OnboardingDeclined" => "declined", from: "screening"
end
```

```ruby boot
Hecks::Adapters::Folder.new.load_bluebooks(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook"))

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

```ruby
runtime.dispatch("Banking::Customer.Register", reference: { value: "pm-1" },
                 name: { given: "Katherine", family: "Johnson" },
                 email: { address: "katherine@example.com" })
```

## correlates_by

<!-- generated:begin word=correlates_by -->
`correlates_by correlates_by` — fills `correlates_by`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | correlates_by |
<!-- generated:end -->

The dotted scalar path that ties a stream of events to one saga
instance — e.g. `:"docket.value"`, never a bare field like `:docket`.
A non-scalar key has no single unambiguous rendering to correlate on,
so the declaration is refused at load time unless it names a scalar.

`Onboarding` correlates on `:"reference.value"`, so the instance is
filed under the case's own reference — not a saga id of its own:

```ruby
kase = Banking::OnboardingCase.open!(customer: "pm-1", reference: { value: "pm-c1" },
                                    account_number: { value: "pm-a1" })
runtime.registry.saga_instances["Onboarding"].keys  # => ["pm-c1"]
```

## starts_on

<!-- generated:begin word=starts_on -->
`starts_on starts_on, starts_on`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | starts_on |
| positional 1 | text | true | starts_on |
<!-- generated:end -->

The event that begins tracking a new instance of this saga.

Nothing declares the instance into existence — `OnboardingOpened`
arriving is what creates it, recorded as `born:` in the saga log:

```ruby
runtime.registry.saga_log.first[:on]    # => "OnboardingOpened"
runtime.registry.saga_log.first[:born]  # => true
```

## ends_on

<!-- generated:begin word=ends_on -->
`ends_on ends_on, ends_on`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | ends_on |
| positional 1 | text | true | ends_on |
<!-- generated:end -->

The event that closes an instance; once it arrives, the instance
stops being tracked.

`Onboarding` ends on `AccountOpened` — the event its own final
`dispatch` causes. Clearing the case therefore runs the whole flow to
its end in one act, and the instance is gone afterwards:

```ruby
kase.clear!
runtime.registry.saga_instances["Onboarding"]  # => {}
```

"Stops being tracked" is exactly that, and no more — the log still
carries what happened:

```ruby
runtime.registry.saga_log.map { |row| row[:on] }.compact  # => ["OnboardingOpened", "OnboardingCleared", "AccountOpened"]
```

## transition

<!-- generated:begin word=transition -->
`transition pairs, from:, from: do ... end` / `transition pairs, from:, from:` — opens a `Handler` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
| `from:` | text | true | from_state |
| `from:` | list | false | from_state |
<!-- generated:end -->

The SAME word `Lifecycle`'s own `transition` already carries (see
lifecycle.md), one level over — `"EventType" => "to_state", from:
"from_state"` — differing only in what fires it: a command on an
aggregate, an event here. `event_type` is usually an event name;
`:refused` is the one exception, matching a dispatched command's own
refusal rather than any event an aggregate emits — the
compensating-leg mechanics live in policies-and-process-managers.md.

Unlike `Lifecycle#transition`, `from:` is MANDATORY — a saga's own
admission check tests a running instance's current state by plain
equality, with no "matches any state" fallback the way an aggregate's
unconstrained transition has, so a transition naming no `from:` would
match no instance ever, silently, and is refused at declaration
instead:

```ruby skip
Hecks.bluebook("Gone") { process_manager("Nowhere") { correlates_by :"ref.value"; starts_on "Opened"; ends_on "Closed"; transition "Opened" => "open" } }  # ~> InvalidProcessManager: Nowhere's transition {"Opened"=>"open"} names no from: — a process manager's own admission checks a saga instance's CURRENT state exactly, so a transition with no from: would match no instance ever, silently
```

Given a list, a leg may fire from any of several states, the same
`from:` shape a lifecycle transition already accepts — see
`Banking::Account`'s own `transition "CloseAccount" => "closed", from:
["open", "frozen"]` on lifecycle.md.

There is no `state "x"` line any more — every state a saga's instances
can hold is DERIVED from the transitions that name it, first-seen
order, the same way an aggregate's own lifecycle states already
derive from theirs. The instance starts in the first state any
transition names and moves only where a leg sends it — both moves are
in the log:

```ruby
runtime.registry.saga_log.map { |row| [row[:from], row[:to]] }.compact.uniq  # => [[nil, nil], ["screening", "cleared"]]
```

`transition "OnboardingCleared" => "cleared", from: "screening"` is
the leg that opened the account — the `Account.Open` its body
dispatches ran for real, against a customer nobody named at the call
site:

```ruby
Banking::Account.find("pm-a1").kind.name  # => "current"
```

A leg with no block is still a leg: `transition "OnboardingDeclined"
=> "declined", from: "screening"` moves the instance and dispatches
nothing, because a case that never cleared opened no account to undo.

