# 04: The sweep method and cost

**Status:** Open · **Type:** grilling (HITL) · **Blocked by:** 02, 03, 05 · **Claimed by:** unclaimed
**Map:** [0075 comment sweep](../0075-comment-sweep-map.md)

## Question

Ticket 01 says the sweep is one draft PR, re-runnable, delete-first, and proven comment-only. About 3,900 blocks over five lines in roughly 530 hand-written files have to be rewritten. Decide how, once the public list (02), the Rust check (03) and the pilot results (05) are known:

1. **Who rewrites.** Agents per file or per directory, and whether one pass or two (delete, then tighten).
2. **Batching and order.** By directory, or by file type, and what runs after each batch (the equivalence check, the linters, the suite).
3. **Idempotence.** How a second run over an already-swept tree changes nothing, and how a branch that conflicts re-runs the script on its own edits without losing its code.
4. **Cost and budget.** The measured per-file cost from the pilot, scaled to the tree, and the ceiling on what the sweep may spend.
5. **Failure handling.** What happens to a file whose rewrite fails the equivalence check, and to a comment the agent cannot decide about.
6. **The review sample.** How the stratified sample of about 40 files and the removed-lines report are produced.

## Working recommendation (not a decision)

Not settled until the three blockers are. The starting point is per-file agents behind a script that owns the batching, the checks and the retry, using the prompt the pilot proved.

## Decision

Executed by direction, 2026-09-26. The owner chose to sweep the whole repository at once before tickets 02 and 03 were decided, so the method below was settled by doing it. It stays open for the owner to accept or change.

- **Who rewrites:** one agent per batch of files (batches packed by comment volume, at most six small files each), plus a second pass over the files still over a limit.
- **Public list (ticket 02, in effect):** a name-match heuristic; constants the README, DSL reference, guides or `docs/tools.md` name were passed to agents as public hints, everything else internal. No tags were added.
- **Rust proof (ticket 03, in effect):** a comment-stripped scan, `sweep-kit/comment_equiv.rb`, checked centrally after the agents finished. Sabotage tests confirmed it fails on a real code edit.
- **Cost:** about 25M subagent tokens for the first pass over roughly 320 batches and about 2M for the second pass over 30.
- **Failures:** the checker's own bugs (raw strings, an over-broad directive regex, symlinks) were fixed centrally. Two generated Ruby files the sweep should have skipped were restored, one spec-required comment was put back, and a lockfile that `cargo check` rewrote was restored.
- **Idempotence and conflicts:** `sweep-kit/README.md` gives the re-run procedure for a tree that moved.
- **Still open:** the review sample and removed-lines report, the generated-output comments (exemplar prose and banners, fixed at their source), and the linter, guide and CI changes.
