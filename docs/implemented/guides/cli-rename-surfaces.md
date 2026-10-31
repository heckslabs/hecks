# Where command names live outside the launcher

ADR 0163 renames and collapses commands in 7.0.0: a bang on every command, one command per family
(`Build.build! target=`), adapter words out of aggregate names (`PullRequest` to `ReviewRequest`,
`Commit` to `Change`, `Checkout` to `Workspace`, `PushTrain` to `SendTrain`), and the positional
forms of `Hecks::CLI` retired. The launcher and the MCP door follow the bluebook, so they rename
themselves. This page lists every other place a command or query name is written down, so the
7.0.0 sweep (ADR 0163 plan step 5) and the rename table (step 26) know what to touch.

Each surface is one of two kinds:

- **Projected**: regenerated from the bluebook by a `hecks` command. It follows a rename once the
  command is run again; the sweep runs the command and commits the output.
- **Hand-written**: edited by a person. The sweep rewrites it, and nothing else will.

## Surfaces inside the repository

| Surface | Kind | Names it carries | Paths |
|---|---|---|---|
| Composer command palette | hand-written | `SAFE_COMMANDS`: `model_check_run.model_check`, `operation.run`, `operation.run_behaviors`, `operation.smoke_test`, `operation.refresh_projections`, `fuzz_run.fuzz`, `fuzz_run.bench`, `build.check_conformance`, `build.fuzz_conformance`, `conformance_run.check_engine_agreement`, `conformance_run.measure_doc_coverage`, `kernel_run.measure_kernel_coverage`, `style_run.check_comments`, `style_run.check_rust_comments`, `style_run.check_comments_unchanged`; `ERA_QUERIES`: `introspection.shape`, `era.scaffold_translation`, `era.audit_translation`, `era.compaction` | `lib/hecks/composer/toolbox.rb` |
| Composer page | hand-written | `fuzz_run.fuzz`, `build.fuzz_conformance` in `startJob` calls | `lib/hecks/composer/page.html` |
| Composer catalog | projected at boot | every command and query of the Hecks bluebook, read from the runtime | `lib/hecks/composer/toolbox.rb` (`catalog`) |
| Generated project launcher | projected by `Launch.project_cli!` | the `LEGACY` list (`run docs narrate ir stores model_check smoke_test project_diagrams project_cli mcp`) handed to `Hecks::CLI`; the `names` short spellings | `lib/hecks/cli/project_cli/templates.rb` (`LEGACY_HANDOFF`), `lib/hecks/cli/project_cli/launcher_source.rb`, world `launcher` setting in `lib/hecks/hecks/hecks.world` |
| Gem executable | projected by `Launch.project_cli!` | the same `LEGACY` list | `exe/hecks` |
| MCP server registration | hand-written | loads `Hecks::CLI::Mcp` and `Hecks::CLI::ServeQueryIrMcp` by class, not by launcher name | `.mcp.json` |
| MCP door scope | hand-written | `READER_TOOLS`, `COMMAND_TOOLS` (generic tool names, not command names); `READ_PATH_QUESTIONS`: `inspection_run.read_source`, `inspection_run.outline` | `lib/hecks/adapters/driving/mcp_scope.rb`, `lib/hecks/adapters/driving/mcp_scope/argument_policy.rb` |
| MCP guide cache | cache | the command guide for `tools/list`, keyed by a digest of the domain files and the allowed commands; a rename makes a new key, the old entry is unused | `lib/hecks/adapters/driving/mcp_guide_cache.rb`, `~/.cache/hecks/mcp_guides`, `~/.cache/hecks/mcp_door_guides` |
| Usage cache | cache | the printed help, keyed by a digest of the declarations and the gem; a rename makes a new key | `lib/hecks/adapters/driving/usage_cache.rb`, `~/.cache/hecks` |
| Rails bridge rows | projected by `Launch.project_rails!` | no command names; the `RailsApp` bluebook holds routes and listings, and `hecks-rails` reads the rows | `lib/hecks/rails_app/bluebook/rails_app.bluebook`, `lib/hecks/hecks/adapters/rails_app_files.rb` |
| Rust host HTTP API | hand-written | domain verbs in the dispatch body (`Domain::Aggregate.Verb`), never Hecks tooling names; no `hecks` call | `rust/host/src/server.rs`, `rust/host/src/payments.rs` |
| hecks-client package | hand-written | domain verbs and queries of the client's own domain; no Hecks tooling names | `packages/hecks-client/src/client.ts` |
| VS Code extension | hand-written | `hecks-lsp` and `hecks-parse` binary names; no command names | `editors/vscode/extension.js`, `editors/vscode/package.json`, `editors/vscode/README.md` |
| Language server | hand-written | runs `hecks-parse bluebook`; no launcher command names | `rust/lsp/src/diagnostics.rs`, `rust/lsp/src/main.rs` |
| Tools page | projected by `RegenerationRun.project_tools_doc!` inside its markers, hand-written prose outside them | every retired-script command, positional forms included (`hecks ir`, `hecks stores`, `hecks run`) | `docs/tools.md` (markers `generated:begin` and `generated:end`) |
| Workflows, generated | projected by `RegenerationRun.project_ci_pipeline!` and `project_lanes!` | `test_suite_run.shard_specs`, `promotion_run.promote`, `promotion_run.watch` | `.github/workflows/ci-rspec.yml`, `lane-watch.yml`, `promote.yml`, `publish-host.yml`, `publish-host-arm64.yml` |
| Workflows, hand-written | hand-written | `gate_run.gate`, `build.build_wasm`, `build.project_rust`, `regeneration_run.decide_ci_gate`, `regeneration_run.regenerate_corpus`, `test_suite_run.list_io_parallel_specs`, `test_suite_run.stress_concurrency`, `test_suite_run.refresh_runtime_baseline`, all without a bang | `.github/workflows/ci.yml`, `ci-checks.yml`, `ci-postgres-io-parallel.yml`, `ci-rust-io.yml`, `ci-rust-host.yml`, `cache-warm.yml`, `client-contract.yml`, `fuzz.yml`, `runtime-baseline-refresh.yml`, `release.yml`, `.github/actions/generated-rust/action.yml` |
| Pre-push hook | hand-written | runs the gate through `Hecks::Tools.script("gate", …)`, not the launcher; names `push_train.board!` in a message | `.githooks/pre-push` |
| Edit hooks | hand-written | `style_run.check_comments` without a bang, with `HECKS_ENVIRONMENT=memory` | `.claude/hooks/comment_style_on_edit.sh` |
| Skills | hand-written | `quality_control query sweep.tick`, `quality_control bug.log`, `quality_control ask target.seed`, `hecks run qa/bluebook …`, `hecks model_check`; the construct-creator skill also names four bare verbs the launcher no longer resolves (hoist_local_givens, measure_doc_coverage, project_reference, ir_duplicates, each now under an aggregate), so it is already stale before 7.0.0 | `.claude/skills/hecks_qa/SKILL.md`, `.claude/skills/bluebook-construct-creator/SKILL.md` |
| Guardfile | hand-written | `build.check_conformance` | `Guardfile` |
| Repository guide | hand-written | `style_run.check_comments`, `test_suite_run.run_spec_example!`, `gate_run.gate`, `push_train.board!`, `landing.land`, `conformance_run.check_shape_ledger`, `regeneration_run.regenerate_corpus`, `promotion_run.promote`, `regeneration_run.project_lanes`, `test_suite_run.refresh_runtime_baseline`, `hecks config` | `CLAUDE.md` |
| Contributor and reader docs | hand-written | positional forms (`hecks run`, `hecks model_check`), `push_train.board`, `publishing_run.publish`, `regeneration_run.regenerate_corpus`, and others | `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/running-a-rules-service.md`, `docs/future-features.md`, `docs/benchmarks.md`, `docs/site-routes.md`, `docs/migrating-2-to-3.md`, `docs/implemented/guides/*.md`, `docs/plans/3.0/*.md` |
| Decision records | hand-written, historical | names as they stood when each record was written | `docs/decisions/*.md`, the heaviest being 0080, 0088, 0087, 0141 |
| Specs | hand-written | launcher lines and name lists pinned by the suite | `spec/cli_spec.rb`, `spec/exe_hecks_spec.rb`, `spec/exe_hecks_help_spec.rb`, `spec/hecks_command_table_spec.rb`, `spec/hecks_custodian_table_spec.rb`, `spec/hecks_launcher_defaults_spec.rb`, `spec/hecks_launcher_memory_commands_spec.rb`, `spec/hecks_tools_doc_spec.rb`, `spec/mcp_servers_spec.rb`, `spec/mcp_read_path_policy_spec.rb`, `spec/composer_panels_spec.rb`, `spec/tools_ci_gates_spec.rb`, `spec/tools_lanes_spec.rb`, `spec/gate_ci_stage_spec.rb`, `spec/ci_fuzz_shards_spec.rb`, `spec/hecks_lane_watch_spec.rb`, `spec/launcher_pinned_gems_spec.rb`, `spec/docs_references_spec.rb`, and the rest of the files a search for `exe/hecks` or a quoted `aggregate.verb` finds under `spec/` |
| Fixtures and goldens | projected or pinned | `bundle exec exe/hecks model_check --wait` in the IR golden; a copy of `ci-rspec.yml` | `spec/golden/ir/Bluebook.json`, `spec/fixtures/ci_pipeline/ci-rspec.original.yml`, `spec/corpus/semantics/README.md` |
| Glossary projection | projected by `Introspection.glossary` | `hecks run` in a query's description | the Introspection output, and `~/Projects/hecks-glossary` which builds a site from it |

