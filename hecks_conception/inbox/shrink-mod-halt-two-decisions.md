# shrink-mod loop — HALTED, two decisions for Chris (2026-07-25)

Branch `feat/shrink-mod`, 22 commits, all pushed, every one green
(cargo test --release + clippy zero-warnings held throughout).
PR: https://github.com/chrisyoung/hecks/pull/new/feat/shrink-mod

## Delivered

- **Phase A** : all four bespoke resolvers (compute, mcp, claude_tool, llm)
  DISSOLVED — each now a declared primitive in primitive.bluebook
  (Compute.Invoke / McpTool.Invoke / ClaudeTool.Invoke / Llm.Invoke, matching
  the seeded Storehouse::Primitive records) with hecksagon sugar + one shared
  engine in reaction.rs. Cascade-fires-and-lands proofs per family. Zero
  changes needed in any user hecksagon (miette's dream chain untouched).
  FIX-WHAT-YOU-FOUND : strip_quotes_or_colon now unescapes source-level
  string escapes — every escaped-quote :mcp args binding silently failed
  JSON parsing before (Ruby<->Rust string-literal drift, fixed at root).
- **Phase B** : 21 concern-casks extracted VERBATIM from runtime/mod.rs, each
  <=200 lines, one intent, its own honest antibody marker (the blanket is
  nearly dissolved). mod.rs **4,270 -> 502** ; what remains is ONLY the
  module index + crate-wide uses + drain_policies.

## Decision 1 — [cask-irreducible] sign-off (completes mod.rs <= 200)

drain_policies is a SINGLE 230-line fn (the live policy/PM cascade loop).
Extracting it verbatim makes a ~245-line policy_drain.rs — over the 200 cap.
Getting under means carving helpers out of live cascade logic, which phase
B's pure-move discipline forbids. Proposed marker (loop may not self-write):

    [cask-irreducible: policy_drain.rs — a single 230-line interpreter fn
     (the live policy/PM cascade loop); splitting it means carving helpers
     out of live cascade logic, which the pure-move discipline forbids]

Sign it -> the extraction lands mod.rs at ~190 code_lines — the goal's residue.

## Decision 2 — the core_runtime NEGATIVE-delta clause (currently +580)

Provably unreachable in this goal's scope : phase B is relocation (delta ~0
per cask, +~210 total from 21 cask headers/impl-wrappers) and phase A's
dissolve cost +370 — behavior-preserving engines + declared protocol weigh
more than the deleted resolvers. The goal-a estimate (-485) assumed 40-line
leaves ; the real engines carry load-bearing protocol (keystone switch,
cross-aggregate scaffolding, world-server routing, chain recursion).

Options :
  (a) amend DONE — drop the clause ; the shrink objective is delivered
      (RECOMMENDED by the loop)
  (b) new goal — deeper dissolution (auth -> ACL bluebook is the best
      candidate) to genuinely go negative
  (c) stop and merge as-is

## Postmortem note for future goal-writing

A \"dissolve to bluebook\" unit does NOT net-shrink imperative LoC when the
protocol being dissolved is load-bearing : the declaration moves to the
bluebook but its generic RUNNER is new Rust. Net-negative requires either
retiring the runner's capabilities entirely or measuring \"bespoke per-family
Rust\" rather than total LoC. Write the metric to match the intent.
