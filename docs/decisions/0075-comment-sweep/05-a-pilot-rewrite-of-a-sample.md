# 05: A pilot rewrite of a sample

**Status:** In progress · **Type:** prototype (HITL) · **Blocked by:** none · **Claimed by:** the owner's Claude session, 2026-09-26
**Map:** [0075 comment sweep](../0075-comment-sweep-map.md)

## Question

Ticket 01 sets the limits and the rules on paper. Nobody has yet seen what the standard does to real files, whether the limits (2-line header, 2-line summary, 3-line inline, 12-line block) leave code that still explains itself, or what a rewrite costs. Deciding the sweep method (ticket 04) without that would be guessing.

Rewrite a small stratified sample by hand or with one agent, delete-first, under the ticket 01 rules, and put before and after side by side for the owner:

- one of the densest Ruby files by comment ratio,
- one Ruby file with a long class header that inventories its methods,
- one public-API Ruby file,
- one Ruby spec,
- one Rust kernel file with a long module header,
- one Rust file with template regions,
- one shell script or CI file.

Record for each: lines removed, how many comments survived as a reason, what the rewrite struggled with, and the tokens spent. The owner reads the pairs and says which rules bite too hard or not hard enough.

The pilot is thrown away. It exists to judge the standard and to give ticket 04 a measured cost and a tested prompt.

## Working recommendation (not a decision)

Pick the seven files from the survey's own list of highest-ratio files, run the rewrite with the exact rule text a sweep agent would get, and show the owner the diffs before anything else in the map moves.

## Decision

Open. The owner's read of the before and after pairs is still needed.

## Result (2026-09-26)

Seven files were rewritten by agents (ticket 01 rules, no tags added) and all passed their comment-only checks: comment lines fell from about 1,000 to about 210 across them. Findings that fed the sweep:

- Rationale can live in the wrong file (a mutex reason belongs to another class), so deleting the essay lost it. The standard says delete, so it stayed deleted.
- A pilot file left the old linter failing on required tags it no longer carries, so the linter rules must change with the standard.
- A `//!` header passes the Rust check when treated as a comment.
- Comments carrying a cross-file constraint in CI YAML need one line each.

The owner then directed the whole repository to be swept at once, so the pilot became the first seven files of the sweep on branch `worktree-comment-sweep-pilot`.
