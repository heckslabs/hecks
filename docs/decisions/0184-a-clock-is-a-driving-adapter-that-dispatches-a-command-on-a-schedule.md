# A clock is a driving adapter that dispatches a command on a schedule

**Status:** Proposed. Date: 2026-11-04. Owner: to be decided. Not yet built.

## Context

A domain can be reached from outside in four ways: `Ruby`, `Cli`, `Json` and `Mcp`. Each is a
driving adapter. The hecksagon admits them with `driven_by`, and the grammar's `DrivingAdapter`
value object accepts only those four names (`lib/hecks/language/hecksagon/hecksagon.bluebook`).

Nothing in the domain fires on time. A domain that needs a nightly close, a retry sweep or a
periodic reconciliation has to be run by an external cron or a scheduler that the project writes
by hand. The survey (item 3, "Drivers") asked for inbound clocks declared in the hecksagon and
projected to a process file, so the schedule lives with the rest of the wiring.

The name needs care. "Driver" already means a driving adapter in this codebase, and a clock is
one, so calling the new thing a driver would blur two concepts. This ADR calls it a **clock**.

## Decision

1. **A clock is a driving adapter.** It is a fifth value of `DrivingAdapter`, `Clock`. It is
   admitted through `driven_by` like the others, and a domain that declares `driven_by` without
   `Clock` refuses its clocks at boot.
2. **A clock dispatches one command.** It does not run code of its own. Each firing goes through
   the normal dispatch path, so the command's `given`, its role and the governance checks all
   apply. A clock cannot do what a caller could not.
3. **Triggers.** A clock has one trigger: `every` (an interval), `cron` (a five-field
   expression), or `at` (a single instant). The grammar for these is decided in the open
   questions.
4. **The tag.** A firing records `clock` as its source (ADR 0183). `clock` is added to
   `SOURCE_TAGS`.
5. **Projection.** Clocks are projected to a process file (a `Procfile` line per clock, or one
   runner for all), so each clock runs out of process. A dead clock stalls only itself, which is
   the survey's reason for out-of-process placement.
6. **A missed tick is skipped, not replayed.** A clock that was down does not catch up with a
   burst of firings. The next scheduled tick fires, and the skip is logged.

Illustrative only, the grammar is not decided:

```ruby
clock "NightlyClose" do
  cron "0 2 * * *"
  dispatch "Ledger::CloseDay"
end
```

## Alternatives considered

- **A "driver" as a new kind of thing.** Rejected. It would be a second concept for the same
  thing as a driving adapter, and it would sit outside `driven_by`, so the admission rules would
  not cover it.
- **Clocks in the domain's own code.** Rejected. It keeps the schedule out of the hecksagon, which
  is where the rest of the wiring is, and it can't be checked at boot.
- **Catch up on missed ticks.** Rejected as the default. A clock that was down for a day would
  fire a day's worth of commands at once, which is usually the wrong thing for a close or a sweep.

## Consequences

- **One firing at a time across replicas.** If two processes run the same clock, the command
  fires twice. A firing must take a lock or a lease before dispatching. This is the same problem
  as the outbox's `claimed` rows (ADR 0053) and needs the same answer.
- **`SOURCE_TAGS` grows by one.** It lives in the runtime after ADR 0183.
- **Projection is new.** Nothing in the codebase projects a process file for scheduling today.
- **Hosts that cannot run a long-lived process** (Lambda, D1 or the static adapters) cannot run a
  clock as projected. A clock on such a domain is refused at boot, not silently dropped.

## Decided

Decided by the owner on 2026-11-04, each as recommended.

1. **Trigger grammar.** Literals: `cron "0 2 * * *"` (a string), `every "1h"` (a duration
   literal), `at` an ISO-8601 time.
2. **Single firing.** A Postgres advisory lock per clock name, taken for each firing. Sqlite and
   Memory need their own single-process rule, not decided here.
3. **Time zone.** `cron` runs in UTC unless the clock names a zone, e.g. `zone: "America/New_York"`.
4. **Process layout.** One process per clock, one Procfile line each.
5. **Host support.** A clock on a host with no long-lived process (Lambda, D1, the static
   adapters) refuses to boot, naming the host.

## Open questions

- Single firing on Sqlite and Memory: a single-process rule, or refuse clocks on those adapters.

## Verification status

Written from the grammar file and the survey. No scheduling code exists to check against, the
Procfile and cron projection were not looked for beyond a search that found nothing, and no specs
were run.
