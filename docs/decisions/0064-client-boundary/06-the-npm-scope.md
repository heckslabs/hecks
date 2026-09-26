# 06: The npm scope

**Status:** Open (wayfinder ticket) · **Type:** task (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Ticket 05 may publish a package under an `@hecks` scope. Find out whether the org owns that scope and, if not, claim it or pick another. This is manual work that must happen before the publishing half of ticket 05 can be decided.

Known on 2026-09-26: the package name `@hecks/client` returns not found from the registry, so it is unclaimed. Whether the `@hecks` scope itself is owned could not be determined, because `npm` is not logged in on the development machine.

## Checklist for the owner

1. Log in to npm on the development machine (`npm login`).
2. Check the scope: `npm org ls hecks`, or look at the organizations listed on the npmjs.com account.
3. If the scope is owned, note which account publishes, and whether publishing needs a token or two-factor prompt in CI.
4. If it is not owned, either create the organization for the scope (if the name is free) or choose a different scope and say which.
5. Record the outcome below.

## Resolution

Not yet done. Record here what was done and any facts later tickets depend on (the scope name, who can publish, where the publish credential is kept).
