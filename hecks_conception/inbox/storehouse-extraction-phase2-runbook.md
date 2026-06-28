# Storehouse extraction — Phase 2 runbook (the physical move)

**Prereq met:** Phase 1 complete + pushed (commits e32d95998 … 925c4dc8a). The engine
has ZERO compile-time `hecks_conception` coupling and resolves the conception at
runtime via `HECKS_CONCEPTION_DIR` (already set in .mcp.json). `git-filter-repo` is
installed (`/opt/homebrew/bin/git-filter-repo`). Repo decided: `github.com/chrisyoung/storehouse`, **private**.

**Layout decision (important):** the new repo PRESERVES the `rust/` + `codegen/` sibling
structure (i.e. `storehouse/rust/`, `storehouse/codegen/`). This keeps
`wasm_worker.rs`'s `include_str!("../../../codegen/wasm_worker_shape/...")` valid with
NO path fix — `storehouse/rust/src/specializer/ -> ../../../codegen` = `storehouse/codegen`,
same depth as today. (Flattening rust/ to the repo root is a conventional-but-optional
follow-up that WOULD require fixing that one include_str path.)

---

## Step 1 — mint the storehouse repo from a filtered clone (history preserved)
```sh
cd ~/Projects
git clone hecks storehouse-extract        # local clone (fast, no network)
cd storehouse-extract
# Keep ONLY the engine's paths, rewriting history to just those:
git filter-repo --path rust/ --path codegen/
#   (Dockerfile.storehouse is NOT included — see Step 5, it's deploy-side.)
# Result: a repo whose entire history is rust/ + codegen/ only.
```
Verify: `git log --oneline | wc -l` (nonzero), `ls` shows only `rust/ codegen/`,
`cd rust && HECKS_CONCEPTION_DIR=~/Projects/hecks/hecks_conception cargo test --release`
green (the engine builds + tests standalone, conception via env).

## Step 2 — create the GitHub repo + push (NEEDS CHRIS: gh auth)
```sh
gh repo create chrisyoung/storehouse --private --source=. --remote=origin --push
#   or: create empty private repo in the UI, then:
#   git remote add origin git@github.com:chrisyoung/storehouse.git && git push -u origin main
mv ~/Projects/storehouse-extract ~/Projects/storehouse   # final home (sibling of hecks)
```

## Step 3 — install the binary from the new home
```sh
cd ~/Projects/storehouse/rust && cargo build --release
ln -sf ~/Projects/storehouse/rust/target/release/storehouse ~/.local/bin/storehouse
#   (was -> ~/Projects/hecks/rust/target/release/storehouse)
```

## Step 4 — remove the engine from hecks (a normal commit, NOT filter-repo)
```sh
cd ~/Projects/hecks
git rm -r rust/ codegen/
git commit -m "refactor(extract): remove the storehouse engine (rust/ + codegen/) — now github.com/chrisyoung/storehouse"
```

## Step 5 — rewire consumers (exact edits)
**Cargo lib path-deps** (sibling `~/Projects/storehouse/rust`):
- `~/Projects/hecks/summer/Cargo.toml:8` — `path = "../rust"` -> `path = "../../storehouse/rust"`
- `~/Projects/hecks/deployments/daily_musing_cf/worker/Cargo.toml:20` — `path = "../../../rust"` -> `path = "../../../../storehouse/rust"`
- `~/Projects/bin-buddy/worker/Cargo.toml:20` — `path = "../../hecks/rust"` -> `path = "../../storehouse/rust"`

