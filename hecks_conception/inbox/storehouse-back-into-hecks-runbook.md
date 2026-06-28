# Runbook — move the storehouse engine BACK into hecks (make the public repo buildable)

> Written 2026-06-24 end-of-session (body op:9, fresh head deferred). Chris's
> decision: "move storehouse back into hecks. It's the real value." This REVERSES
> the engine extraction (a37f3d8bc et al). Execute as ONE committed arc — a
> half-done state leaves the PUBLIC repo unbuildable AND its CI confused.

## Why
- `hecks` is **PUBLIC** ; `storehouse` (the runtime engine) is **PRIVATE**.
- The engine IS the value, and nothing builds/runs without it. An OSS user
  literally cannot build today.
- The extraction removed `hecks/rust` + `hecks/codegen` and the README's Quick
  Start (`cd hecks/rust && cargo build`) now dies on step two.
- Fix: bring the engine home so the public repo is self-contained and buildable.

## Ground truth at write time
- storehouse repo: `https://github.com/chrisyoung/storehouse.git` (PRIVATE),
  HEAD `3377909`, tracked root = `codegen/ rust/ tooling/`. `rust/` is now a
  3-crate workspace: core `storehouse` (lib, wasm-safe) + `rust/sqlite` + `rust/cli`
  (binary named `storehouse`). Local checkout: `~/Projects/storehouse`.
- hecks repo: `git@github.com:chrisyoung/hecks.git` (PUBLIC), HEAD `7ffbd521a`.
  No `rust/`/`codegen/` tracked (only a stale gitignored `rust/target/`).
- wasm32 thread is GREEN (storehouse lib + deciderate worker both build for
  wasm32). Don't re-chase it ; just preserve it (see Gate step).

## History decision
Flat-import the engine via `git archive` (tracked files only, no `target/`, no
`tooling/` collision). The storehouse repo is KEPT as the history archive. A
unrelated-history merge was rejected: storehouse's `tooling/` (its own cargo-test
gate) collides with hecks's `tooling/` (bluebook gates), and the layout graft is
fiddly. Clean-break + archived history matches house style.

## STEP 1 — import the engine (non-destructive; storehouse untouched)
```sh
cd ~/Projects/hecks
git -C ~/Projects/storehouse archive HEAD rust codegen | tar -x
#   -> restores hecks/rust/ (workspace) + hecks/codegen/ , tracked content only.
ls rust/Cargo.toml rust/cli rust/sqlite codegen/   # sanity
```

## STEP 2 — repoint EVERY call site (one pass). Exact before -> after:
**Cargo path-deps (in-tree consumers):**
- `hecks/summer/Cargo.toml:8`  `path = "../../storehouse/rust"` -> `path = "../rust"`
- `hecks/deployments/daily_musing_cf/worker/Cargo.toml:20`
  `path = "../../../../storehouse/rust", default-features = false`
  -> `path = "../../../rust", default-features = false`

**Cargo path-deps (EXTERNAL repos — separate commits in those repos):**
- `~/Projects/deciderate/worker/Cargo.toml:20`
  `path = "../../storehouse/rust", default-features = false`
  -> `path = "../../hecks/rust", default-features = false`
- `~/Projects/bin-buddy/worker/Cargo.toml:20`
  `path = "../../storehouse/rust"` -> `path = "../../hecks/rust"`

**Tooling / door:**
- `hecks/.mcp.json:11` `STOREHOUSE_BIN`
  `/Users/christopheryoung/Projects/storehouse/rust/target/release/storehouse`
  -> `/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse`
- `~/.local/bin/storehouse` symlink ->
  `~/Projects/hecks/rust/target/release/storehouse`
  (`ln -sf ~/Projects/hecks/rust/target/release/storehouse ~/.local/bin/storehouse`)
- `hecks/tooling/git-hooks/pre-commit:50`
  `STOREHOUSE="$REPO/../storehouse/rust/target/release/storehouse"`
  -> `STOREHOUSE="$REPO/rust/target/release/storehouse"`
- `hecks/tooling/git-hooks/pre-push:40`
  `STOREHOUSE="$MAIN_REPO/../storehouse/rust/target/release/storehouse"`
  -> `STOREHOUSE="$MAIN_REPO/rust/target/release/storehouse"`

**Parity + smoke harnesses** (repointed to external in df832f82f — reverse them):
- `hecks/parity/*.rb` (6: parity_test, hecksagon_parity_test, world_parity_test,
  fixtures_parity_test, behaviors_parity_test, fixtures_auto_load_parity_test)
