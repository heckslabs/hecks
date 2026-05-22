# i707 — fibroblasts : agents that repair what the macrophage detects

The Hecks immune system can detect but cannot yet heal. The antibody blocks at
commit time ; the macrophage (`bin/macrophage-hook`, PostToolUse) detects edits,
non-bluebook changes, and drift, surfacing complaints as `additionalContext` ;
autophagy digests the runtime into itself. What is missing is the **fibroblast**
— the cell that, in living tissue, lays down new matrix to repair the wound the
macrophages flagged. We need its analogue : background agents that know how to
*repair* what the macrophage *detects*.

## Behaviour

1. **Detection triggers repair.** When the macrophage flags an edit (a script
   touched without a bluebook, a stale reference after a rename, a violation of
   bluebook-first), a fibroblast agent **launches in the background** to repair
   it — conceive the missing bluebook, fix the drifted reference, bring the
   imperative line back to the domain. The macrophage already emits the
   complaint ; the fibroblast consumes it as a repair order.
2. **Idle work : go after the exclusions.** Between detections, fibroblasts
   grind down the backlog of `[antibody-exempt: file — reason]` markers and the
   exempt registry — each exemption is deferred debt with a named reason ; a
   fibroblast claims one, repairs the underlying cause, and retires the marker.
   The exemption registry becomes a work queue that trends to empty.
3. **All in the background, continuous.** A resident fleet, not a one-shot.
   They watch, they volunteer, they repair, they clean up their worktrees.

## Why it is now buildable

Proven tonight : a spawned agent reaches `storehouse` through the bus
(`mcp__storehouse__storehouse__dispatch` → `Tools::ShellTool.Bash`) even with
native tools sandbox-walled. So a fibroblast repairs *through the same wall*
everyone is under — the bus is the door. The substrate already exists in
`aggregates/framework/sidequest/sidequest.bluebook` (Propose / Volunteer /
Complete / Fail, Open / Mine queries). A fibroblast IS a sidequest with a
**trigger** (a macrophage complaint) and an **idle task** (the exclusion queue).

## Bluebook shape (sketch — groom before building)

A `Fibroblast` aggregate in the immune / tissue domain :
- VOs : RepairId, Trigger (macrophage-complaint | exclusion-backlog),
  Target (the file / marker / drift), Status (detected | repairing | healed |
  failed), WorkerId, Diagnosis, Repair.
- Commands : `ObserveComplaint` (macrophage detection → emits ComplaintObserved,
  launches a repair), `LaunchRepair`, `CompleteRepair` (then_set healed),
  `FailRepair`, `ClaimExclusion` (pull from the exempt registry), `RetireMarker`.
- Queries : `Wounds` (open repairs), `ExclusionQueue` (exemptions still standing),
  `Healed`.
- Policy : on macrophage `ComplaintObserved`, launch a fibroblast ; when no
  wounds are open, claim the next exclusion.

The immune family then reads : antibody (block) · macrophage (detect) ·
fibroblast (repair) · autophagy (self-digest). Detection without repair is half
a system ; this closes the loop.