Three of these need a decision beyond a rewrite:

- `.mcp.json` loads two `Hecks::CLI` classes directly. Retiring `Hecks::CLI` (ADR 0163 decision
  9) removes both MCP servers unless the registration is moved to the launcher (`hecks mcp!` and
  the `Server` aggregate's IR MCP command) first.
- The generated launcher's `LEGACY` list is written by `Launch.project_cli!` into every client
  project's launcher. Emptying the world's `legacy` list is not enough: each client must run
  `project_cli` again after upgrading, or its launcher keeps handing the retired forms to a class
  that no longer exists.
- The Composer's `SAFE_COMMANDS` is an allowlist. After the renames, a stale entry silently stops
  matching, so the palette offers fewer tools and refuses nothing. A spec that checks every entry
  resolves would catch it, the same shape as the everyday-list check (ADR 0163 plan step 49).

## Consumers outside the searched repositories

The first search covered `~/Projects/hecks`, `lifeadelics`, `emaho`, `miette2`, `~/bin` and
`~/.claude`. This search covered every other directory one level under `~/Projects`, the shell
start-up files, `~/.config`, `~/Library/LaunchAgents` and `~/.claude.json`. Hecks checkouts
(`hecks-stage3`, `hecks-editor-demo`, `~/.claude/hecks-train`) were skipped.

| Repository | Files | What the calls are | Examples |
|---|---|---|---|
| `embryonaut_platform` | 9 | queries (`query introspection.shape`, `era.scaffold_translation`, `era.audit_translation`) in a deploy script and the README; commands without a bang (`operation.bootstrap_admin`) and with one (`package.vendor!`, `era.approve_translation!`) in the README; translation edge comments | `deploy/sync/preflight.sh:49`, `README.md:214`, `README.md:316`, `bluebook/embryonaut_platform.bluebook:6`, `bluebook/translations/4-1b26bc.bluebook:4` |
| `embryonaut_platform-adr` | 7 | the same files as `embryonaut_platform`, an older copy | `deploy/sync/preflight.sh:49`, `README.md:149`, `README.md:242` |
| `embryonaut_platform-scheme` | 6 | the same files as `embryonaut_platform`, an older copy | `deploy/sync/preflight.sh` is absent; `README.md:149`, `README.md:196`, `bluebook/translations/3-b83c3e.bluebook:18` |
| `embryonaut_bluebooks` | 3 | `package.check` (a query) in a CI workflow; `package.release` without a bang and `package.verify` in the README and Gemfile | `.github/workflows/versions.yml:27`, `README.md:45`, `README.md:50`, `Gemfile:4` |
| `hecks_ai_training` | 5 | `build.project_rust` and `build.build_host` without a bang, run through `bundle exec hecks` in a script; positional `hecks model_check` and `hecks run` in spec comments | `bin/chess_native:54`, `bin/chess_native:65`, `spec/spec_helper.rb:8`, its conformance spec at line 19, `README.md:541` |
| `hecks-glossary` | 5 | `hecks ask <query>` built by a site generator; `hecks run` copied from a query description | `build/pages.py:562`, `glossary.md:997`, `html/index.html:1253` |
| `personal-cloud` | 1 | `package.verify` (a query) and `package.vendor!` in the README | `README.md:32`, `README.md:39` |
| `lifeadelics_design` | 1 | `package.verify` and `package.vendor!` in a process page | `process/process.html:108`, `process/process.html:117` |
| `embryonaut-company` | 1 | `Operation.run_behaviors!` with a bang, in a README | `engagements/README.md:2` |
| `pizzas_rails` | 1 | positional `hecks run` and `hecks mcp` named in hecksagon comments | `bluebook/pizzas.hecksagon:7`, `bluebook/pizzas.hecksagon:9` |

No call was found in `~/.zshrc`, `~/.zshenv`, `~/.config`, `~/Library/LaunchAgents` or
`~/.claude.json`. `~/bin/hecks-qa` starts a tmux session and names no command. The user hook
`~/.claude/hooks/governed-door` runs the `storehouse` binary, not the launcher.

What the outside calls mean for the sweep:

- The scripts that run (`embryonaut_platform/deploy/sync/preflight.sh`,
  `embryonaut_bluebooks/.github/workflows/versions.yml`, `hecks_ai_training/bin/chess_native`) use
  queries or bang-less commands. Each project pins a hecks version, so they break only when it
  upgrades; the rename table (step 26) keeps them running through the warning window.
- `hecks-glossary` builds `hecks ask …` lines from the IR. Its generator needs the new spelling
  once `ask` leaves; the glossary text itself is projected and follows the next build.
- The three `embryonaut_platform*` directories are copies of one project; a sweep of one is the
  sweep of all three.
- The rest are READMEs and comments, which the rename table does not reach and a reader will
  follow until each project's docs are rewritten.
