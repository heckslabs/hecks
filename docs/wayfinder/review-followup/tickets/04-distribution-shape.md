---
type: grilling
status: open
blocked_by: [01-research-what-escapes-the-gem]
claimed_by:
---

# Distribution shape: what `gem install hecks` ships

## Question

Today the installed gem is far less than the repo: no executables, and dev tooling in `lib/`
reaches paths that do not exist in a gem. Decide: one `hecks` executable with subcommands
versus the current 85 `bin/` scripts; one gem versus a lean runtime gem plus a tooling gem
(`hecks-dev`); and where each group from the research ticket lands. What does an evaluator get
from `gem install`, and what stays repo-only?

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision.

**Facts**
- `bin/` holds about 86 Ruby scripts in four buckets. Domain-operator tools a gem user could
  use (about 27): `run`, `console`, `docs`, `narrate`, `ir`, `model_check`, `smoke_test`,
  `fuzz`, `project_diagrams`, `project_cli`, `hecks_mcp_door`, era and journal operations.
  Deploy and target projectors (7): `project_deploy`, `project_rust`, `project_wasm` and
  kin, of which Rust and wasm need the `rust/` tree. Language-development and self-hosting
  (about 31): grammar generators, codemods, corpus, `bench`, conformance checks. QA, CI and
  release (about 20).
- Most operator scripts do `require "hecks"` from `lib`, so they port easily (`bin/run:27`).
- Only that first bucket works with an installed gem plus a domain path. The README's own
  quickstart says to clone (`README.md:655`), and `bin/console examples/...` and
  `bin/run ... spec/corpus/...` need repo-only directories.
- `hecks.gemspec:22` ships `lib/**/*` only; there is no `executables`.
- `Hecks::Facade::CliRunner.call(runtime:, argv:, program:)` (`lib/hecks/facade/cli_runner.rb:44`)
  is an IO-free, domain-scoped runner that `bin/run` and `bin/project_cli` already wrap. There
  is no dispatcher for tool subcommands, so a `hecks` executable is a thin new router.
- Blast radius: dependents pin `hecks` with `~>` ranges, so anything `lib/hecks.rb` requires
  must stay in the runtime gem. `lib/hecks.rb:36` requires `hecks/corpus`, which is dev
  tooling and would have to move or become lazy before any split. `storehouse` and
  `mcp_stdio_guard` (`lib/hecks.rb:33-34`) are runtime and stay. Domain images build from a
  git tag, so tag builds must keep working.

**Options**
1. Single gem plus a `hecks` executable (`exe/hecks`, `spec.executables`). Least churn; dev
   code still ships and still raises on a gem install.
2. Runtime gem plus `hecks-dev`. Cleanest seam (research ticket 01 shows one), but two release
   trains and the corpus coupling to untangle; `hecks-dev` still needs `rust/` and `qa/`.
3. Executable plus repo-only dev tooling, guarded. Option 1, plus the dev directories dropped
   from `spec.files` and documented as clone-only.
4. Do nothing. Zero risk; an evaluator gets no command, and the two runtime writes remain.

**Recommendation from prep.** Option 3 in two steps. First fix the two runtime writes
(syntax-boot cache, Storehouse log) to use the temp or cache directory, which is independent of
any split. Then add `exe/hecks` over the operator bucket (`run`, `docs`, `narrate`, `ir`,
`stores`, `model_check`, `smoke_test`, `project_diagrams`, `project_cli`, `mcp`), drop the dev
directories from `spec.files`, and make `hecks.rb:36` lazy. Revisit option 2 only if the dev
tools gain outside users.

**For the maintainer**
1. Are `fuzz` and `model_check` evaluator-facing in the gem or repo-only? `fuzz` needs
   `QaSettings` to stop raising without `qa/settings.yml`.
2. Is the MCP door a product surface? If so it must ship, and *MCP door auth* becomes a release
   blocker.
3. Should the gem carry a sample domain and corpus so the README can say `gem install`?
4. Are the dependents still pinned to `~> 0.3` dead? If so they do not constrain the split.
5. Are `exe/` names locked as public API under the 1.0 stability promise?

## Answer
