# Cross-aggregate event chain gaps — Phase 0c inbox

Surfaced while writing `cross_aggregate/*_spec.rb` against the production
bluebooks. Each gap is asserted as a `pending` example in the spec so it
turns green the moment the policy lands.

## gap : chain 3 — `DeepEntered → Heartbeat.RecoverFatigue`

**Status :** no policy declared anywhere in the production tree.

The plan's chain inventory at `hazy-spinning-garden.md` lists this hop,
but no `RecoverFatigueOnDeep` (or equivalent) exists. Today the only
policy reacting to `DeepEntered` is `EndLucidityOnDeep` in
`body/dream/lucid_dream.bluebook`. Heartbeat resets fatigue exclusively
on `WokenUp` via `RecoverHeartbeatOnWake`.

**Most likely resolution :** the plan conflated this with chain 4
(`WokenUp → RecoverFatigue`). Recovering fatigue at every `DeepEntered`
would defeat the per-cycle accumulator's purpose — the body would
re-enter REM with the fatigue ladder reset. Recommend dropping chain 3
from the inventory rather than wiring a policy that contradicts the
fatigue model.

**Spec lock :** `wake_chain_spec.rb` carries TWO assertions :
- `pending` example asserting the post-wired contract (so it lights up
  if a policy lands)
- An always-passing example regression-locking today's behaviour
  (DeepEntered does NOT touch `heartbeat.fatigue`) so an accidental
  policy addition triggers a deliberate decision.

## gap : chain 5 — `WokenUp → WakeMood.SetWakeMood`

**Status :** the `WakeMood` aggregate has NO incoming policy.

`body/sleep/wake_mood.bluebook` header explicitly notes : *"No policies
target this aggregate today."* The production wake-mood signal flows
through a different path :

```
WokenUp
  → ClassifyFullWake / ClassifyPartialWake (sleep_cycle gate)
  → WokeFullSleep | WokePartialSleep
  → Mood.RefreshMood | Mood.SetGroggy   (via mood.bluebook policies)
```

The plan's "WokenUp → WakeMood.SetWakeMood" line names the wrong
aggregate. Two ways forward :

1. **Update the plan** to reflect the production reality (Mood, not
   WakeMood). `wake_chain_spec.rb` already asserts the production
   chain in passing examples for both full + partial sleep cases.
2. **Wire a `SetWakeMoodOnWake` policy** into `wake_mood.bluebook` so
   WakeMood becomes a per-wake snapshot alongside the Mood update —
   useful for the wake report's "what mood did you wake into" record.

The pending example is keyed on path (2) ; if path (1) is chosen,
delete the pending example and update this gaps.md entry.

## gap : cross-bluebook `.behaviors` runner

**Status :** open since `body/cycles/tick.behaviors` and
`body/mindstream/mindstream.behaviors` were narrowed to
single-bluebook dispatch.

The audit calls this out in detail. None of these chain specs use the
`.behaviors` runner — they use `Hecks::Behaviors::BehaviorRuntime`
booted from a composite of all source bluebooks. That works for the
test gate but means the `.behaviors` cluster can't follow `across`
hops (chain 8 in particular). Filed for visibility ; out of scope for
0c.

## not-a-gap : chain 6 (BodyPulse → Awareness.RecordMoment)

The `Awareness.RecordMoment` command takes 13 attributes (the
AwarenessSnapshot value object). The `RecordMomentOnPulse` policy
fires the command, but the snapshot fields land empty in the
BehaviorRuntime cascade because the policy doesn't carry attrs ; the
mindstream daemon supplies them in production.

The spec asserts the **policy edge** (BodyPulse → MomentRecorded
emitted ; awareness aggregate exists), not the 13-attr content. The
13-attr contract belongs to 0g (organ math + dream invariants) and
the Mind PM phase that subsumes mindstream's snapshot work.

This is documented in the audit as :

> Mind constraint : "AwarenessSnapshot must be filled atomically (all
> 13 fields read in one tick) — currently a shell-side workaround for
> missing `with_attrs from_heki:` policy operator"

Worth filing as a separate runtime-gap inbox item if not already :
**policies need a `from_heki:` query operator so policy-driven dispatches
can fill snapshot attrs from the current heki state without a shell
between them.**
