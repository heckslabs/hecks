---
type: research
status: closed
blocked_by: []
claimed_by:
---

# Research: what in `lib/` reaches outside an installed gem

## Question

The gemspec ships only `lib/**/*` and declares no executables. List every place code under
`lib/` reads or writes a path that exists only in a repo checkout (`rust/`, `examples/`,
`qa/settings.yml`, `bin/`, `<gem root>/../tmp`, `spec/`), and group them: fuzzing, bench,
QA settings, syntax-boot cache, MCP servers, other. For each group say whether it is runtime,
dev tooling, or ambiguous, and what breaks (raises, silently no-ops) when run from an installed gem.
Facts only; the decision is in *Distribution shape*.

## Answer

Research complete. Correction to the premise: `SyntaxBoot` and `Storehouse` resolve to
`<gem root>/tmp`, not `<gem root>/../tmp`. An installed gem ships `lib/**` only.

| Group | Kind | Installed-gem behavior |
| --- | --- | --- |
| Fuzzing (`lib/hecks/fuzzing/`) | dev tooling, not loaded by `hecks.rb` | `QaSettings.load` raises (no `qa/settings.yml`); `rust/Cargo.toml` read raises `ENOENT`; the concurrency racer spawns a missing `bin/` script and raises; combination miner raises on missing `qa/` prompt |
| Bench (`lib/hecks/bench/`) | dev tooling, not loaded by `hecks.rb` | `cargo build` in missing `rust/` raises; example domains missing; `git rev-parse` silently returns "unknown" |
| Syntax-boot cache (`bluebook/meta_validator/syntax_boot.rb`) | **runtime, on every parse** | writes `<gem dir>/tmp/hecks_syntax_boot_cache`; a read-only gem dir silently disables the cache; `HECKS_SYNTAX_BOOT_CACHE=off` opts out |
| Storehouse and MCP guard (`storehouse.rb`, `mcp_stdio_guard.rb`) | runtime, loaded by `hecks.rb` | appends JSONL under `<gem dir>/tmp/storehouse` or silently no-ops; path confinement root becomes the gem dir; the MCP server executables themselves live in unshipped `bin/` |
| Corpus, codemod, query IR (`corpus.rb`, `codemod.rb`, `query_ir.rb`) | dev tooling (`corpus.rb` constant is loaded by `hecks.rb`) | globs over `examples/`, `qa/`, `spec/`, `rust/` come back empty or raise `ENOENT`; codemod writes back into shipped `lib/` bluebooks |
| Grammar evolve (`grammar/evolve.rb`) | dev tooling | rewrites shipped `lib/hecks/language/**/*.bluebook` in place |
| Doc reference (`doc/reference.rb`) | dev tooling | unguarded `File.read` of `docs/` and `bin/*` raises |
| Deploy projections | string output only | emit Makefile text naming `rust/` and `bin/` paths; no filesystem access |

Two findings matter for the decision. (1) Two runtime paths, the syntax-boot cache and
Storehouse logging, write into the gem directory on a normal install, which is a defect
independent of any split. (2) Everything else that breaks is already dev tooling and is not
required by `hecks.rb`, so a split has a clean seam: fuzzing, bench, corpus, codemod, query IR,
grammar evolve and doc reference.
