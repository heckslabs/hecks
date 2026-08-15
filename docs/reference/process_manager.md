# ProcessManager

<!-- generated:begin id=page -->
Words available inside `process_manager do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Every example on this page runs against `examples/banking`'s `Onboarding`
saga — the one that carries no compensating leg, because a KYC case that
does not clear has nothing to put back:

```ruby skip
# examples/banking/bluebook/banking.bluebook
process_manager "Onboarding" do
  correlates_by :"reference.value"
  starts_on "OnboardingOpened"
  ends_on   "AccountOpened"

  state "screening"
  state "cleared"
  state "declined"

  on "OnboardingCleared", transition: { "screening" => "cleared" } do
    dispatch "Banking::Account.Open", with: {
      customer: :customer, number: :account_number,
      kind: { name: "current" }, daily_limit: { cents: 0 }
    }
  end

  on "OnboardingDeclined", transition: { "screening" => "declined" }
end
```

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
kase = Banking::OnboardingCase.open(customer: "pm-1", reference: { value: "pm-c1" },
                                    account_number: { value: "pm-a1" })
runtime.registry.saga_instances["Onboarding"].keys  # => ["pm-c1"]
```

## starts_on

<!-- generated:begin word=starts_on -->
`starts_on starts_on` — fills `starts_on`

| argument | kind | required | fills |
|---|---|---|---|
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
`ends_on ends_on` — fills `ends_on`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | ends_on |
<!-- generated:end -->

The event that closes an instance; once it arrives, the instance
stops being tracked.

`Onboarding` ends on `AccountOpened` — the event its own final
`dispatch` causes. Clearing the case therefore runs the whole flow to
its end in one act, and the instance is gone afterwards:

```ruby
kase.clear
runtime.registry.saga_instances["Onboarding"]  # => {}
```

"Stops being tracked" is exactly that, and no more — the log still
carries what happened:

```ruby
runtime.registry.saga_log.map { |row| row[:on] }.compact  # => ["OnboardingOpened", "OnboardingCleared", "AccountOpened"]
```

## state

<!-- generated:begin word=state -->
`state states` — fills `states`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | states |
<!-- generated:end -->

Declares one state this saga's instances may be in, repeated once per
state. Every `from`/`to` a handler's `transition:` names must appear
here, or the declaration is refused at load time.

The instance starts in the first state declared and moves only where a
handler's `transition:` sends it — both moves are in the log:

```ruby
runtime.registry.saga_log.map { |row| [row[:from], row[:to]] }.compact.uniq  # => [[nil, nil], ["screening", "cleared"]]
```

## on

<!-- generated:begin word=on -->
`on event_type, event_type, transition: do ... end` / `on event_type, event_type, transition:` — opens a `Handler` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | event_type |
| positional 1 | symbol | false | event_type |
| `transition:` | pairs | true |  |
<!-- generated:end -->

Opens one handler: a leg that must arrive while the instance is in
`transition:`'s `from` state, and moves it to `to` once its `dispatch`es
run. `event_type` is usually an event name; `:refused` is the one
exception, matching a dispatched command's own refusal rather than any
event an aggregate emits — the compensating-leg mechanics live in
policies-and-process-managers.md.

`on "OnboardingCleared"` is the leg that opened the account — the
`Account.Open` its body dispatches ran for real, against a customer
nobody named at the call site:

```ruby
Banking::Account.find("pm-a1").kind.name  # => "current"
```

A handler with no body is still a handler: `on "OnboardingDeclined",
transition: { "screening" => "declined" }` moves the instance and
dispatches nothing, because a case that never cleared opened no account
to undo.

