# A client downloads the host hecks already built

**Status:** Proposed. Built: the `PrebuiltBinary` rows, `Hecks::RustBuild::PrebuiltBinary`, the download in `build_host` and the
generated `publish-host.yml`. Date: 2026-10-16.

## Context

`hecks build.build_host` compiles `rust/host` for every client: a Lifeadelics CI run, a domain image, a laptop. The host does not
contain the client's domain (the domain is a `.wasm` and an `.ir.json` loaded at run time, and `rust/host` has no path dependency
on `rust`), so every client compiles the same bytes from the same release. A cold build compiles wasmtime and the AWS SDK and took
about twelve minutes of a fourteen-minute Lifeadelics CI run; a warm one still took three. The warm path leans on `actions/cache`,
which is scoped to a branch (a PR's cache is invisible to `main`, and the reverse needs `main` to have saved it first) and is
evicted after seven days unused, so a miss is routine.

## Decision

1. **The binaries hecks publishes are `PrebuiltBinary` rows of the Vocabulary chapter.** A row names the crate, the Cargo binary,
   the target and the runner image it is built on. The first row is `host`: `rust/host`, `bootstrap`, `x86_64-unknown-linux-gnu`,
   `ubuntu-24.04`.
2. **A release is named by what went into it.** `host-<key>` where the key is a hash of every file of the crate that goes into the
   build (paths and bytes, without `target/`, `tests/` and `.gitignore`). The same bytes are the same release whichever commit they
   come from, and a commit that does not touch the crate publishes nothing.
3. **hecks publishes it, generated from the rows.** `hecks regeneration_run.project_lanes` writes `publish-<name>.yml` with the
   other lane workflows. After a push to `main` that touches the crate it builds on the row's runner and creates the release with
   the binary and its `.sha256`, unless the key already has one. The runner is pinned, never `-latest`, because the binary links
   that image's glibc.
4. **`build_host` downloads before it compiles.** It computes the key from the host crate it was going to build, fetches the release
   and the published hash, and uses the binary only if its bytes hash to it. Any other outcome (no release yet, no network, a
   different target, a hash that does not match) is a miss and the host is compiled as before. `HECKS_PREBUILT=off` turns the
   download off. A client needs no change to benefit; it only has to be on a hecks that carries this.
5. **The domain's own wasm is still built by the client.** It depends on the client's bluebook.

## Consequences

- A client on the published target stops compiling wasmtime. What remains is the domain's `.wasm` and `.ir.json`.
- A hecks commit that changes `rust/host` is not downloadable by a client until its release is published, a few minutes after the
  push; a client that pins such a commit in that window compiles, exactly as it does today.
- The binary is trusted on a hash published beside it by the same repository's own workflow, over TLS. Anyone who can create a
  release in `heckslabs/hecks` can publish a host, so the repository's release permissions are now part of what a client trusts.
- A new target (for example `aarch64-unknown-linux-gnu`) is a new row, not a new workflow.
- No bluebook command or aggregate was added: the rows are reference data like `Lane`, and the publishing is a workflow, not a
  fact about a domain.
