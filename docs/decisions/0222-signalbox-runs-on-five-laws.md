# Signalbox runs on five laws

**Status:** Proposed. Date: 2026-11-19. Started on the owner's direct word ("start the signalbox
rewrite now"), from the grid and compute framing the owner agreed the same morning. The names
Signalbox and Roundhouse are proposed; `naming-decision-hecks-on-rails-and-its-parts` stays
Proposed. Work item `signalbox-five-laws-adr`, epic `signalbox-runs-on-five-laws`. Builds on
[0220](0220-a-run-and-a-day-have-a-spend-bound-declared-as-data.md) (a spend bound declared as data).

**Decision in one line:** the machine's compute is one budget; Signalbox decides who may draw on it
by five laws and one pressure signal, and Roundhouse only executes what Signalbox decided.

## Context

The pipeline's load handling is the Delegate module, `lib/hecks/hecks/delegate/delegate.bluebook`:
3,483 lines, 19 aggregates, 102 commands and 204 policies. Each problem met so far got its own limit,
and each limit is its own setting in `tickets.world`, tuned by hand in `turned.local.world`:
`work_limit` (cap 7, turned to 4), `work_cap` (moving between 2 and 10), `dispatch_max_load` (10.0,
turned to 20.5), `epic_wip_limit`, `cpu_budget` (6 boot hours, turned to 36), `load_shed`,
`machine_marks`, `heavy_jobs`, `ticks` and `idles`. No one of them sees the whole machine, and the
sessions they do not count (helpers, beats, gates, hand-run seats) are the ones that tripped it.

What happened on 2026-11-18 and 2026-11-19, read from the machine, the ledgers and the beat log:

- **Helper storms.** A blocked helper was seen as a stall, the stall check started an answerer, the
  answerer blocked, and the chain repeated: more than 80 sessions held about 22 GB of the 36 GB
  machine while 3 coders did the work. About 100 finished or idle sessions stood by the evening.
- **Phantom load.** About 40 sessions showed as working for 7 items in progress.
- **Red-main helpers while main was green.** Helpers started for a red main kept running, and new
  ones started, after main had turned green; their purpose was met and nothing ended them.
- **76 MCP servers.** 38 `hecks/tools/mcp` and 38 `serve_query_ir_mcp` Ruby processes (about 880 MB,
  and system time at half of every core): every session booted both servers whether its role used
  them or not.
- **The cap flipped 4, 5, 6, 7.** The moving cap followed each reading of the machine with no gap
  between its marks and no limit on its step, so it rose and fell with the noise.
- **The boot fuse tripped at 24.16 of 24 hours.** The whole-machine fuse (`cpu_budget`, the boot hours
  of a rolling day) was the first breaker to act. It stopped every new coder except red fixes while
  the helpers that had spent the budget kept running: the largest breaker tripped first.
- **90 minutes of landings bounced.** Finished branches clashed on shared files and were refused at
  landing, over and over, while new coders kept being started into the same areas.
- **A stale train copy rewrote the overlay.** The train copy (`~/.claude/hecks-train`) stopped at
  `98290fc2c` (2026-11-18 14:22) and lacked the main checkout's local files, so every beat ran
  yesterday's code on memory stores; one beat ran 17 minutes at a full core (load 32), and the copy
  wrote the retired `PromotionRecommendation` binding back into the main overlay.
- **Orchestrator seat copies.** On 2026-11-19 by 11:15 about 20 sessions named
  `handrun-orchestrator-*`, `orchestrator-seat-*` and the like stood together, each a copy of the
  one seat; with about 50 other non-productive sessions they held memory pressure at 2, the cap at
  its floor of 4 and the load at 32.

Throughput tells the same story: 2.3 items an hour on 2026-11-18 from 11:00 to 17:00 and about 5.8
from 17:20 to 22:00, when the places were full and the clutter was pruned. Capacity was not the
limit; load that did no work was.

