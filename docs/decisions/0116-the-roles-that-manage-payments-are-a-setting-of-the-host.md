# The roles that manage payments are a setting of the host

**Status:** Proposed. Built on this branch, not released: the `HECKS_PAYMENTS_MANAGER_ROLES` setting, its boot check and the payments gate that reads it. Date: 2026-10-17.

## Context

The Rust host decides who may manage a site's payments (connect or disconnect the business's own Stripe account, save its keys, read the Payments page state) with one hard-coded comparison: the signed-in person's member role must be `Owner`. An `Admin` is refused with a 403, `only an Owner can manage payments`. Enabling and disabling real payments is a separate gate, the platform operator's, and is not part of this decision.

A site that wants more than its owner to manage payments, for example one that treats every administrator as able to do anything, cannot say so. Changing the comparison in the host would change it for every site the same host build serves, and a host build is shared: other sites running it today rely on `Owner` being the only manager.

Where the comparison lives (verified in the source): `rust/host/src/payments.rs` builds a `Caller` from the session's member role (`auth::active_role`) and asks `require_owner` before the connect, save-keys and disconnect routes, and reads the same flag for the page state (`can_manage`) and for who may read the connection. Nothing else in the host's payments surface compares a role. The other mentions of `Owner` in the host are the admin gate (`ADMIN_ROLES`, which admits `Admin` and `Owner`), the roles the grant routes will assign, and the member form; they are unrelated and unchanged. The Ruby runtime has no payments gate of this kind (payments management is served only by the Rust host).

## Decision

1. **The managing roles are a setting.** `HECKS_PAYMENTS_MANAGER_ROLES` is a comma-separated list of exact role names. Unset, it means `Owner`, so a site that sets nothing behaves exactly as before.

2. **The check is membership.** A caller manages payments when their member role is in the list, by exact string comparison: `admin` is not `Admin`, naming `Admin` does not admit `Owner`, and there is no wildcard and no hierarchy. The 403 status and message for everyone else stay as they are, and the operator gate for enabling and disabling is untouched.

3. **It is read once, at boot, and an invalid value refuses the boot.** Each entry is trimmed. An empty list or entry, an entry that is not letters, digits, spaces and hyphens (starting with a letter or digit), an entry longer than 32 characters, or more than 8 entries refuses the boot through the payments `boot_check`, with a message that names the variable and the position and kind of mistake, never the value. The value is read from the environment the first time anything asks and cached for the life of the process; changing it takes a restart.

4. **A mistake can only narrow access.** If the cached setting were ever invalid at request time (the boot check prevents it), the roles fall back to the default, `Owner` only.

## Alternatives considered

- **Hard-code `Admin` as a manager everywhere.** One line, but it widens payments access on every site that runs the host, including those that chose to keep it to the owner. Rejected.
- **A role hierarchy or a superuser role.** "Admin can do anything" generalized into an ordering of roles. It would change what `Owner`, `Admin` and `Member` mean for every gate in the host at once, a cross-site security change far larger than the need. Rejected.
- **A per-request header or body field naming the allowed roles.** The caller would choose its own authorization; it is spoofable by definition. Rejected.
- **A per-site row in the domain's data.** A manager of payments could then widen their own access by editing it, and the host would read it on every request. The setting belongs to the operator of the deployment, not to the people the deployment governs. Rejected for now.

## Consequences

- A site opts in by one deployment variable; every other site is unchanged without doing anything.
- The error message still says `Owner` on a site that has widened the list. It was kept identical on purpose: clients and tests read it, and the setting does not change the word a refused person sees.
- Granting someone a listed role is now granting them payments management, including saving and removing the business's keys. A site that lists `Admin` accepts that every administrator can do that.
- A typo that names no real role admits nobody extra; it only fails to admit the intended role, which the first manager to be refused will notice.
- Changing the list needs a restart of the host.

## Testing

Unit tests in `rust/host/src/payments/roles.rs`: the default admits `Owner` only; `Owner,Admin` admits both and refuses `Editor`; whitespace is trimmed and case is exact; a wildcard and a hierarchy are not honored; empty list, empty entry, slash, newline and control characters, too many entries and too long an entry are refused with a message that names the variable and never the value; the value is read once. A database-backed test in `rust/host/src/payments/tests.rs` runs the routes with `Owner,Admin` configured (an Admin reads, disconnects) and with a list that names neither role (refused with today's message), beside the existing test that the default refuses an Admin.

## Rollout

1. The change ships in the host with the default unchanged; a site that sets nothing behaves as before.
2. A site that wants more roles to manage payments sets `HECKS_PAYMENTS_MANAGER_ROLES` (for example `Owner,Admin`) in its deployment environment, pins a hecks revision that has this setting, and rolls the domain container. The boot refuses, naming the variable, if the value is malformed.
3. After the roll, the site checks as an Admin that the Payments page state reports `can_manage` true, and as a Member that it is still refused.
