# 06: The npm scope

**Status:** Resolved 2026-09-26 · **Type:** task (HITL) · **Blocked by:** none · **Claimed by:** Claude (session 2026-09-26), with the owner signed in on the npm website
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

Done on 2026-09-26.

- **Before:** neither an organization nor a user named `hecks` existed on npm (both pages answered "Scope not found"), and `@hecks/client` was unclaimed. `npm login` from the development shell did not take (no token was stored), so the check and the creation were done through the owner's signed-in browser session.
- **What was done:** with the owner's approval, the free organization `hecks` (public packages only) was created from the owner's npm account. Its name is permanent. No member was invited and nothing was published.
- **Facts later work depends on:**
  - The scope is `@hecks`, so the package is `@hecks/client`. The owner's account is the organization's owner.
  - Publishing is still a separate step: `npm publish --access public` from `packages/hecks-client`, after a Hecks release whose version matches the package. npm is restricting tokens that bypass two-factor authentication (account changes from August 2026, direct publishing from January 2027), so plan for a two-factor prompt or a trusted-publishing setup rather than a long-lived token.
  - Until the first publish, installs keep using the vendored tarball or a git tag.

- **Outcome (2026-09-27):** `@hecks/client` 2.7.0 was published by hand, once, with a short-lived token that bypassed two-factor. Later releases publish from CI through npm trusted publishing (the `heckslabs/hecks` repository, workflow `publish-client.yml`), so no long-lived token exists and the account keeps its passkey. The client site installs the package from npm instead of a vendored tarball.
