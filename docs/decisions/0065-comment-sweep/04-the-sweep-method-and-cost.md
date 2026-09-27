# 04: The sweep method and cost

**Status:** Open · **Type:** grilling (HITL) · **Blocked by:** 02, 03, 05 · **Claimed by:** unclaimed
**Map:** [0065 comment sweep](../0065-comment-sweep-map.md)

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

Open.
