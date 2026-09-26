# 02: Is commerce a Hecks capability or a client feature?

**Status:** Open (wayfinder ticket) · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

The Rust host compiles in payments (a tenant's Stripe keys, webhook and checkout), a mailer, newsletter subscribe and send, and registrations, about 4,400 lines in all. They are wired as a fixed chain of route branches in `rust/host/src/web.rs`. The capability registry (`lib/hecks/bluebook/capabilities.rb`) already defines `payments`, `registrations`, `payment_connection` and `newsletter`. The host is the only production implementation, and the client site's own Ruby copies are being retired.

Decide what these are:

- **A. A Hecks capability, generalized in place.** Fix the hardcoded names and settings; keep the code where it is.
- **B. A Hecks capability, isolated.** Move it into its own crate behind a route-extension trait and a Cargo feature, still shipped by Hecks.
- **C. A client feature.** Make the host a library and move the code into the client repo.

The answer decides the de-hardcoding work, whether the seat rule and payment-key handling are exposed from the host, and whether the client's duplicate admin pages are retired.

## Working recommendation (not a decision)

A. The registry treats these as Hecks concepts, the host is the sole implementation, and other consumers (the seat rule, the payment-key client, the newsletter import) all want the host's API. B costs a large refactor of `web.rs` for isolation alone. Revisit B if a second consumer or a lean-host build appears.

## Decision

Not yet resolved.
