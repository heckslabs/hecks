---
type: grilling
status: open
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
