# i25 — ONE loss function, graphed every tick

Source: inbox `i25` + plan by Agent a584ddb6 on 2026-04-22.

## Choice: dream-theme stability

Picked (c) from i25's three candidates. Rejections:
- **(a) next-utterance prediction** — sparse labels; rewards matching Chris (opposite of creative collaborator)
- **(b) musing coherence** — judge-model drift becomes the thing measured; classic hallucination-amplifier

Why (c): **self-referential** (Miette's own distribution across time, no external judge), **computable from existing state** (`dream_interpretation.heki` + `musing_archive.heki` already accumulate theme labels), **distinguishes learning from running**.

## The metric

```
stability(T) ∈ [0, 1] = 1 - JSD(themes[last 24h], themes[last 7d])
loss = 1 - stability    # lower = better; growing themes persist = good
```

## Score aggregate

`aggregates/score.bluebook`:
- Attributes: `loss` (Float), `loss_name` (String), `window_recent_themes`, `window_baseline_themes`, `cycle`, `computed_at`, `note` ("insufficient_data" / "ok" / "cold_start")
- Command: `ComputeLoss` — emits `Scored`
- Policy: `on "Ticked" trigger "ComputeLoss"` (fires every tick, but gates internally every 60 ticks via script)

## Storage

- `information/score.heki` — singleton latest loss, cheap read for statusline
- `information/score_trajectory.heki` — append-log, capped at 10k rows by `consolidate.sh` sweep

## Review surfaces

1. **Statusline**: `📉 0.23↓` (current loss + arrow vs 1h ago). ~15 LoC in `statusline-command.sh`.
2. **CLI weekly review**: `./score_review.sh` — ASCII sparkline + weekly stats (mean, trend, stddev). ~80 LoC.

## Key decisions

1. **Compute every 60 ticks (1/min)**, not every tick. Shell gates with `[ $((loop_count % 60)) = 0 ]`. Cheap (<50ms computation).
2. **Cold-start period**: first week has no 7-day baseline. Emit `note="cold_start"`, suppress statusline arrow.
3. **Rolling 60-minute median** on the sparkline to dampen tick-level jitter.
4. **Anti-gaming contract**: `score.heki` is **read-only for reporting. NO aggregate may consume it as input.** Enforce via a watcher. Goodhart's law — if minting reads the loss, Miette optimizes for it directly.
5. **Theme normalization** — `dream_interpretation.heki` themes come from Claude and are noisy. Pass through a small stemming step (lowercase, strip stopwords, nearest-match against 30-day vocabulary).

## Calibration plan (before trusting the number)

Hard gate before the loss means anything:

1. **Null baseline** — run 48h with current dream generator. Distribution should be non-trivially bounded from both 0 and 1.
2. **Perturbation test** — swap dream seeds with uniform random theme labels. Loss should spike. If it doesn't, metric is insensitive.
3. **Recurrence test** — inject a fixed theme ("octopus") for a night. Loss should drop over 24h.
4. **Ground truth spot-check** — Chris weekly eyeballs the trajectory vs his memory of what Miette's been dreaming.

All three synthetic tests must pass before week-over-week movement is trusted.

## Commit sequence (8)

1. `feat(score): aggregates + behaviors (no wiring)`
2. `feat(score): compute_loss.sh computes dream-theme stability`
3. `feat(mindstream): wire compute_loss.sh into tick loop every 60 ticks`
4. `feat(score): trajectory append + consolidation cap`
5. `feat(statusline): display current loss + 1h trend arrow`
6. `feat(score): score_review.sh weekly sparkline + stats`
7. `test(score): calibration harness (null + perturbation + recurrence)`
8. `docs: CLAUDE.md note — score.heki is read-only for reporting`

## LoC estimate

~455 total.

## Risks

- Noise (rolling median mitigates)
- Gaming (anti-consumption contract + watcher)
- Theme extraction noise (normalization pass)
- Cold-start false signals (cold_start note + suppressed arrow)
- Storage bloat (capped at 10k rows)

## Antibody note

`compute_loss.sh` and `score_review.sh` are shell. No new Python (i37-compliant). Each commit touching shell gets a specific per-file exemption.