The owner's framing: running the pipeline is running a grid. The resource is **compute** (memory,
CPU, model usage). Every session, coder or helper, is **load**; the machine is **supply**. The
headline measure is landings per unit of compute, without starving the person using the machine.

## Decision

### Two parts

- **Signalbox decides.** Who runs, how many, the helpers' share, what is shed, the order breakers
  trip in, and whether a part may act on shared state. It holds the laws and nothing else.
- **Roundhouse executes.** It starts, meters, rests, resumes, finishes and reaps sessions, takes the
  machine's readings and keeps the compute meter. It never decides and never starts a session on
  its own: every start carries the admission Signalbox gave it.

### The five laws

1. **Conservation.** Every action draws from one compute budget. Nothing creates load for free: a
   helper, a beat, a gate and a seat are admitted exactly as a coder is, and a helper cannot start a
   helper.
2. **One pressure signal.** Headroom against capacity (supply less draw less the person's reserve)
   is published continuously, like grid frequency, in four bands: normal, tight, short and dark (no
   current reading). Every part reads the same signal.
3. **Local response.** Each kind of session answers the signal by its own rule, with no orchestrator
   in the loop (droop control): in normal pressure all run; when tight or short, urgent coders keep
   running, lower-tier coders defer their heavy steps, helpers finish and leave, and gates wait
   their turn.
4. **Admission by headroom.** A session starts only if its expected draw fits the headroom. There is
   no cap to set; the cap emerges. Starts are ramp-limited (a few per window, which also staggers
   boots and quick gates), and a band eases only once headroom passes its mark by a gap
   (hysteresis), so admission never oscillates.
5. **Every session closes its circuit.** A session has an owner, a purpose, an end condition and its
   own fuse from birth. None is orphaned or unlabeled, one whose purpose is met ends, and a role
   starts only the MCP servers it uses.

And with them:

- **Merit order.** When headroom appears, the waiting job with the highest value per unit of compute
  takes it.
- **Protection coordination.** The smallest breaker trips first: the session's own fuse, then the
  helpers' share, then shedding (lowest merit first, an urgent coder never), and the whole-machine
  fuse last. A larger breaker waits while a smaller one can still act.
- **Congestion.** While finished work is refused at landing in an area, no new coder starts there
  (an urgent fix excepted); generation upstream of a congested line is curtailed at the source.
- **Anti-islanding.** A part acts on shared state only from a current view: the head of main, every
  local file the main checkout has, and a reading younger than its staleness bound.
- **Black start.** When the meter is dark, only the repair seat is admitted, and it boots whatever the
  local files say, so a broken overlay can always be repaired.
- **One standing orchestrator seat at most.** A second seat is refused while one is live, busy or
  blocked; a gone seat is the only one restarted.
- **The meter.** Each window records pressure, power factor (productive sessions over all sessions),
  landings per unit of compute, negawatts (compute reclaimed by ending waste) and curtailment
  (finished work refused at landing).

The bluebooks are `lib/hecks/signalbox/signalbox.bluebook` (Pressure, Admission, Response, Breaker,
Clearance) and `lib/hecks/roundhouse/roundhouse.bluebook` (Session, Reading, Tally), each with its
behaviors written first from the incidents above, and the starting settings in
`lib/hecks/signalbox/signalbox.world`. Each boots alone from its directory, as Triage does.
Roundhouse's policies on Signalbox's events (start what was admitted, rest what was deferred or
shed, finish what was sent home) are the whole contract between the two; they fire once both share
a bus, so the two are model-checked together.

### Where each Delegate aggregate goes

| Delegate aggregate | New home | How |
|---|---|---|
| AgentRun | Roundhouse `Session` | Start, meter, rest, resume, finish, reap; the start carries an admission |
| SessionSweep | Roundhouse `Session.Meter` | Each pass meters each session's draw and activity |
| PlainSession | Roundhouse `Session` | A hand-started session is admitted like any other (owner: a person) |
| SessionCleanup | Roundhouse `Session.Reap` | A finished or blown session is reaped; the worktree is never discarded |
| ReapTurn | deleted | Reaping follows each session's end; no shared turn to take |
| Dispatch | Signalbox `Admission` | Admission by headroom and merit order replace the cap and the fill |
| Roll | deleted | Headroom appearing admits the top waiting job; no roll on events |
| RollSwitch | Signalbox `Admission` | The owner's switch is the main disconnect, a given of admission |
| Idler | deleted | Nothing polls while held back; the pressure signal admits when it eases |
| Ticker | deleted | Per-pull-request tick chains are load with no work; the beat suffices |
| Wake | deleted | Folded into the beat that publishes pressure |
| Heartbeat | Signalbox `Pressure` | The beat publishes the signal from Roundhouse's reading, from current code |
| Machine | Signalbox `Pressure` | One headroom signal replaces the separate load, CPU and memory marks |
| Overload | Signalbox `Pressure` | Overload is the short band |
| Shed | Signalbox `Breaker` | Shedding is the third breaker, lowest merit first, never an urgent coder |
| RedWake | Signalbox `Admission` | A red fix is an urgent coder: admitted in every band, past congestion |
| MergeWindow | Signalbox `Response` | Gates wait their turn under pressure; no window is held open |
| Question | Roundhouse (phase 2) | A question goes to the one standing seat's inbox; it starts no session |
| AnswerDesk | deleted | One seat at most; questions queue to it |

### What it replaces

The settings `work_limit`, `work_cap`, `dispatch_max_load`, `epic_wip_limit`, `load_shed`,
`machine_marks`, `ticks`, `idles` and `heavy_jobs` give way to one headroom target, a floor, a gap, a
ramp step, a helper share and the fuses (`signalbox.world`). `cpu_budget` stays, as the
whole-machine fuse, and trips last. `dispatch_roll_forward` stays as the owner's switch.

## Cut-over

1. **Phase 1 (this record).** The decision, the examples and the two bluebooks, booting alone from
   their own directories. Nothing is wired into the running pipeline and nothing is deleted.
2. **Shadow.** Roundhouse meters every live session and the machine, and Signalbox publishes pressure
   and decides every admission, response and trip beside Delegate, recording what it would have done
   without doing it. The board shows both side by side until they agree, or until each difference is
   shown to be Delegate's fault.
3. **Function by function.** One function at a time moves from Delegate to the new parts, each behind
   its own switch and each read on the live machine after it lands: metering, then the pressure
   signal, then admission, then local response, then protection, then reaping.
4. **Delete.** Once every function has moved and held for a measured day, Delegate's machinery and the
   settings it alone read are deleted.

## Consequences

- The cap is no longer a number anyone sets; it is read off the meter as the sessions that fit.
- A helper costs what it draws. Helper storms stop at the helper share, and a helper cannot start one.
- The order breakers trip in is declared once; the whole-machine fuse stops being the first to act.
- A stale copy refuses to act rather than writes from an old view.
- Shadowing needs Roundhouse's per-session meter (role, item, memory, CPU, last activity), which
  Delegate does not keep today; it is the first piece of phase 2.

## Open items

- **[owner]** The model usage budget: Pressure reads memory as the binding resource on this machine;
  model usage (ADR 0220's daily spend bound) and CPU join the headroom as their own readings. Which one
  binds first in a day is a measurement, not yet made.
- **[owner]** Value per unit of compute for merit order: the tier and epic order stand in for value
  until work is sized (`work-is-sized-and-routed-to-a-model`).
- **[owner]** The person's reserve: 8 GB is a guess at what the owner's own use of the machine needs;
  `the-pipeline-backs-off-when-the-owner-uses-the-machine` would read it live.
- **[owner]** Whether the names Signalbox and Roundhouse stand.
