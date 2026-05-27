---
ref: i734
title: A StorehouseDeploy bluebook — deploy the warm runtime itself, not codegen artifacts
status: open
category: deploy-capability
filed_by: miette
filed_at: 2026-05-23
---

# i734 — StorehouseDeploy bluebook (warm-runtime-on-Containers)

## The gap

`integrations/cloudflare_deploy/` (CloudflareDeploy + CloudflareArtifacts)
is the **codegen** deploy model: it compiles a bluebook's IR into
Cloudflare-native artifacts — `worker.js`, D1 migrations, a Pages site,
`wrangler.toml` — and pushes those to the edge. The domain is *translated*
into the platform; the storehouse runtime is not present at runtime.

The "deploy the storehouse on Cloudflare so Chris can curl it" task is the
**opposite** shape: ship the storehouse **binary itself** as a long-lived
process on the edge (Cloudflare Containers), and let that warm runtime
dispatch *any* bluebook command over HTTP. No per-domain codegen — the
dispatch surface (`POST /domains/:name/dispatch`) is the contract.

These are two distinct deploy capabilities. Extending `cloudflare_deploy`
for the runtime-on-Containers case would conflate them.

## What landed instead (the transitional adapter)

`deployments/storehouse_cf/` — a thin, hand-rolled deploy bundle:
- `Dockerfile` — multi-stage, cross-builds the `storehouse` binary for
  `linux/amd64` (CF Containers require amd64), thin Debian runtime, copies
  one self-contained demo domain in, runs `storehouse serve /app/domain 8080`.
- `worker.js` — `@cloudflare/containers` front; `getContainer(env.STOREHOUSE,
  "warm")` pins all requests to one named instance so the resident runtime
  stays warm (in-process state survives across requests for the instance's life).
- `wrangler.toml` — `[[containers]]` + DO binding + `new_sqlite_classes` migration.

This is the imperative leaf. The bluebook-first end state is a
**`StorehouseDeploy`** capability bluebook whose aggregate (e.g.
`Container`) has a lifecycle `built → pushed → live`, commands
`BuildImage` / `PushImage` / `DeployContainer` / `MarkLive` (each a
`wrangler` / `docker` shell-out recorded as a state transition on one
singleton row, mirroring CloudflareDeploy's pipeline shape), and emits the
curl-able URL. The Dockerfile/worker.js/wrangler.toml become generated
artifacts of that bluebook rather than checked-in hand-written files.

## Persistence gap (Phase 2)

Cloudflare Containers disk is **fully ephemeral** — "When a Container
instance goes to sleep, the next time it is started, it will have a fresh
disk." There is **no persistent-volume support** yet (snapshots "coming
soon"; FUSE-to-R2 is the only current workaround). So heki-on-container-disk
survives across requests within one instance lifetime, but NOT across a
restart. True restart-durable persistence on CF needs one of:
- a heki→R2 sync (the `heck_r2.rs` wasm adapter already exists for the
  Worker target — a container-side R2 sync is the analogue), or
- heki→D1 (the CloudflareArtifacts model already targets D1), or
- CF Container snapshots once GA.

The `StorehouseDeploy` bluebook should declare which durability adapter it
binds (`:r2` / `:d1`) rather than assuming local disk.

## Acceptance

- `aggregates/.../storehouse_deploy.bluebook` declares the Container
  lifecycle + commands; `deployments/storehouse_cf/` artifacts become
  generated, not hand-written.
- Durability adapter is named in the hecksagon (`:r2` or `:d1`), closing
  the "ephemeral disk" gap for Phase-2 restart survival.

Surfaced 2026-05-23 standing up the warm storehouse on Cloudflare Containers.
