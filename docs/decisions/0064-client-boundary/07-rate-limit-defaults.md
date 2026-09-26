# 07: Rate limit defaults

**Status:** Open (wayfinder ticket) · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

The host has no per-IP rate limit. A client site implements one in its own serverless functions in front of the public write endpoints (registration and newsletter subscribe): a per-IP window, and a proxy-trust rule that reads the client address from a forwarded-for header right to left so a caller cannot spoof it, keyed on a shared secret from the CDN and a trusted-proxy list. A disposable-server smoke test proves the 429.

Decide how the host should provide this:

1. **On or off by default** for public write endpoints.
2. **How it is configured.** The current inputs are named for one CDN. Options: environment variables named for the concept (a proxy authentication header and a trusted-proxy list), or a declaration in the project's world or hecksagon file so it is part of the project's declared shape.
3. **Which routes** are covered, and the default limits and window.
4. **Where it lives** in the host (`server.rs` before routing, or in `web.rs` in front of specific routes).
5. **Whether the smoke test moves with it.**

## Working recommendation (not a decision)

On by default for public write endpoints, so a fresh project is safe. Generic setting names rather than CDN names. Environment variables first, a declaration later if a second setting proves the need. Keep the smoke test with the host code.

## Decision

Not yet resolved.