**Binary path** (point at the new home / installed binary):
- `~/Projects/hecks/.mcp.json` — `STOREHOUSE_BIN` -> `/Users/christopheryoung/Projects/storehouse/rust/target/release/storehouse` (or `~/.local/bin/storehouse`)
- `tooling/git-hooks/pre-push:40` — `STOREHOUSE="$MAIN_REPO/rust/target/release/storehouse"` -> `STOREHOUSE="$MAIN_REPO/../storehouse/rust/target/release/storehouse"`
- `tooling/git-hooks/pre-commit:50` — `STOREHOUSE="$REPO/rust/target/release/storehouse"` -> `STOREHOUSE="$REPO/../storehouse/rust/target/release/storehouse"`
- `~/.local/bin/storehouse` symlink — retargeted in Step 3.

**Dockerfile.storehouse** — DECISION NEEDED. It `COPY`s BOTH `rust/target/release/storehouse` AND `hecks_conception/aggregates` + `catalog` into the image (binary + conception = a sealed deploy). It is therefore a DEPLOY artifact, not a pure-engine one. Recommendation: it STAYS in hecks (the deploy side), with its `COPY rust/target/release/storehouse` line repointed to a built sibling binary (or a multi-stage build that `cargo build`s `../storehouse/rust`). Do NOT move it to the storehouse repo — that repo has no conception to copy.

## Step 6 — storehouse gets its OWN gate (mirror miette's)
Copy `~/Projects/miette/tooling/git-hooks/pre-push` as the template, but storehouse's gate runs the ENGINE's own suite, not conception .behaviors:
```sh
# ~/Projects/storehouse/tooling/git-hooks/pre-push (installed to .git/hooks/):
#   export HECKS_CONCEPTION_DIR="$REPO/../hecks/hecks_conception"   # for the framework-integration tests
#   (cd rust && cargo test --release)                              # the engine suite + codegen goldens
```
Install: `cp tooling/git-hooks/pre-push .git/hooks/ && chmod +x .git/hooks/pre-push`.
Note: storehouse's framework-integration tests (expiry_sweep, seam*, …) need a sibling
hecks checkout for the conductor/plan DOMAINS (via HECKS_CONCEPTION_DIR) — the
hecksagon fixtures are vendored (Phase 1.5) but the domains are read live. The
boot-from-serialized-bundle arc dissolves this last runtime dependency.

## Step 7 — hecks gate now depends on the sibling binary
hecks's pre-push/pre-commit shell the storehouse binary to run conception .behaviors
+ integrity. Post-move that binary lives in `../storehouse` (Step 5). Document that
hecks's gate now requires a built sibling storehouse (same way miette's gate finds
storehouse in `../hecks` today). Add a clear "storehouse binary not found at … — build
`cd ../storehouse/rust && cargo build --release`" message.

## Step 8 — verify end to end
- `cd ~/Projects/storehouse/rust && cargo build --release` (standalone, conception absent at compile).
- Live door: dispatch through the MCP door (now STOREHOUSE_BIN -> storehouse repo) — a probe + a miette query.
- `bin-buddy` / `summer` / `daily_musing_cf` build against `../storehouse/rust`.
- Both repos' pre-push gates green.
- `git -C ~/Projects/hecks status` clean ; storehouse repo pushed.

## Risks / notes
- **Door-brick:** the symlink/STOREHOUSE_BIN cutover changes the live door's binary. Build the new binary FIRST, probe, keep the old hecks/rust/target binary until verified. `miette --ungoverned` is recovery if the door dies.
- **History size:** filter-repo on a clone is safe (original hecks untouched). The storehouse repo carries rust/+codegen/ history only.
- **The bundle alternative:** boot-from-serialized-bundle (inbox/boot-from-serialized-bundle.md) would let storehouse's tests + deploy stop needing a sibling conception at all — worth doing BEFORE or alongside Phase 2 if we want the storehouse repo fully self-sufficient. Phase 2 as written leaves the framework-integration tests depending on a sibling hecks (acceptable, documented).

## First move next session
Get Chris's go on the repo name/visibility (settled: chrisyoung/storehouse private) and the gh-auth'd Step 2. Steps 1, 3–7 are mechanical and scripted above ; Step 2 is the one irreversible cutover.
