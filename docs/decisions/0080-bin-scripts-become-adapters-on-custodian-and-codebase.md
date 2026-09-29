# Bin scripts become adapters on the Custodian and Codebase bluebooks

**Status:** Proposed. Date: 2026-09-28. Builds on [ADR 0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md) (what ships in the gem) and [ADR 0053](0053-transactional-outbox-for-domain-events-and-effects.md) (the journal every command writes). Nothing below is built yet.

## Context

`bin/` holds 92 hand-written Ruby scripts. Each one parses its own arguments, performs its own checks, shells out to `git`, `gh`, `cargo`, RubyGems or the filesystem inline, and reports by printing and exiting. None of what they do reaches a journal, so a check that starts failing leaves no history, and the rules they enforce are invisible to `model_check`.

The pieces for doing this the domain way already exist:

- `bin/project_cli` (`lib/hecks/cli/project_cli.rb`) generates a launcher beside each domain. The launcher boots the domain and hands `ARGV` to `Hecks::Facade::CliRunner`, which projects verbs, arguments and refusals from the bluebook each time it runs.
- A hecksagon declares ports, and an `adapters/` directory binds them. `qa/bluebook/quality_control.hecksagon` declares the `CI` port and `qa/adapters/github_checks` binds it.
- `lib/hecks/deploy/bluebook/` shows a bluebook that lives inside `lib/`.
- ADR 0066's `dev_tooling` pattern in `hecks.gemspec` shows how to keep repository-only code under `lib/` out of the package.

## Decision

Every bin script becomes a command or query on a bluebook, with its outside-world work in adapters behind ports. All 92 move in one pass.

### 1. A bin becomes adapters plus a generated launcher

- **Rules move into the bluebook.** A refusal a script checks by hand becomes a `given` on the command, with a message that states the rule.
- **Side effects move into driven adapters.** Calls to `git`, `gh`, `cargo`, `gem`, `npm`, Postgres, AWS and the filesystem sit behind ports the hecksagon declares, bound in the domain's `adapters/` directory, in the same shape as `qa/adapters/github_checks`.
- **Results become events.** A check that printed and exited answers with a passed or failed event, so the journal records when a result changed.
- **The entry point is generated.** `project_cli` writes the launcher beside each domain. Nobody writes a launcher by hand, and `bin/<name>` is deleted.

### 2. Two new bluebooks, split by whether they ship

| Bluebook | Lives in | Ships in the gem | Holds |
| --- | --- | --- | --- |
| Custodian | `lib/hecks/custodian/` | Yes | Operating any domain: introspection, running, eras and journals, packages, doors |
| Codebase | `lib/hecks/codebase/` | No, added to the gemspec `dev_tooling` pattern | Working on this repository: language self-hosting, Rust generation, conformance, style, codemods, test suite, fuzzing, release |

Each directory holds `<name>.bluebook`, `<name>.hecksagon`, `adapters/` and the generated launcher. `exe/hecks` gains a `custodian` route through `CliRunner`, so an installed gem reaches Custodian without a checkout.

A script whose concern already has a bluebook joins that bluebook instead: the `qa_*` scripts go to QualityControl and the deploy scripts go to Deploy.

### 3. Where each script goes

| Bluebook | Aggregate | Scripts |
| --- | --- | --- |
| Custodian | Introspection | `ir`, `shape`, `stores`, `history`, `statements`, `narrate`, `docs`, `project_diagrams`, `project_glossary`, `model_check` |
| Custodian | Operation | `run`, `project`, `behaviors`, `console`, `follow`, `smoke_test`, `smoke_http` |
| Custodian | Era | `check_era`, `merge_tail`, `reattest_era`, `backfill_era_projections`, `scaffold_translation`, `translation_audit`, `compact`, `heki_compact` |
| Custodian | Package | `vendor_bluebook` |
| Custodian | Door | `project_cli`, `hecks_mcp_door` |
| Deploy (existing) | Deploy | `project_deploy`, `lint_deploy_recipes`, `deploy_template_diff`, `project_oidc`, `project_tenant` |
| Codebase | Language | `project_model`, `project_vocabulary`, `project_rust_vocabulary`, `project_refusal_wording`, `project_reserved_names`, `project_parser_table`, `project_bootstrap_table`, `project_kernel_capabilities`, `project_field_hints`, `expression_projection`, `reference`, `evolve` |
| Codebase | RustBuild | `project_rust`, `project_wasm`, `project_wasm_browser`, `regen_codegen_domains` |
| Codebase | Conformance | `rust_conformance`, `rust_conformance_fuzz`, `rust_coverage`, `rust_kernel_coverage`, `check_engine_agreement`, `doc_coverage`, `argument_gate_matrix` |
| Codebase | Style | `standardize_comments`, `standardize_comments_rust`, `canonicalise` |
| Codebase | Codemod | `codemod_hoist_local_givens`, `codemod_implicit_append_fields` |
| Codebase | TestSuite | `rspec_shard_files`, `rspec_io_parallel_files`, `refresh_rspec_runtime_baseline`, `spec_example`, `stress_concurrency_specs`, `regenerate_persistence_legacy_fixtures`, `seed_semantics_corpus`, `pattern-cases` |
| Codebase | Fuzzing | `fuzz`, `generate`, `bench` |
| Codebase | Corpus | `corpus`, `query_ir`, `hecks_query_ir_mcp`, `present` |
| Codebase | Release | `release`, `release_gem` |
| QualityControl (existing) | as listed per script | `qa_tick`, `qa_sweep`, `qa_pr_check`, `qa_open_pr`, `qa_log_bug`, `qa_seed_angles`, `qa_seed_targets`, `qa_generated_domains`, `qa_mine_combinations`, `qa_domain_novelty`, `qa_discover_external_domains`, `qa_postgres_migrate`, `qa_postgres_role`, `qa_concurrency_racer` |

