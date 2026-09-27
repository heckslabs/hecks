# Comment sweep kit

Everything needed to re-run the ADR 0075 comment sweep on a tree that has moved. The sweep is comment-only, so it is safe to redo on any file whose upstream version changed.

## Files

| File | Job |
|---|---|
| `comment_equiv.rb` | Proves a file changed only in its comments. `ruby comment_equiv.rb BASE_REF path...` or `@listfile`. Ruby-family files compare Ripper tokens, Rust files compare a comment-stripped scan (raw strings, char literals and nested block comments handled; `// TMPL:` sentinels count as code), YAML compares parsed values and non-comment lines, shell and TOML compare non-comment lines. Symlinks are skipped. |
| `worklist.py` | Selects hand-written files that break the standard, skips generated files, adds public-name hints from the docs, and packs files into batches. Writes `worklist.json` beside itself. |
| `sweep-workflow.js` | The first pass: one agent per batch, each rewriting comments under the ticket 01 rules and self-checking with `comment_equiv.rb`. |
| `tighten-workflow.js` | The second pass over files that still break a limit (long blocks, long lines, history phrases). |

## Re-running after other work merged

1. Rebase or branch from the new `main`. For every file the sweep changed **and** upstream also changed, take the upstream version (`git checkout origin/main -- <file>`). Files upstream did not touch keep the swept version.
2. Regenerate anything generated (`bin/project_rust`, `bin/project_vocabulary`, `bin/project_bootstrap_table`, `bin/project_model`) rather than merging it. Never sweep a generated file; fix the comment at its generator or exemplar.
3. Set `BASE` in the workflow scripts and the scratch directory `T` (they name absolute paths) to the new base commit and a fresh directory. Run `worklist.py` from the repo root, restricted to the files taken from upstream in step 1.
4. Run the first-pass workflow over those batches, then the second pass over what `comment_equiv.rb` and the limits still flag.
5. Verify centrally, never from the agents' own reports: `comment_equiv.rb BASE @changed-files` must print OK for every file, the whole suite must pass, and every Rust crate must `cargo check`.

## Known traps

- A comment can be a contract. One spec requires a Rust source file to contain a fixture name that only appeared in a comment. Run the suite before trusting a sweep.
- The docs generator reads the opening comment of each `bin/` script into generated docs. Run the reference golden spec.
- `cargo check` rewrites stale lockfiles; restore them before committing.
- Comment-looking lines inside heredocs and string literals are data, not comments. The checker treats them as code, so agents cannot change them without failing.
- A shell guard in some sandboxes rejects commands that name `.github` paths; pass those through a list file (`@listfile`).
