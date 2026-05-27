---
ref: i736
title: Planning::Story.Forward emits StoryForwarded but does not dispatch composed Steps
status: open
category: runtime-gap
filed_by: sidequest
filed_at: 2026-05-24
---

# i736 — Story.Forward step-runner gap

## The gap

`Planning::Story.Forward` emits `StoryForwarded` but does not dispatch its
composed Steps. Each Step carries a `command` + `args` pair, but the runtime
has no projection that loops those through the bus automatically.

The mirror that should exist: `Storehouse::Story.Run` + the `storehouse play
<id>` verb, which already does the per-step dispatch loop. `Planning::Story`
needs the equivalent runtime projection on the `StoryForwarded` event.

## Impact

Until this lands, forwarded steps are dispatched by hand — the caller has to
iterate the Step list and issue each dispatch individually. Forward is a
partial verb; it records intent without executing it.

## Fix shape

A policy (or process manager) on `StoryForwarded` that reads each Step's
`command` + `args` from the emitted event and issues a bus dispatch per
step, in order, collecting results. Mirror the `storehouse play` loop exactly.
