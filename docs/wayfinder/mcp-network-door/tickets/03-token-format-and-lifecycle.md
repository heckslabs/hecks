---
type: grilling
status: closed
blocked_by: [01-where-principals-live]
claimed_by:
---

# Token format and lifecycle

## Question

Decide what a caller presents: a signed token like the host's HMAC-signed session cookie
(`rust/host/src/auth.rs`), or something else. Then decide how a token is minted and by whom, how
long it lives, how it is revoked before it expires, how the signing key is held and rotated, and
what the token carries (the principal, an audience, an expiry, possibly a role ceiling). A shared
static secret is accepted by ADR 0062 only for a single operator with no per-principal audit, so
say whether that case is in or out of scope.

## Answer

Decided 2026-09-27: a signed, short-lived bearer token. An HMAC-signed token naming the principal,
an audience and an expiry, in the same family as the host's signed session cookie; the key is held
in the platform's secrets store and rotated; revocation is by expiry plus a deny list. Recorded in
[ADR 0077](../../../decisions/0077-the-network-door-speaks-http-and-takes-a-signed-short-lived-token.md).
The exact claims, the rotation interval and where the deny list lives are left to the build.
