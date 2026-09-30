# The gem ships a `hecks` executable, and development tooling stays in the repo

**Status:** Accepted — implemented in 2.8.0. Date: 2026-09-27. Step 1 (the syntax-boot cache and the Storehouse log live under `Hecks::CacheDir`) and step 2 (`exe/hecks`, and a packaged file list without the repository-only tooling) both shipped. The open items below still stand.

## Context

`gem install hecks` today delivers `lib/` and nothing else. `hecks.gemspec:25` builds `spec.files` from `lib/**/*` and the gemspec declares no `executables`. Every command an operator would run lives in the unshipped `bin/` directory, and the README's own quickstart tells the reader to clone (`README.md:655`).

Some code under `lib/` reaches paths that exist only in a checkout (`docs/wayfinder/review-followup/tickets/01-research-what-escapes-the-gem.md`).

| Group | Kind | Installed-gem behavior |
| --- | --- | --- |
| Syntax-boot cache (`lib/hecks/bluebook/meta_validator/syntax_boot.rb`) | runtime, on every parse | `CACHE_DIR` (line 169) is `<gem dir>/tmp/hecks_syntax_boot_cache`; a read-only gem directory silently disables the cache |
| Storehouse log (`lib/hecks/storehouse.rb`) | runtime, required by `lib/hecks.rb:33` | `LOG_ROOT` (line 105) is `<gem dir>/tmp/storehouse`; appends fail silently on a read-only install |
| Fuzzing (`lib/hecks/fuzzing/`) | dev tooling | `QaSettings.load` raises without `qa/settings.yml`; the `rust/Cargo.toml` read raises `ENOENT` |
| Bench (`lib/hecks/bench/`) | dev tooling | `cargo build` in a missing `rust/` raises |
| Corpus, codemod, query IR, grammar evolve, doc reference | dev tooling | globs over `examples/`, `qa/`, `spec/`, `rust/` come back empty or raise; codemod and grammar evolve rewrite shipped `lib/` bluebooks in place |

Two findings shape the decision. The first two rows are runtime writes into the gem directory on a normal install, a defect independent of any split. Everything else that breaks is already dev tooling and is not required by `lib/hecks.rb`, so there is a clean seam. The one exception is `require_relative "hecks/corpus"` at `lib/hecks.rb:36`.

`bin/` holds about 86 scripts in four buckets (`docs/wayfinder/review-followup/tickets/04-distribution-shape.md`): about 27 domain-operator tools, 7 deploy and target projectors, about 31 language-development and self-hosting scripts, and about 20 QA, CI and release scripts. Most operator scripts start with `require "hecks"` from `lib` (`bin/run:27`), so they port easily. `Hecks::Facade::CliRunner.call(runtime:, argv:, program:)` (`lib/hecks/facade/cli_runner.rb:48`) is an IO-free, domain-scoped runner that `bin/run` and `bin/project_cli` already wrap. Nothing dispatches tool subcommands.

Dependents pin `hecks` with `~>` ranges, and domain images build from a git tag, so whatever `lib/hecks.rb` requires must stay in the runtime gem and tag builds must keep working.

## Decision

Two steps, in this order.

1. **Stop writing into the gem directory.** Move the syntax-boot cache (`CACHE_DIR`) and the Storehouse log (`LOG_ROOT`) to the system temp directory or the XDG cache directory. `HECKS_SYNTAX_BOOT_CACHE=off` keeps working. This step does not depend on step 2 and ships first.
2. **Ship a `hecks` executable and trim the package.**
   - Add `exe/hecks` and list it in `spec.executables`. It is a thin router over the domain-operator scripts: `run`, `docs`, `narrate`, `ir`, `stores`, `model_check`, `smoke_test`, `project_diagrams`, `project_cli`, and `mcp` for the MCP door. The domain-scoped part wraps `Hecks::Facade::CliRunner`.
   - Keep the dev-tooling directories out of `spec.files`.
   - Make the `require "hecks/corpus"` at `lib/hecks.rb:36` lazy, so the constant loads on first use instead of at boot.

Dev tooling stays in the repo and is documented as clone-only: fuzzing, bench, corpus, codemod, query IR, grammar evolve, the doc reference generator and the QA scripts. A separate `hecks-dev` gem is revisited only if those tools gain users outside this repository.

The runtime gem keeps everything `lib/hecks.rb` requires, including `storehouse` and `mcp_stdio_guard`, so existing `~>` pins keep resolving. Building a domain image from a git tag keeps working because nothing in the tag layout moves.

## Consequences

- An evaluator who runs `gem install hecks` gets a `hecks` command that can run a domain they supply, read its docs and narration, print its IR, inspect its stores, model-check it, smoke-test it, project diagrams and a CLI, and start the MCP door over stdio. They do not get the example domains, the corpus or the Rust tree, so a sample to point the command at still has to come from somewhere (open item 3).
- The dev directories no longer ship, so the installed gem is smaller and its `lib/` no longer contains code that raises on first use. Anyone who required those files from an installed gem loses that; `lib/hecks.rb` itself requires none of them except `hecks/corpus`, which becomes lazy.
- Executable names become public API under the 1.0 stability promise unless this ADR or a follow-up says otherwise (open item 5). Choosing the subcommand names is therefore a compatibility decision, not a cosmetic one.
- `fuzz` needs `QaSettings` to stop raising without `qa/settings.yml`, and `bench` needs `rust/`. Both stay repo-only, which is why they are not in the router.
- Step 1 changes where cache and log files land for every existing user. Old files under the gem directory are simply orphaned.
- The `mcp` subcommand exposes the door from an installed gem. `docs/decisions/0062-mcp-servers-need-real-authentication-before-any-network-transport.md` still holds: the door is stdio-only and its identity is caller-asserted.

## Alternatives considered

- **Runtime gem plus `hecks-dev` now.** The seam exists, but it buys two release trains and the corpus coupling to untangle, and `hecks-dev` would still need `rust/` and `qa/`, so it would not install cleanly either. Deferred until the dev tools have outside users.
- **Single gem plus an executable that ships everything.** Least churn, but dev code still ships and still raises on a gem install, and the package keeps directories an evaluator can never use.
- **Do nothing.** No risk, but an evaluator gets no command and the two runtime writes into the gem directory remain.

## Open items

These are the maintainer questions from the distribution ticket that are still unanswered.

- Are `model_check` and `fuzz` evaluator-facing? This ADR ships `model_check` in the router and keeps `fuzz` repo-only pending the `QaSettings` change, and that placement is provisional.
- Is the MCP door a product surface? If yes, it ships as decided here and MCP door auth (`docs/wayfinder/review-followup/tickets/11-mcp-door-auth.md`) becomes a release blocker for the release that adds `hecks mcp`.
- Should the gem carry a sample domain and corpus so the README can say `gem install` and mean it?
- Are the dependents still pinned to `~> 0.3` dead? If so they do not constrain this change.
- Are the `exe/` names locked as public API under the 1.0 stability promise, or do they stay provisional for a stated period?

## Addendum (2026-09-30): Facade is now Doors

`Hecks::Facade` is now `Hecks::Doors`, and this text's `Hecks::Facade::CliRunner` is `Hecks::Doors::CliRunner` (in `lib/hecks/doors/cli_runner.rb`). `Surface` is `Doors::RubyDoor`, and the MCP door (`Hecks::Doors::McpDoor`, with its `McpDoorScope`) moved from `lib/hecks/cli/` to sit beside the others. The boot keyword `install_facade:` is `install_doors:`. The old constants and keyword still work for one release and warn; generated launchers pick up the new names when regenerated with `hecks project_cli`.
