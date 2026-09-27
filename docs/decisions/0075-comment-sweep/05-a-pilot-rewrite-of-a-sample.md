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

Open.
