# Commerce and the bluebook registry maintainer tooling move to the platform

**Status:** Accepted in part: the seam (step 4a) shipped in 3.9.0 and `boot::run` is on main; the moves are open. Date: 2026-10-06. Supersedes [0064/02](0064-client-boundary/02-is-commerce-a-hecks-capability.md) (commerce stays in Hecks) and the registry half of [0064/08](0064-client-boundary/08-platform-tooling-that-belongs-in-hecks.md).

## Context

0064/02 kept payments, checkout, the mailer, newsletter and registrations in the Rust host, "revisit if a second consumer or a lean-host build appears". 0064/08 moved the bluebook vendoring tooling into Hecks. The owner has since decided that both are product concerns: Hecks is the language and runtime, and the platform (`embryonaut_platform`) owns what is built on it.

## Decision

1. **Commerce moves to the platform.** `payments*`, `checkout.rs`, `resend.rs`, `web/registrations.rs`, `web/registration_receipt*` and `web/newsletter*` in `rust/host`, the payments and registrations fixtures, the mock Stripe adapter, and the payments surface of `@hecks/client`.
2. **The registry maintainer half moves** to `embryonaut_bluebooks`: `Registry`, `Manifest`, `Lock`, `Shape` and the custodian `Registry` aggregate.
3. **Stays in Hecks:** `attaches ..., from: :vendor`, `Hecks::Vendoring`, the Rust vendor path resolution, the `:vendored` corpus kind, and the vendoring demo (the Rust-conformance proof of ADR 0058). Also the capability registry (`lib/hecks/bluebook/capabilities.rb`), the provider lookups and the `ir.json` binding keys: the platform and the bluebooks repo both rely on them.
4. **Order.** (a) Hecks gets the seam 0064/02 rejected: `rust/host` becomes a library plus a binary, with a route-registration trait covering routes, rate-limit forms, boot checks and secret fetch. (b) The platform moves off hecks 2.7 to the current release and gains a Cargo workspace and CI with Postgres-backed tests. (c) Commerce moves in layers: `resend` and `checkout`, then `payments` and `newsletter`, then `registrations`. (d) The shared `checkout_fixture` splits: a neutral fixture stays, the payments one moves. (e) The `@hecks/client` payments exports go last, as a semver-major change.
5. Release timing stays with the owner. No step publishes or tags.

## Consequences

- Hecks loses about 5,800 lines of host code and gains a stable host extension API that it must keep compatible.
- The platform takes on a Rust build, toolchain and CI.
- The release lockstep (gem, `@hecks/client`, `rust/host/HECKS_RELEASE`) must be revisited when the host becomes a library.

## Progress and Open

Done: `rust/host` is a library plus a binary; `HostExtension` carries guest routes, account routes, rate rules, a boot check and boot secrets; the commerce readers live in `commerce_ir.rs`; the boot sequence is `rust_host::boot::run`. The platform has a `host/` crate (`embryonaut_host`) that depends on `rust_host`, installs the commerce extension and boots, and builds.

Open, and why each is not done yet:

1. **How a client deploy builds a host that is not hecks's own.** Generated `AwsBox` and `AwsFargate` deploys build `rust/host` from the hecks gem (`cd $(ROOT)/rust/host && cargo build`). Commerce moving to the platform means a client site's host must be `embryonaut_host`, so the deploy generator needs a setting that names a host crate (a path or a git source) and builds that instead. Until then, moving commerce out of hecks would drop it from every client deploy, so no commerce module has moved. This is the gate for steps 4c to 4e.
2. **`checkout_fixture`.** Host tests use it as a generic wasm fixture (the presentation, console-settings and lineage tests). A neutral replacement has to exist before the payments half can leave.
3. **The registry-maintainer half to `embryonaut_bluebooks`.** `package.verify` and `Git::Pin` in hecks call `Registry`, `Manifest`, `Lock` and `Shape`, so moving them makes hecks depend on the registry or duplicates them. Needs a decision on which side owns the contract.
4. **`@hecks/client` payments exports.** Removing them is a semver-major change.
5. **Resend tracking webhook** (a peer branch) is written against the old routing and should land as a `HostExtension` route, not in `web.rs`.
