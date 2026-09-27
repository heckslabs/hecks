# 01: The comment standard

**Status:** Accepted 2026-09-26 · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0075 comment sweep](../0075-comment-sweep-map.md)

## Question

Hecks is criticized for being full of comments. On the day of charting, about half of the lines in the Ruby library are comments and about a quarter of the hand-written Rust. Roughly 3,900 comment blocks run over five lines, about 650 run over twenty, and the longest is 118. The blocks over five lines hold three quarters or more of all comment volume.

The current guide adds to it. It requires tags on every public Ruby method and a doc comment on every public Rust item, and it sets no length cap beyond a class doc of about 25 lines. The RuboCop configuration exempts comment lines from the line-length limit. Neither linter runs in CI.

Decide what a comment in this repository is allowed to say, how long it may be, where docs are required, and how the rule is enforced.

## Decision

Accepted by the owner on 2026-09-26, in a grilling session.

**Voice.** Rails API documentation. Ruby reads like Rack and Sinatra source with a one-line summary per public class and method. Rust reads like the standard library: a `///` summary, and an example only where it earns its place.

**Scope.** Comments in every code file type in the repository: Ruby, Rust, specs, `.bluebook` files, shell scripts, CI YAML, generator templates, and generated output through its generator. Markdown (docs, ADRs, README, CHANGELOG) is not swept.

**What a comment may say.** What the thing is, in one line. The contract (parameters, return, raises) on public API only. A non-obvious reason or constraint. A short code example on a public entry point. A file or class header of one or two lines. Design history is banned. Narration of the next line is deleted. Inventories of what a module contains are deleted.

**Limits, enforced mechanically.**

- File or class header: at most 2 lines of prose.
- Method doc: a summary of at most 2 lines, plus tags where the tag rule below applies.
- Inline comment: at most 3 lines.
- Any contiguous block: at most 12 lines including YARD tags.
- No ratio target; the block limits are the control.
- The RuboCop exemption for comment lines is removed.

**Public and internal.** Public is the default surface: what the README, the generated DSL reference, the guides and the `bin/` commands documented in `docs/tools.md` show. Internals are tagged `:nodoc:` in Ruby and `#[doc(hidden)]` or `pub(crate)` in Rust, and need no docs unless there is a non-obvious reason. Docs and tags are required only on untagged public items, and `@param` and `@return` only where the name and signature do not already say it. The Rust missing-doc rule narrows to the public surface, which closes the gap of about 400 undocumented items by narrowing the rule, not by writing 400 docs. Which items are public is ticket 02.

**History.** The banned phrase list grows to cover the wording the code actually uses ("no longer", "the old", "until now", "renamed", "legacy", "used to" and the like); genuine concept names go on the allowlist. A bare ADR reference such as `(ADR 0053)` is allowed, at most one per block. A bug identifier as a lead-in is banned. A real constraint that a future editor would break survives as a one-line reason; everything else is deleted, not moved.

**Enforcement.** Both linters fail CI. There are no per-site markers, only a small allowlist file reviewed like code.

**Delivery.** One large draft PR based on main, superseding the rules from the earlier guide work. The sweep is a re-runnable script, so a branch that conflicts takes its own code and re-runs the script. A short merge freeze covers landing.

**Proof of no behavior change.** The whole suite passes. A comparison of each Ruby and Rust file's non-comment tokens before and after is identical, and the check runs in CI. Regenerated output matches what is committed. Ruby already has the token check; Rust does not (ticket 03).

**Review.** The reviewer reads the rules and the linter, then a stratified sample of about 40 files (public API, internals, Rust, specs, templates), plus a report of removed lines by category.

## Relation to ADR 0069

Accepted by the owner on 2026-09-26. This standard amends ADR 0069, which made the linter a CI gate with a provisional block ceiling of 50 lines and a baseline, over `lib/hecks` only (implemented in PR 874). PR 874 lands first as it is. This standard then lowers the ceiling to 12 lines, widens the scope to the whole repository, and shrinks the baseline to whatever still needs an exception. The sweep rebases onto PR 874 and re-runs on the files that PR touched.

## Consequences

The mandatory-docs rules of the current guide are relaxed, so the guide, `CLAUDE.md` and both linters change. Tickets 02, 03, 04 and 05 settle what this decision leaves open.
