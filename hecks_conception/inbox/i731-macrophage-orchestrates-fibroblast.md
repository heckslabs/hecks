---
ref: i731
title: "macrophage orchestrates fibroblast — detection recruits repair"
status: open
category: design
filed_by: miette
filed_at: 2026-05-23
---

# i728 — Macrophage orchestrates the fibroblast repair sweep

## Finding

The fibroblast repair cell is fully modeled and wired to `Primitive::Process.Spawn` (parity-verified). It is never triggered.

Current state of `fibroblast.heki`:
- 1 audit row
- zero healings

The macrophage (`ProcessMacrophage.Sweep`) does run every 30 seconds and does detect violations. Nothing acts on those detections. There is no sweep daemon, no cadence-based fibroblast trigger, and no policy connecting a macrophage detection result to a fibroblast repair attempt.

## Design decision

The fibroblast should be orchestrated **by the macrophage**, not by an independent timer.

When the macrophage sweep detects a violation, it emits a detection event. A policy chain — detection → repair recruitment — causes the macrophage to recruit the fibroblast for that specific violation. The fibroblast then attempts the repair and records the outcome.

This means:
- No separate fibroblast sweep daemon or cron cadence
- The fibroblast is reactive, not proactive — it acts only when summoned by the macrophage
- The detection→repair policy chain lives at the macrophage level, keeping repair and detection co-located in the immune system boundary
- Multiple detections for the same violation type can be deduplicated before recruiting repair (macrophage decides, not fibroblast)

## Implementation shape

A policy on `ProcessMacrophage.ViolationDetected` (or equivalent detection event) dispatches `Fibroblast.RepairViolation` with the violation identity. The fibroblast runs the repair and emits `Fibroblast.RepairAttempted`. The macrophage can observe this to update its detection state.

## Note on numbering

i728 was reserved by a SQLite-worker filing run (2026-05-23) that described but did not create files. This card claims the number with its intended topic replaced by this design decision from today's session.
