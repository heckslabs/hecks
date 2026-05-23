# i729 — `storehouse specialize` repo_root walks PAST the worktree → fragment edits don't take

`heki::repo_root` (`rust/src/heki.rs:617 walk_up_for_repo_root`) deliberately
SKIPS any `hecks_conception/` whose ancestry contains `/.claude/worktrees/`,
walking up to the canonical checkout. That's correct for resolving sibling
repos (`../miette`, `../miette_family` only exist at the real root). But it has
a sharp edge for `storehouse specialize`: the specializer reads its codegen
`*.rs.frag` snippets via `repo_root.join(snippet_path)`, so when run from inside
an agent worktree it reads the MAIN repo's fragments, not the worktree's.

## Found
Editing `codegen/hecksagon_parser_shape/snippets/absorb_adapter_body.rs.frag` in
the worktree, then `storehouse specialize hecksagon_parser` regenerated from the
UNCHANGED main-repo fragment — the new match arm silently didn't appear. The
golden test then failed because the tracked (worktree) file and the regenerated
(main-fragment) file disagreed.

## Workaround used (this PR)
Mirror every codegen fragment edit into the main repo's `codegen/` before
running `specialize`, then regenerate. The worktree commits carry the
fragment + generated file (coherent); the main working-tree dirtiness resolves
on merge. This is the standard workflow for ANY specializer-touching change made
in a worktree, and it's easy to forget (and the main-repo fragment can get
reverted by unrelated checkouts mid-session, silently un-doing the mirror).

## Fix wanted
Either (a) `specialize` resolves its codegen root from `current_dir` (or a
`--codegen-root` flag) rather than the sibling-aware `repo_root`, so a worktree
specializes its OWN fragments ; or (b) a guard that errors loudly when the
fragment that fed a generated file differs from the one on disk at the resolved
root. Today the divergence only surfaces as a downstream golden-diff failure
with no hint that the cause is a worktree/main fragment mismatch.
