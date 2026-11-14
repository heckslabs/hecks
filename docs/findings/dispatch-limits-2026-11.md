# Dispatch limits: session cap and per-epic limit (2026-11-14)

Work item: dispatch-limits-measured-and-set. Settings live in `lib/hecks/hecks/tickets.world`.

## Decision rule, written before any numbers were read

A change to `work_limit cap` or `epic_wip_limit` needs, for each setting compared, a window of at
least 6 hours with `dispatch_roll_forward` true, the tidy loop working, and no other limit changed,
and it needs landed work items per hour to rise by at least 20% without the 1-minute load average
staying above `dispatch_max_load` (10.0). Without that, the values stay as they are.

## What is known (read-only, 2026-11-14)

| Date | Change |
|------|--------|
| 2026-11-11 | `dispatch_max_load` 10.0 |
| 2026-11-12 01:00 | `epic_wip_limit` 2 to 4 (#1358) |
| 2026-11-13 | `work_limit cap` 5 to 7 (#1370) |

`Dispatch.preview` on 2026-11-14 showed 6 of cap 7 started at load 8.6 (load 11 to 12 earlier in the
day), with about 25 work items skipped for "cap 7 reached". `dispatch_roll_forward` is false (the
owner's pause), and the Mechanical cleanup epic (tidy of finished sessions and worktrees) is open.

## What is not measured

Throughput per hour and load per window are **unmeasured**. No launcher command reports landed items
per hour or load history by window, and a script over the event tap was refused (CLAUDE.md: a missing
command is a bluebook change, not a one-off script). Every window above also overlaps another change,
so a retrospective read could not have separated the settings. Caps 6 and 8 and epic limit 2 under the
current code have no window at all.

## Result

The data does not clear the rule, so `cap` stays 7 and `epic_wip_limit` stays 4.

## Open item for the owner: a controlled run

1. Turn `dispatch_roll_forward` on and wait for the tidy loop to work.
2. For each of cap 6, 7 and 8 (epic limit 4), then epic limit 2 and 4 (cap 7), hold the setting for
   6 hours, changing only `tickets.world`.
3. Per window record landed work items per hour, mean and p95 of the 1-minute load, the count of
   "cap reached" skips from `Dispatch.preview`, and shed requests.
4. Apply the rule above. A missing command for step 3 is a Delegate bluebook change to file first.
