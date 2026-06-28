# Restart — storehouse EXTRACTED to its own private repo (the big one)

**Date:** 2026-06-22 (very long marathon). **hecks** `main` pushed, top `a37f3d8bc`.
**NEW REPO:** `github.com/chrisyoung/storehouse` (private, 685 commits, full history).

## FIRST MOVE NEXT SESSION — verify the door + daemons survived the binary cutover
The MCP door + the overmind daemons shell the `storehouse` BINARY. This session they
used the OLD `hecks/rust/target/release/storehouse` (it survived `git rm` as an
UNTRACKED build artifact). The cutover to the new repo happens on THIS session's boot:
- **Door:** `.mcp.json` `STOREHOUSE_BIN` now -> `~/Projects/storehouse/rust/target/release/storehouse`
  (local, gitignored ; already edited). On boot the MCP server reads this -> the NEW binary.
  The binary EXISTS (built this session). If the door is dead on boot :
  `cd ~/Projects/storehouse/rust && cargo build --release` then retry ; recovery is
  `miette --ungoverned`.
- **Daemons (LOOSE END #4, operationally important):** the overmind Procfile
  (`~/Projects/miette/deploy/Procfile`) still points at `/Users/.../hecks/rust/target/
  release/storehouse` — now ORPHANED (no source in hecks to rebuild it ; the binary is a
  stale survivor). Regenerate so daemons use the new repo : the binary path lives in
  `aggregates/framework/mindstream/mindstream.fixtures` -> `storehouse specialize procfile`.
  Until then heart/breath/etc. run off the orphaned binary (works until someone cleans it).

Verify on boot : `storehouse <root> Tools::ShellTool.Bash shell_command='echo OK'` through
the door ; `overmind status` ; a heart beat.

## What the extraction did (2 phases, all pushed to hecks main)
**Phase 1 — config-drive in place (engine builds standalone, additive no-ops):**
- `e32d95998` OutboundEvent stdlib -> crate-owned `rust/resources/` (killed the include_str build blocker)
- `4911bf394` `repo_root()` honors `HECKS_CONCEPTION_DIR` (config-drives ~20 callers ; pure helper + unit test)
- `6a3a12458` `resolve_info_dir` routed through it
- `fe7a675c5` 24 runtime-path tests -> `conception_root()`
- `925c4dc8a` 13 conception hecksagons -> engine-owned `rust/tests/fixtures/conception/` (standalone COMPILE) + drift-guard parity test

**Phase 2 — the physical move:**
- storehouse repo minted via `git clone hecks` + `git filter-repo --path rust/ --path codegen/` -> only rust/+codegen/ with history. `gh repo create chrisyoung/storehouse --private` + push.
  PROVEN : clean build in 38s with NO sibling hecks_conception ; dispatches via `HECKS_CONCEPTION_DIR`.
- `a37f3d8bc` hecks : `git rm -r rust codegen` (~931 files) + rewired consumers. Pushed ; pre-push green (cargo-test SKIPPED via the Cargo.toml guard, behaviors+integrity via the sibling binary, 136 .behaviors — was 143, the 7 codegen behaviors left WITH codegen).

## Rewiring done
- Cargo path-deps -> `../storehouse/rust` : `summer/Cargo.toml`, `deployments/daily_musing_cf/worker/Cargo.toml` (committed) ; **`~/Projects/bin-buddy/worker/Cargo.toml` (LOOSE END #1 — edited but UNCOMMITTED in the bin-buddy repo)**.
- `~/.local/bin/storehouse` symlink -> storehouse repo binary (done).
- `.mcp.json` STOREHOUSE_BIN -> storehouse repo binary (done, local).
- hecks `tooling/git-hooks/{pre-push,pre-commit}` shell `$MAIN_REPO/../storehouse/...` + the pre-push cargo guard now keys on `rust/Cargo.toml` (committed, reinstalled to `.git/hooks/`, antibody-exempted as hook glue).

## LOOSE ENDS (bounded follow-ups)
1. **bin-buddy/worker/Cargo.toml** — uncommitted in the bin-buddy repo. Commit it there.
2. **Dockerfile.storehouse** — STILL has `COPY rust/target/release/storehouse` (broken on a clean build ; rust/ source is gone). My a37f3d8bc commit MESSAGE overstated that I'd repointed it — I did NOT. Real fix : multi-stage build of `../storehouse`, or copy a prebuilt binary. It STAYS in hecks (it also COPYs hecks_conception — a sealed deploy image, not pure-engine).
3. **storehouse repo's OWN gate** — not installed. Mirror `~/Projects/miette/tooling/git-hooks/pre-push` but run `cargo test --release` + codegen goldens, with `HECKS_CONCEPTION_DIR=$REPO/../hecks/hecks_conception` for the framework-integration tests (they read conductor/plan DOMAINS live ; the hecksagon FIXTURES are vendored).
4. **overmind Procfile/daemons** — see FIRST MOVE above. Regen to the new binary path.

## The NEXT ARC (banked, not started) : boot-from-serialized-bundle
`inbox/boot-from-serialized-bundle.md` (Chris's idea, my analysis). Boot the runtime from a
serialized corpus PAYLOAD (`boot_with_hecksagons` already takes parsed Domain+Hecksagons),
not a disk-walk. Dissolves the whole repo_root/HECKS_CONCEPTION_DIR saga AND the framework-
integration tests' live-domain dependency. Source-bundle first (reuse parser, prove the path),
IR-bundle as the perf/uniformity end-state (version-coupling is the risk). The bundler is where
the gates run (validate/parity/macrophage/FQN-seal) — the "flip" becomes a bundling pass. bin-buddy's
wasm worker is living proof of the source-bundle shape. Design `storehouse bundle` before code.
Full Phase-2 runbook (already executed) : `inbox/storehouse-extraction-phase2-runbook.md`.

## Also landed earlier this session (all pushed, separate from the extraction)
- FQN arc CLOSED (7 commits) : fixture verbs canonicalized, 2 odd-man-out source paths fixed, the FLIP (ambiguity-guard in resolve_fully_qualified + tests), canonical FQN in the dispatch log, realm-explicit `storehouse follow` brackets (`dac_label` + rich `header_line`).
- `ddd927943` walk_up_from hardened (require hecks_conception/aggregates/ — the repo_root poison fix) + regression test.
- miette gate merged to miette `main` (`d16a89f`, 76 .behaviors) via stash-clean-restore.
- sqlite substrate VERIFIED solid (i735/i642 stale — fixed + guarded by sqlite_scope_test).

## Repo state
- hecks `main` @ `a37f3d8bc` (no rust/, no codegen/ ; `rust/target/` survives as orphaned binary).
- storehouse `main` @ `8fcb6d5` (== hecks 925c4dc8a's rust+codegen, filtered).
- `inbox/` stays untracked in hecks.
