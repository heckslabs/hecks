# Driving adapter conception — stress test (session 5, 2026-06-17)

CONCEIVE-ONLY. The category is modelled in
`aggregates/language/grammar/driving.bluebook` (VALID, 0 errors). This doc is
the stress test : every real cadence the body runs — plus the dormant cells
Root §2 must revive — expressed in ONE vocabulary, derived from the hardest
case (circadian's wall-clock segments), not the easiest (heart's interval).

## Why a Driver is NOT a Family
A Family is an impure edge that LEAVES the domain (persisted_by, charged_by) :
the domain composes a call, an Adapter runs it. A Driver is the INVERSE — an
external clock reaching IN to dispatch a command. The grammar already split
these : `driven on <event>` (edge out, Binding) vs `driving on <clock>`
(trigger in, this chapter). Shoehorning cadence into Family would fight the
grammar ; the Driver is its own category, parallel to Family.

## The model (driving.bluebook)
- **Driver** (keyed by name) : `schedule` (one), `root`, `lifespan`,
  `last_fired_at`, `has_many Dispatch`.
- **Schedule** (value-object) : `kind` = interval | cron | clock ; `every`
  (interval) ; `cron` (five-field) ; `poll` (clock re-check period).
- **Dispatch** (ordered child entity) : `command` FQN, `order`, `when`
  (hour-range gate for clock kind ; — for interval/cron).
- Commands : `Declare` (name/schedule/root/lifespan), `AddDispatch` (one
  ordered command), `Fire` (the tick — records last_fired_at, runtime fans
  out the dispatches ; the dispatch IS the act, like Inbox.Check).

## Stress test — every cadence in the vocabulary

| Driver | kind | every / poll | Dispatches (order : command [when]) |
|---|---|---|---|
| heart | interval | 1s | 0:Heart.Beat |
| breath | interval | 4.5s | 0:Breath.Inhale, 1:Breath.Exhale |
| ultradian | interval | 5400s | 0:Ultradian.EnterPeak, 1:Ultradian.EnterTrough |
| inbox | interval | 900s | 0:Inbox.Check |
| process_macrophage | interval | 30s | 0:ProcessMacrophage.Sweep |
| **circadian** | **clock** | poll 60s | 0:MarkDawn [5-6], 1:MarkMorning [7-11], 2:MarkAfternoon [12-16], 3:MarkDusk [17-19], 4:MarkNight [20-4] |
| **fibroblast** (dormant) | interval | <tbd> | 0:Fibroblast.Sweep |
| **no_promises** (dormant) | interval | <tbd> | 0:NoPromisesSweep.Scan, 1:NoPromisesSweep.Verify |

The two shapes that broke a naive `--every`-only model and drove the design :
- **circadian** — not an interval at all : five wall-clock hour-segments, each
  firing its OWN command. Expressed as kind=clock + per-Dispatch `when`.
- **breath / ultradian / no_promises** — several commands, ONE tick, ORDERED.
  Expressed as multiple Dispatches with `order`. (no_promises must scan THEN
  verify — order is load-bearing.)

## The projection (the i262 close — NOT built here)
Each Driver projects to one Procfile member + its .overmind.env CAN_DIE flag :
- interval -> `name: storehouse loop <root> <cmd>[,<cmd>...] --every <every>`
- clock    -> `name: storehouse clock <root> --segment <when>:<cmd> ... --poll <poll>`
The Procfile stops being hand-authored truth and becomes the projection of
the declared Drivers — the same relationship `.world` has to a Family's
Fields. A drift like the `restart_prompt` line (fixtures says one thing,
Procfile another) becomes structurally impossible.

## Scope boundary (don't go fast)
DONE here : the category (driving.bluebook, VALID) + this stress test.
NOT here, each its own card :
1. **The projector** — emit Procfile/.overmind.env from declared Drivers.
   This is what actually closes i262. Specializer/generator work.
2. **Rewiring the live cells** — declaring Drivers for heart/breath/… and
   cutting the boot Procfile over to the projection. MUST prove in isolation
   first ; a cell driven by BOTH its old Procfile loop AND a new Driver is a
   double-fire regression. Live boot Procfile stays untouched until then.
3. **Reviving the dormant cells** (fibroblast, no_promises) — the Root §2
   payoff, lands once the projector exists ; until then they'd still need a
   hand Procfile line, which is the antipattern we're closing, so they WAIT.
4. **Root §1 (BodyPulse cascade)** — unrelated mechanism (synthetic `--emit`,
   not `loop` dispatch) ; its own investigation.

## Open design questions for the projector card
- Where Drivers are DECLARED : a `.drivers` fixture per domain (sibling to
  mindstream.fixtures), or inferred from each hecksagon's `driving on` block?
  The hexagon already has `driving on cron` syntax (cron_adapter.hecksagon) —
  the projector likely reads those blocks, making the hecksagon the source
  and the Driver records the parsed IR.
- Cron-expression evaluation : CronAdapter v1 'fires every tick' ; real
  five-field evaluation is the same follow-up that chapter already names.
