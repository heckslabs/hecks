# 03: Proving a Rust change is comment-only

**Status:** Open · **Type:** prototype (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0075 comment sweep](../0075-comment-sweep-map.md)

## Question

Ticket 01 requires that a sweep touching most files is proven comment-only, in CI. Ruby has this: `bin/standardize_comments --code-unchanged REF` compares the non-comment tokens of each file at a git ref with the working tree, using Ruby's own lexer. Rust has nothing equivalent. `bin/standardize_comments_rust` has a hand-written character walker that separates code from comments, but no comparison and no verification behind its fixes.

Decide how to prove a Rust change is comment-only, and what "comment-only" has to mean for the two cases that are not obvious:

1. **Mechanism.** Reuse the existing character walker, or use a real Rust lexer (a parser crate already in the workspace, or `rustc`'s own token output). The walker is the cheaper build and the likelier to disagree with the compiler on raw strings, nested block comments, lifetimes and doc attributes.
2. **Doc comments are tokens.** A `///` line becomes a `#[doc = "..."]` attribute in the compiler's view, and `#[doc(hidden)]` is a real attribute added by the tagging pass. What counts as unchanged code: the check has to ignore doc text yet accept the deliberate attribute additions.
3. **Template regions.** Comments inside `// TMPL:` sentinel regions in the exemplar files are source for generated code. A change there is comment-only in the file and not comment-only in the generated output. The check has to say which it proves, and regenerate-and-diff has to cover the rest.
4. **Where it runs.** Changed files in PR CI, and the whole tree in the merge queue.

A prototype answers this: build the smallest version of the comparison, run it against a real comment-only edit, a real code edit with the same comment change, and the tricky lexical cases, and look at the result.

## Working recommendation (not a decision)

Prototype the comparison on a real lexer first and compare it with the walker on the tricky cases. Treat `///` text as comment and `#[doc(hidden)]` as an allowed, explicit addition. Cover template regions by regenerate-and-diff rather than by the token check.

## Decision

Open.