Release goes to Codebase rather than Custodian because it publishes this repository's gem, and the gem does not need to carry it.

`project_refusal_wording` is an alias for `project_rust_vocabulary`; it becomes a second name for the same Language command, not a command of its own.

### 4. QualityControl

The rules hand-coded in `qa_open_pr` and `qa_pr_check` become `given`s on `Patch.Open` and `Improvement.Open`: the branch-prefix check, the per-day PR cap, a fix commit being an ancestor of `HEAD`, and the angle being under investigation. Their `git` and `gh` calls move into a `GitPr` adapter. The declared `IssueTracker` port gets a bound adapter.

## Consequences

- Checks and lifecycle actions leave a history in the journal, so a regression such as the runtime baseline going stale shows up as an event instead of passing unnoticed.
- `model_check` can see the rules that were hidden inside scripts, including QualityControl's PR-opening rules.
- One launcher per bluebook replaces 92 separate front doors, and each door's help text comes from the bluebook.
- Every reference to `bin/<name>` changes in the same pass: `.github/workflows/`, `Makefile`s generated by `project_deploy`, pre-commit and pre-push hooks, specs that shell out, `docs/`, the README, and the `exe/hecks` routes from ADR 0066.
- Some scripts are processes by nature: `console` and `follow` are interactive, `qa_concurrency_racer` and `stress_concurrency_specs` must run as separate OS processes, and `qa_tick` forks other steps. Their commands exist, but the adapter behind them still starts the process or session, and the journal records that it ran, not what the session did.
- `project_cli` generates every launcher, including Custodian's own. The `exe/hecks project_cli` route stays as the bootstrap that produces the first one.
- Custodian code in `lib/` loads only when its launcher or the `custodian` route runs, not from `lib/hecks.rb`, so boot cost for an ordinary domain does not change.
- `spec/gemspec_packaging_spec.rb` gains the rule that `lib/hecks/codebase/` stays out of the package and `lib/hecks/custodian/` goes in.

## Alternatives considered

- **Hand-written launchers per command.** Keeps `bin/<name>` as a short script that dispatches one verb. Rejected: `project_cli` already generates a launcher from the bluebook, and hand-written ones drift from it.
- **One bluebook per concern** (Release, RuntimeBaseline, LanguageContract, DocCoverage, Codemod, and so on). Rejected: it produces a dozen front doors and a dozen hecksagons with the same wiring. Aggregates inside two bluebooks keep the distinctions without the sprawl.
- **Repository-level `custodian/` and `codebase/` directories, like `qa/`.** Rejected in favour of `lib/hecks/`, so the shipped half sits beside the runtime it operates on and the gemspec filter decides what ships.
- **Phased migration** (Release first, then checks, then Codebase). Rejected in favour of one pass, so the repository never has two ways to run the same tool.
- **Leave the scripts as they are.** Rejected: results keep leaving no history, and the rules stay out of the model.

## Open items

- Which store each bluebook persists to. A shared history of CI checks needs a durable store that CI can reach. Local runs may use Sqlite under `Hecks::CacheDir`.
- The exact command names and arguments for each script, written out per aggregate before the migration starts.
- Whether `rust/host` needs any of Custodian, or whether it stays Ruby-only operational tooling.
- Where the new bluebooks' specs live: beside each bluebook as `.behaviors` files, or under `spec/`.
