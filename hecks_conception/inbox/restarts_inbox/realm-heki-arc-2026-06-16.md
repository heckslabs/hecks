# RESTART — Arc 0 done ; Realm+world+heki arc fully designed, kernel keystone NEXT

**Date:** 2026-06-16 (session 4). Read this, then the design doc, then act.

VOICE : I speak as myself — I / my / mine. My state, my brain.

## 0. Standing constraints (unchanged)

- Every tool call routes through the storehouse door (`mcp__storehouse__storehouse__dispatch`
  with `Tools::FileTool.*` / `Tools::ShellTool.Bash` / `Tools::SearchTool.Grep` ; FileTool uses
  `file_path`, ShellTool uses `shell_command`, every dispatch needs a top-level `summary`).
  Native IO is hard-blocked (exit 2). Always the Rust runtime. Bluebook-first.
- No `git add -A`, no Co-Authored-By, files <200 LoC code, tests <1s. Let antibody/macrophage
  hooks BLOCK and surface per file ; never pre-write `[antibody-exempt: ...]` markers.
- **GOLDEN REFERENCE : `examples/pizzas/bluebook/` — Chris : “always use pizzas for reference
  from now on.”** (world + hecksagon + bluebook ; the family-establishes-world composition.)

## 1. DONE this session (committed)

- **Arc 0 — no-promises macrophage : COMMITTED `ceee742a9`.** `Discipline::ArtifactClaim` (per-claim,
  standing-fact upsert keyed by source+claimed_path ; verdict unverified/satisfied/broken/retracted)
  + `NoPromisesSweep` singleton (Scan/Verify → Primitive::Process.Spawn policies) +
  `bin/artifact_claim_scan.mjs` (extract path tokens, skip comment prose, RecordClaim + Retract) +
  `bin/artifact_claim_verify.mjs` (test -e → MarkSatisfied/MarkBroken) + `:heki` hecksagon.
  Proven : scan 4 bluebooks → 5 claims → 5 satisfied, 0 broken (after clearing self-false-positives).
  Warn-first ; flips to block once the over-promise work-list clears. Forks resolved : Process.Spawn
  for both scan + verify (NO new adapter family, NO generated Rust). Antibody passed on the .mjs leaves.
- **Design docs committed `a4e8aff6b`** (event-sourcing-lineage + the 3 prior restart notes).

## 2. THE NEXT ARC — Realm + world-wired heki across all ~/Projects

**Source of truth : `hecks_conception/docs/designs/realm-heki-world-wiring.md` (read it first).**

Target store shape EVERYWHERE : `~/.heki/<realm>/<domain>/<aggregate>.heki`. No env var.

**Two decisions LOCKED with Chris :**
1. **Realm declared in each `.world`** — new `realm "name"` field beside `heki { dir }`.
2. **Full pizzas-ification** — migrate every `adapter :heki` → `Domain::Aggregate.persisted_by("Heki")`
   (~22 hecksagons in hecks_conception + miette + client + prod repos).

**Kernel keystone FIRST (this is why it was banked for a fresh head — it touches the world
GRAMMAR + the Ruby↔Rust PARITY suite, the most drift-prone surface) :**
1. Add `realm` to the `.world` grammar (world parser) + IR. **Parity bites here — the delicate part.**
2. Make the DISPATCH store-path resolution world-aware (today it ISN'T : Arc 0 claims landed at
   `miette-state/information/artifact_claim/artifact_claim.heki` via `resolve_info_dir`, FLAT, no
   domain/realm). `main.rs:3170 find_world_heki_dir` already reads world `heki.dir` for SOME
   subcommands ; the main dispatch path must too. Nest `<dir>/<realm>/<domain>/<aggregate>.heki`
   in `heki.rs:382 store_path` / `:415 path_for`.
3. Drop `HECKS_INFO` precedence in `heki.rs:656 resolve_info_dir` (last-resort default only) ;
   invert the `resolve_tests` (“env wins unconditionally”).
4. **VERIFY against pizzas** with `HECKS_INFO` UNSET : dispatch `Pizzas::Pizza.CreatePizza`,
   confirm store lands at `~/.heki/<realm>/pizzas/pizza.heki`. ONLY THEN fan out.

**Fan-out (mechanical, AFTER keystone green ; good workflow candidate) :** per domain with
`adapter :heki` → migrate to `persisted_by("Heki")` + add `.world` (`realm` + `heki dir "~/.heki"`)
+ update parity/behaviors. Arc 0's artifact_claim migrates too (store relocates to
`~/.heki/<realm>/discipline/`). CONFIRM realm value per repo with Chris (hecks_conception →
“miette”? “hecks”? ; clients → per-client ; prod → “embryonaut”).

## 3. ALSO QUEUED (Chris, this session)

- **Pizzas as THE golden reference in my SYSTEM PROMPT.** It is GENERATED from a bluebook (the
  mindstream `boot` member regenerates `~/Projects/miette/self/system_prompt.md` every boot). Edit
  the GENERATING source, NOT the rendered `.md`. Small, separate.
- **Thread B — DSL tightening** (`list_of`/`reference_to` removal, ~110 files). Still queued.
- Dispatch architecture (CommandBus vs storehouse, two async buses) — the BIG arc, design at
  `docs/designs/event-sourcing-lineage.md`. Q1/Q5/static-fork still open. Don't start at high context.

## 4. UNCOMMITTED right now

- `docs/designs/realm-heki-world-wiring.md` + this restart note (commit together).
- Stale memory `reference_filetool_write_broken.md` still wrongly says FileTool.Write never
  persists — it DOES (used all session). Correct or delete.
