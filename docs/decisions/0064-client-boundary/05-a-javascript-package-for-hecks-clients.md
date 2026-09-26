# 05: A JavaScript package for Hecks clients

**Status:** Open (wayfinder ticket) · **Type:** grilling (HITL) · **Blocked by:** none (the publishing half waits on ticket 06) · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

The client site carries three copies of the code that speaks the host's protocol (`text`, `whole`, `instancesOf`, `Answer`), with the domain name and service URL hardcoded, plus other generic pieces: a fetch wrapper with retry and a last-good fallback, a parser and client for entering payment keys, and the receiver for the single-sign-on token the host mints. Future clients will need the same pieces. Hecks has no JavaScript package, toolchain or publish flow today.

1. **Does Hecks ship a JS package?** Options: (a) in this repository, (b) a separate repository or package owned by the org, (c) a copy kept inside each client with no package.
2. **What goes in it?** Protocol client only; plus the generic helpers; plus a CMS-adapter package for future sites using the same CMS.
3. **How is it versioned and tested?** Tied to the gem version; a CI check that runs its protocol tests against the current host.
4. **Where is it published?** Public registry under an org scope, or installs from a git tag. Depends on ticket 06.

## Working recommendation (not a decision)

Ship it from this repository as `packages/hecks-client/`, protocol client first, with the fetch wrapper, payment-key client and token receiver as follow-ups. Version it with the gem and run its tests against the current host in CI. Do not build a CMS-adapter package until a second site exists, because one consumer cannot tell you its shape. Publish to the registry if the scope is owned, otherwise install from a git tag.

## Decision

Not yet resolved.
