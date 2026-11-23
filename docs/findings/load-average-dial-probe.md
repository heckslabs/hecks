# The load average the fill reads: starts in a dip, before and after

The fill read the 1-minute load (`getloadavg`, first figure). It is spiky, so the fill started
sessions in a dip and the load then reached 38 (the 23:57 red flag). The Tickets world now has a
`load_average` dial (`minutes: 1`, `5` or `15`, default `5`; turn it with
`exe/hecks Dial.turn! setting.value=load_average.minutes becomes.value=15`). The fill's
`dispatch_max_load`, the expedite bar, the Machine's marks and the board's guard all read it.

## What the probe counts

A **start in a dip** is a session start followed, within 10 minutes, by a load over
`dispatch_max_load`. Count them over one night (22:00 to 06:00) and divide by the starts.

- Starts: the `started` events of Work items, from the event tap (`Operation.follow` on Work).
- Load: the board's load history (`/tmp/hecks-pipeline-board-load.json`, a sample every 10
  seconds, three hours kept) or the Machine sampler's readings; copy the file out at 06:00 for
  the night's last three hours, or keep the readings through the night.
- Limit: `dispatch_max_load.limit` as turned that night (10.0).

## Result

| Night | Average read | Starts | Starts in a dip | Share |
|-------|--------------|--------|-----------------|-------|
| before (1-minute) | 1 | not measured | not measured | |
| after (default) | 5 | not measured | not measured | |

Neither night is measured here: the branch was built in one working session, the load history
keeps three hours, and the Machine record carries no time, so a night's starts cannot be set
beside its load after the fact. The two rows are filled the first morning after each night: turn
`load_average.minutes` to 1 for the before night, leave the default for the after night, and
record the three figures above.

## Caveat

`dispatch_max_load` (10.0) was tuned against the 1-minute figure. The 5-minute average is lower
and steadier, so the same limit admits more starts; if the after night shows more load over the
limit, turn the limit down before blaming the average.
