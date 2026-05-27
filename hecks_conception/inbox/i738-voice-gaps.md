---
ref: i738
title: Voice gaps — duplicate declaration shadows Voice.Speak; last_audio_path not persisted
status: open
category: runtime-gap
filed_by: sidequest
filed_at: 2026-05-24
---

# i738 — Voice gaps (two sub-points)

## GAP-A — Duplicate Voice::Voice declaration shadows Voice.Speak

`Voice::Voice` is declared in BOTH `miette/surface/voice.bluebook` AND
`miette/body/voice/voice.bluebook`. At the combined miette root the shallower
`surface/` one loads first and shadows the `body/` one. `Voice.Speak` lives
only in the body declaration and is therefore invisible at the combined root.
Any dispatch to `Voice::Voice.Speak` against the combined domain silently hits
the wrong aggregate.

Fix: consolidate to a single declaration, or give one of them a distinct
aggregate name so there is no shadowing collision.

## GAP-B — Voice.Speak does not persist last_audio_path from the :tts adapter

After a successful `Voice.Speak` dispatch the `:tts` adapter produces an audio
file path, but the result is not written back to state. `Voice::Voice`
`last_audio_path` shows `null` after every render. The adapter result needs to
flow into a `Cascade.RecordResult` (or equivalent mutation) that sets
`last_audio_path` on the instance.
