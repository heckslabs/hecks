# Clock

<!-- generated:begin id=page -->
Words available inside `clock do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference!` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

## cron

<!-- generated:begin word=cron -->
`cron cron, zone:` — fills `cron`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | cron |
| `zone:` | text | false | zone |
<!-- generated:end -->

Fires on a five-field cron expression: minute, hour, day of month, month and day of week. Each
field takes `*`, a number, a range `a-b`, a step `*/n` or `a-b/n`, and comma lists of these. It
runs in UTC unless `zone:` names a time zone such as `"America/Phoenix"`.

```ruby excerpt
clock "MorningPrintout" do
  cron "30 6 * * *", zone: "America/Phoenix"
  dispatch "Printout.Request", with: { printout_id: :firing_id, date: :fire_date }, as: "Journaler"
end
```

The block builds one clock:

```ruby
morning = Hecks::Bluebook::DSL::ClockBuilder.build("Morning") do
  cron "30 6 * * *", zone: "America/Phoenix"
  dispatch "Loan.OpenLoan"
end
[morning.trigger, morning.zone]  # => [:cron, "America/Phoenix"]
```

## every

<!-- generated:begin word=every -->
`every every` — fills `every`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | every |
<!-- generated:end -->

Fires on an interval: a whole number of seconds, minutes, hours or days (`30s`, `15m`, `1h`,
`1d`). Ticks fall on whole multiples of the interval since the Unix epoch, so a restarted clock
keeps the same ticks.

```ruby
sweep = Hecks::Bluebook::DSL::ClockBuilder.build("Sweep") do
  every "15m"
  dispatch "Loan.OpenLoan"
end
[sweep.trigger, sweep.expression]  # => [:every, "15m"]
```

## at

<!-- generated:begin word=at -->
`at at` — fills `at`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | at |
<!-- generated:end -->

Fires once, at an ISO-8601 instant that names its offset, such as
`"2026-11-23T06:30:00-07:00"`. Once the instant has passed, the clock has no next tick and stops.

```ruby
launch = Hecks::Bluebook::DSL::ClockBuilder.build("Launch") do
  at "2026-11-23T06:30:00-07:00"
  dispatch "Loan.OpenLoan"
end
[launch.trigger, launch.expression]  # => [:at, "2026-11-23T06:30:00-07:00"]
```

## dispatch

<!-- generated:begin word=dispatch -->
`dispatch dispatch, with:, as:` — fills `dispatch`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | dispatch |
| `with:` | pairs | false | with |
| `as:` | text | false | role |
<!-- generated:end -->

Names the command each firing dispatches, as `"Aggregate.Command"`. It goes through the normal
dispatch path with the source `clock`, so the command's givens, role and governance apply. `with:`
gives its arguments: a literal, or a symbol naming what the firing knows, `:fire_date` (the due
date in the clock's zone), `:fire_time` (the due instant) or `:firing_id` (the clock's name and
that instant). `as:` names the role it dispatches as, for a command that declares one. A tick the
clock wakes too late for is skipped and logged, never replayed.

```ruby
morning = Hecks::Bluebook::DSL::ClockBuilder.build("Morning") do
  every "1d"
  dispatch "Loan.OpenLoan", with: { day: :fire_date }, as: "Lender"
end
[morning.command_name, morning.arguments, morning.role]  # => ["OpenLoan", { day: :fire_date }, "Lender"]
```

