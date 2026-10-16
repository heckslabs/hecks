# A thin, movable platform sign-in extension in the host

**Status:** Proposed. Built: `rust/host/src/platform_signin/` (the verifier, the flow, the extension), off unless
`PLATFORM_SIGNIN` is set. Date: 2026-10-16.

## Context

A site can let a platform issuer sign its people in, instead of running its own Google client. The issuer signs a short-lived
EdDSA token for the site, and the site must verify it, map it to one of its own members and mint its usual account cookie.

That relying-site code has to live somewhere a site can run. A client site builds hecks's own `rust/host` (`build.build_host`,
ADR 0110): the host crate the platform ships as `host_crate` exists only for the Fargate and Lambda deploy kinds, so a site on
an `AwsBox` cannot receive code placed there without new Hecks tooling. [ADR 0094](0094-commerce-and-the-bluebook-registry-move-to-the-platform.md)
says product concerns belong in the platform and Hecks stays the language and runtime. The two pull in opposite directions.

## Decision

1. **The relying side is a small extension in `rust/host`**, `PlatformSignin`, installed through the `HostExtension` seam
   (`default_extensions`). It is named generically (site, issuer, console) and knows nothing of any one site.
2. **It is off by default.** With `PLATFORM_SIGNIN` unset or empty no extension is installed, no route is claimed and the host
   answers exactly as before. Unsetting the one variable is the rollback.
3. **Two modes.** `alongside` adds `GET /auth/platform` (start) and `GET /auth/platform/callback`; `/auth/google` is untouched.
   `default` also sends `GET /auth/google` to the issuer, and `GET /auth/google?via=google` is the break-glass to the existing
   Google flow. Any other value refuses the boot.
4. **Settings are read once, from an explicit map**, and validated before anything runs: `PLATFORM_SIGNIN`,
   `PLATFORM_ISSUER_URL`, `PLATFORM_JWKS_URL` (optional, defaults to `<issuer>/.well-known/jwks.json`), `PLATFORM_SITE_ID` and
   `PLATFORM_ENVIRONMENT`, together with the host's `SITE_URL` (https), `SESSION_SECRET` and `HECKS_SERVE_MODE=1`. A missing or
   malformed setting refuses the boot with a message naming the variable and the kind of mistake, never the value. The callback and
   every redirect derive from these settings only, never from a request header.
5. **The flow is the issuer's contract.** Start writes the `__Host-signin` cookie (`<nonce>.<state>`, `Secure; HttpOnly;
   SameSite=Lax; Path=/`, no `Domain`, ten minutes) and redirects. The callback always deletes the cookie, checks it against the
   query state in constant time, verifies the token (the verifier of the previous step: pinned issuer, site and environment,
   single-use `jti`, short life), and only then maps the person. Failures are small static pages with a stable code and no redirect.
6. **Mapping never creates a member.** The token's `(idp_iss, idp_sub)` resolves to an identity linked to a member; otherwise an
   existing, enabled member with a role and no identity is linked by email; otherwise the sign-in is refused as `google_unlinked`.
   There is no sign-in by email alone, because the identity pin is what protects against a recycled address. A role difference
   between the token and the member is logged and not written.
7. **The key set is fetched with the client the host already uses for Google** (`reqwest`): five second timeout, no redirects,
   status 200 only, 64 KiB cap, and a cache that honours `Cache-Control: max-age` between 30 seconds and one hour.
8. **The cookie `Secure` flag follows the site address.** The account cookie's flags come from `GOOGLE_REDIRECT_URI` when it is
   set, as before, and otherwise from `SITE_URL`, so a site that stops setting the Google variables still sets `Secure`.
9. **The extension is built to move.** It touches the rest of the host through `HostExtension`, one flags function and
   `default_extensions`; moving it to the platform later means changing which list installs it.

## Consequences

- The host gains a token verifier, a key set fetch and a sign-in flow, all inert until `PLATFORM_SIGNIN` is set. A site adopts it by
  environment alone: no bluebook change, no new secret (the issuer's public key comes from its key set address).
- The record of used token identifiers lives in the process. A restart forgets it (a replay window of at most 90 seconds), and a
  second instance would not share it, so the settings refuse any process that is not the single long-lived server.
- Sign-in over plain http is not supported: `__Host-` cookies need `Secure`, so a local run needs an https front or the issuer's
  local stand-in behind one.
- `GET /auth/platform` and its callback are rate limited per client; `/auth/google`, in either mode, is not, as before.
- Nothing is lost if the extension is later moved: the routes, the variables and the cookie are the contract, not the crate.
- If the platform ever publishes a host that includes this, the same variables select it; the extension here is then deleted.
