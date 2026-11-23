# A promotion to stable rolls by policy, guarded per service, with no deploy-manager role

**Status:** Accepted. Date: 2026-11-23. Settled with the owner in the deploy-manager grilling of
2026-11-18. The plan was reviewed by the architect (verdict sound with changes). Builds on
[0105](0105-a-box-roll-names-its-restore-point-before-it-changes-anything.md) and
[0233](0233-roles-exist-where-they-limit-or-read-independently.md).

## Context

A promotion moves `stable`; a service then has to roll to the promoted commit. The epics
`deploy-manager-role` and `deploy-recommendations` planned a role for it. 0233 sets the test for a role:
it exists only where it limits what an agent can touch or gives a read not anchored on the author's work.
A deploy manager does neither: the roll is a fixed sequence of reads and checks, and a sequence is a policy.

## Decision

Each decision ends with where the code stands today.

1. **There is no `deploy_manager` role.** Rolling is a policy. *Code: none exists; nothing to retire.*
2. **A promotion to `stable` rolls each service through `service_roll.run!` by policy.**
   *Code: `StableRoll` in `lib/hecks/deploy/bluebook/deploy.bluebook` begins a roll, runs it through
   `ServiceRoll.Run` and its smoke, and ends rolled or stopped.*
3. **The roll reads the live box first and stops with an impediment when the box is not what `stable`
   expects.** *Code: the box is read and `StableRoll` stops when a command is still running, no restore point
   is named, or the service is not running. It does not yet compare the box's commit with
   `promoted_commit`: that comparison is new work.*
4. **The roll names its restore point first (0105).** *Code: done in `StableRoll` and `deploy-box.sh`.*
5. **Every roll runs the service's smoke check and restores by itself on red,** filing an impediment
   (`StallWatch.impediments`) that the scrum master turns into a help-wanted record (the `member` line in
   `agents.bluebook`). *Code: the smoke runs and a red smoke flags the roll. Nothing restores: `StableRoll`
   has no restore command, and the comment above it says a person decides. The automatic restore is new
   work, and it replaces that comment.*
6. **Each service has an auto-roll switch, a committed row shown on the feature page:** on for the owner's
   own services, off for each client site until the owner turns it on. *Code: `StableRoll.auto_roll` and
   `HoldStableRollWhenAutoRollIsOff` hold a roll when the switch is off, but `Request` takes the switch as
   a plain input. No world file or aggregate holds the per-service row, and the feature page does not show
   it: new work.*
7. **A switched-off service's ready roll waits as one line on Waiting-on-you.** *Code: the held roll is
   readable (the `Held` query), but nothing feeds it to the panel, which today shows only what the
   delegate's needs-an-answer route feeds it: new work.*

## Set aside

- **The `deploy_manager` role** (epic `deploy-manager-role`): it fails 0233's test. ADR 0195 mentions a
  deploy manager board as filed; the set-aside epics cover it.
- **A short deploy-manager session for failures:** a failure is an impediment, and the scrum master already
  turns impediments into help-wanted records.
- **A recommend-then-auto-confirm step:** a recommendation the policy confirms by itself is the policy
  with a delay.
- **The owner confirming every roll** (epics `deploy-manager-role` and `deploy-recommendations`): it makes
  the owner the bottleneck for every service, including the owner's own. The per-service switch keeps the
  owner's confirmation where it matters, on client sites.
- **`stable` alone as the guard:** a promotion says the commit is good, not that this box is ready for it.
- **A smoke check with no per-service switch:** the smoke check is every roll's, but whether a roll
  starts without the owner is per service.

## Open items

Follow-on work items are cut from this record, not created by it.

1. **Compare the box's commit with `promoted_commit`** and stop with an impediment on a difference.
2. **Restore by itself on a red smoke,** file the impediment, and update the comment above `StableRoll`
   that says nothing restores.
3. **The per-service auto-roll row:** a committed row for each service, on for the owner's services and
   off for client sites, shown on the feature page and read by `StableRoll.Request`.
4. **Feed the held rolls to Waiting-on-you** as one line each.