- `hecks/hecks_conception/tests/*.sh` (8: voice_and_sleep_lockdown, dream_content_smoke,
  interpret_dream_smoke, statusline_regression_smoke, status_golden, body_cycles_smoke,
  pulse_fanout_smoke, pulse_organs_smoke)
  -> grep each for `storehouse/rust` / `../storehouse` and repoint to in-tree
  `rust/target/release/storehouse`. Verify with:
  `grep -rn 'storehouse/rust\|\.\./storehouse' parity/ hecks_conception/tests/`

## STEP 3 — REVERSE the gate re-tuning (the non-obvious part)
The extraction re-tuned hecks CI around the engine being gone. With it back:
1. **LoC ratchet (Gate 7)** — "non-bluebook LoC may not increase vs origin/main".
   The engine return is a huge legit increase -> it WILL block. DO NOT skip
   (validators-first: change the rule, never bypass). Read the ratchet script
   (`tooling/` — find the Gate-7 implementation) and EXCLUDE `rust/` + `codegen/`
   from the counted set (the ratchet guards CONCEPTION discipline, not engine LoC),
   or rebaseline. Decide + implement, don't RATCHET_SKIP.
2. **Antibody / commit-msg** — engine files are non-bluebook. Either the antibody
   already scopes to `hecks_conception/` (verify) or add `rust/` + `codegen/` to the
   exempt registry as a named, intentional engine-tree entry. NOT a per-file
   pre-emptive marker.
3. **Bring the pruned Rust gates HOME** — `a0536bf14` pruned conceiver parity,
   `cargo check --tests`, specializer byte-identity (they moved to storehouse CI).
   Recover them from `git show a0536bf14` and re-add to hecks pre-commit/pre-push
   now the engine is in-tree. Also FOLD IN the wasm regression guard the OUROBOROS
   brief wanted: `rustup run stable cargo check --target wasm32-unknown-unknown -p storehouse`
   (Homebrew cargo has NO wasm32 std — must use rustup stable). Make it skip
   gracefully if rustup/target absent (OSS contributors won't all have it).

## STEP 4 — build + door cutover
```sh
cd ~/Projects/hecks/rust && cargo build --release -p storehouse-cli
#   produces target/release/storehouse (binary name is `storehouse` via cli crate).
#   NOTE: building the root pkg alone only builds the lib — must target the cli crate.
ls -l target/release/storehouse   # fresh mtime
# Probe BEFORE trusting the door (door shells STOREHOUSE_BIN fresh each call):
./target/release/storehouse validate ../examples/pizzas/bluebook/pizzas.bluebook  # expect VALID — Pizzas (4 aggregates)
```
The `.mcp.json` repoint (Step 2) + this build = the door now runs the in-tree binary.

## STEP 5 — README + verify
- README Quick Start (`cd hecks/rust && cargo build`) becomes CORRECT again once
  `rust/` is back — verify it actually works from a clean state. Consider noting
  the binary is built by the `storehouse-cli` workspace member.
- Simulate a fresh clone build if feasible (clone to /tmp, `cd rust && cargo build --release`).
- Run hecks pre-commit gates green (parity, validate, behaviors, smoke, ratchet,
  + the re-homed Rust gates).
- `cd ~/Projects/storehouse/rust && cargo test --workspace` should still pass
  (storehouse repo stays as archive; nothing removed there).

## STEP 6 — commit strategy (hecks, PUBLIC)
One arc, ideally a few clean commits:
  1. `feat(engine): bring the storehouse engine back in-tree (rust/ + codegen/)`
  2. `refactor(gates): re-home the Rust gates + scope the LoC ratchet to conception`
  3. `chore(repoint): point path-deps/.mcp/symlink/harnesses at in-tree rust/`
External repos (`deciderate`, `bin-buddy`) get their own one-line repoint commits.

## OPEN DECISIONS for Chris (surface at start)
- **Storehouse private repo fate**: keep as private history archive (default),
  make it a public mirror, or delete now that the engine lives in hecks?
- **LoC ratchet scope**: confirm excluding `rust/`+`codegen/` (engine isn't the
  thing the conception-discipline ratchet should police) vs rebaselining.
- **History**: flat-import (this plan) vs grafting storehouse history. Flat is
  assumed ; say so if you want the engine commits in the public log.

## Risks
- Door-brick: build the in-tree binary + probe BEFORE relying on the door ; keep
  the old `~/Projects/storehouse/rust/target/release/storehouse` until verified.
- Don't leave the public repo half-imported (unbuildable). If interrupted, either
  finish the import+repoint or `git checkout`/`rm` the imported tree to restore.
- LoC ratchet / antibody: FIX the rule, never SKIP the gate.
