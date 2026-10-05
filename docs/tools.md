# The commands

Every job the `bin/` scripts did is a command of the `Hecks` chapter or of a chapter it attaches, and the
`hecks` launcher answers it: `hecks` lists the verbs, `hecks <verb> --help` prints one's usage, and
`hecks <verb> name=value …` runs it. A verb that changes the tree, a database or a registry does nothing
until it is given `--confirm`. The Custodian verbs ship in the installed gem; the Codebase verbs need a
checkout of this repository and refuse without one. The `bin/` script named in the last column is the
script the command replaced: `bin/` was removed in 3.0.0. The QualityControl scripts (`bin/qa_*`) are commands
of the attached QualityControl chapter, spelled `hecks quality_control <verb>`.

Each table below is written by `hecks regeneration_run.project_tools_doc` from the `RetiredScript` rows of
`lib/hecks/language/bluebook/vocabulary.bluebook`, one row per command or query that answers a retired script. A form
is rendered from the command's own arguments, the same projection the launcher parses against: the first argument is
the bare word, `name=` takes the rest, a switch is `--name`, and an argument in brackets is optional or has a default.
A row's `passes` text documents the flags a command hands through to the tool it wraps (its `arguments=` word), and its
`note` stays beside the form. `spec/hecks_adr_command_table_spec.rb` checks that every row's verb is declared and
answers `--help`. A `|` inside a form is escaped as `\|` in the cell.


## Custodian, for clients

<!-- generated:begin tools section=Custodian -->
| launcher | replaces |
|---|---|
| `hecks ir [<domain>] [--translations] [--meta]` | `bin/ir` |
| `hecks introspection.shape <domain>` | `bin/shape` |
| `hecks stores <domain>` | `bin/stores` |
| `hecks introspection.history <domain>` | `bin/history` |
| `hecks introspection.statements <domain> chapter=` | `bin/statements` |
| `hecks narrate [<domain>] [aggregate=]` | `bin/narrate` |
| `hecks docs [<domain>] [aggregate=]` | `bin/docs` |
| `hecks project_diagrams <domain> chapter=` | `bin/project_diagrams` |
| `hecks introspection.glossary <domain> chapter=` | `bin/project_glossary` |
| `hecks model_check [<domains>] [profile=] [--strict]` | `bin/model_check` |
| `hecks run [domain] <verb [name=value …] \| script.json \| - \| '{"steps":[…]}'>` | `bin/run` |
| `hecks operation.refresh_projections <subject>` | `bin/project` |
| `hecks operation.run_behaviors <subject>` | `bin/behaviors` |
| `hecks console [<subject>]` | `bin/console` |
| `hecks operation.follow <domain> [aggregate=] [since=] [wait=] [interval=] [--from-now]` | `bin/follow` |
| `hecks smoke_test [<subject>]` | `bin/smoke_test` |
| `hecks operation.smoke_http [<url>] path= [header=] [scheme=] [payload=] [payload_file=] [health_path=] [state_path=]` | `bin/smoke_http` |
| `hecks host.check_era <host> expected= [timeout=]` | `bin/check_era` |
| `hecks era.merge_tail <domain> [winners=] --confirm` | `bin/merge_tail` |
| `hecks era.reattest <domain> era= --confirm` | `bin/reattest_era` |
| `hecks era.backfill_projections <domain>` | `bin/backfill_era_projections` |
| `hecks era.scaffold_translation <domain>` | `bin/scaffold_translation` |
| `hecks era.audit_translation <domain>`; `hecks era.approve_translation <domain> [snapshot=] [host_version=] [rehearsal=] [rehearsed_at=] --confirm` | `bin/translation_audit` |
| `hecks era.compact <domain> [aggregates=] --confirm` | `bin/compact` |
| `hecks era.compact_heki <domain> [aggregates=] --confirm` | `bin/heki_compact` |
| `hecks package.vendor <package> [from=] [root=] (waits: a refusal exits 1 with its reason on stderr)` | `bin/vendor_bluebook` |
| `hecks project_cli [<domains>]` | `bin/project_cli` |
| `hecks mcp [--stdio]` | `bin/hecks_mcp_door` |
| `hecks build.project_rust <domain>` | `bin/project_rust` |
| `hecks build.build_wasm <domain>` | `bin/project_wasm` |
| `hecks build.build_host <domain> [target=] [stage_dir=]` | `bin/project_host` |
| `hecks build.build_browser_wasm <domain>` | `bin/project_wasm_browser` |
| `hecks build.rust_coverage <module_name> [codegen=]`; `hecks build.check_coverage_allowlist` | `bin/rust_coverage` |
| `hecks build.check_conformance <domain> script= [artifact=]` | `bin/rust_conformance` |
| `hecks build.fuzz_conformance <domain> artifact= [seeds=] [steps=]` | `bin/rust_conformance_fuzz` |
| `hecks fuzz_run.fuzz [<domain>] [seeds=] [steps=] [workers=] [adapter=]` | `bin/fuzz` |
| `hecks fuzz_run.generate_sequence <domain> [seed=] [steps=] [adversarial=]` | `bin/generate` |
| `hecks fuzz_run.bench [<domains>] [targets=] [iterations=] [warmup=] [runs=] [rust_binary=] [format=] [output=]` | `bin/bench` |
| `hecks era.hold_first <domain> --confirm` | (new: no `bin/` script) |
<!-- generated:end tools -->

## Deploy, for clients

<!-- generated:begin tools section=Deploy -->
| launcher | replaces |
|---|---|
| `hecks deploy recipe.project <domain> [tenant=] [schema=] [out=] [environment=]` | `bin/project_deploy` |
| `hecks deploy makefile_check.lint [<makefiles>]` | `bin/lint_deploy_recipes` |
| `hecks deploy template_comparison.diff <before> after= [--json] [--strict]` | `bin/deploy_template_diff` |
| `hecks deploy oidc_manifest.project_oidc [<domains>]` | `bin/project_oidc` |
| `hecks deploy tenant.provision <directory> slug= domain= realm= schema= database= [adapter=]`; `hecks deploy tenant.reprovision <to> directory= database= [adapter=]` | `bin/project_tenant` |
<!-- generated:end tools -->

## Site, for clients

<!-- generated:begin tools section=Site -->
| launcher | replaces |
|---|---|
| `hecks site site_projection.project_site <domain> [out=] [template=] [extension=] [--check]` | (new: no `bin/` script) |
<!-- generated:end tools -->

`project_site` has no retired script to point at, so its row names `(new)` for the script; see
`docs/site-routes.md`. It writes `routes.ts` (`routes.mts` with `extension=mts`, for a commonjs package) and, when the
project declares an edge, rewrites the marked regions of the infrastructure template with the CloudFront behaviours and,
unless the Edge row says `alb: false`, the load balancer's listener rules. It runs from a client project with the installed
gem, no checkout: `<project>` holds `bluebook/`, `out=` is any directory for `routes.ts` (default `<project>/generated`) and
`template=` is any file to rewrite in place (default the Edge row's `template:`).

## Codebase, for maintaining Hecks

<!-- generated:begin tools section=Codebase -->
| launcher | replaces |
|---|---|
| `hecks language_run.project_model --confirm` | `bin/project_model` |
| `hecks language_run.project_vocabulary --confirm` | `bin/project_vocabulary` |
| `hecks language_run.project_rust_vocabulary --confirm` | `bin/project_rust_vocabulary` |
| `hecks language_run.project_refusal_wording --confirm` | `bin/project_refusal_wording` |
| `hecks language_run.project_reserved_names --confirm` | `bin/project_reserved_names` |
| `hecks language_run.project_parser_table --confirm` | `bin/project_parser_table` |
| `hecks language_run.project_bootstrap_table --confirm` | `bin/project_bootstrap_table` |
| `hecks language_run.project_field_hints --confirm` | `bin/project_field_hints` |
| `hecks language_run.project_expression_tables [--stdout] --confirm` | `bin/expression_projection` |
| `hecks language_run.project_reference --confirm` | `bin/reference` |
| `hecks language_run.word_status`; `hecks language_run.propose <word> context= [body=] [inner=] [opens=] [fills=] --confirm`; `hecks language_run.admit <word> context= --confirm`; `hecks language_run.deprecate <word> context= --confirm`; `hecks language_run.retire <word> context= --confirm`; `hecks language_run.rename <word> context= new_name= --confirm`; `hecks language_run.propose_argument <word> context= kind= [required=] [at=] [named=] [fills=] [pairs_shape=] --confirm`; `hecks language_run.admit_argument <word> context= [at=] [named=] --confirm`; `hecks language_run.deprecate_argument <word> context= [at=] [named=] --confirm`; `hecks language_run.retire_argument <word> context= [at=] [named=] --confirm` | `bin/evolve` |
| `hecks kernel_run.project_kernel_capabilities --confirm` | `bin/project_kernel_capabilities` |
| `hecks kernel_run.measure_kernel_coverage` | `bin/rust_kernel_coverage` |
| `hecks conformance_run.check_engine_agreement` | `bin/check_engine_agreement` |
| `hecks conformance_run.measure_doc_coverage` | `bin/doc_coverage` |
| `hecks conformance_run.argument_gate_matrix --confirm` | `bin/argument_gate_matrix` |
| `hecks regeneration_run.regenerate_corpus [--check] --confirm` | `bin/regen_codegen_domains` |
| `hecks style_run.report_comments <paths> [only=] [top=] [--json]`; `hecks style_run.check_comments <paths> [only=]`; `hecks style_run.fix_comments <paths> [only=] --confirm`; `hecks style_run.write_comment_baseline [<paths>] --confirm`; `hecks style_run.check_comments_unchanged <ref> [paths=]` | `bin/standardize_comments` |
| `hecks style_run.report_rust_comments <paths> [only=] [top=] [--json]`; `hecks style_run.check_rust_comments <paths> [only=]`; `hecks style_run.fix_rust_comments <paths> [only=] --confirm` | `bin/standardize_comments_rust` |
| `hecks style_run.canonicalise <file>` | `bin/canonicalise` |
| `hecks codemod_run.hoist_local_givens --confirm` | `bin/codemod_hoist_local_givens` |
| `hecks codemod_run.drop_implicit_append_fields --confirm` | `bin/codemod_implicit_append_fields` |
| `hecks test_suite_run.shard_specs <group> groups= [runtime_log=]` | `bin/rspec_shard_files` |
| `hecks test_suite_run.list_io_parallel_specs <exclude> [tags=] [check=]`; `hecks test_suite_run.write_io_parallel_spec_list <exclude> [tags=] write= --confirm` | `bin/rspec_io_parallel_files` |
| `hecks test_suite_run.refresh_runtime_baseline [<workers>] [from_run=] --confirm` | `bin/refresh_rspec_runtime_baseline` |
| `hecks test_suite_run.run_spec_example <file> example=` | `bin/spec_example` |
| `hecks test_suite_run.stress_concurrency [<runs>] [parallel=] [seed_start=]` | `bin/stress_concurrency_specs` |
| `hecks test_suite_run.regenerate_legacy_fixtures --confirm` | `bin/regenerate_persistence_legacy_fixtures` |
| `hecks test_suite_run.seed_semantics_corpus [<fixture>]` | `bin/seed_semantics_corpus` |
| `hecks test_suite_run.record_pattern_cases` | `bin/pattern-cases` |
| `hecks corpus_run.rust_domains`; `hecks corpus_run.regen_order`; `hecks corpus_run.corpus_rust_coverage` | `bin/corpus` |
| `hecks corpus_run.ir_constructs [<names>]`; `hecks corpus_run.ir_duplicates [<domains>] [--meta]`; `hecks corpus_run.ir_impact <name> field=` | `bin/query_ir` |
| `hecks corpus_run.serve_query_ir_mcp` | `bin/hecks_query_ir_mcp` |
| `hecks corpus_run.present [<port>]` | `bin/present` |
| `hecks publishing_run.publish [--gem-only] [--npm-only] [--npm-local] [--no-wait] --confirm (without --confirm, the old --dry-run)` | `bin/release` |
| `hecks publishing_run.publish_gem --confirm` | `bin/release_gem` |
| `hecks gate_run.gate <stage> [only=]` | (new: no `bin/` script) |
<!-- generated:end tools -->

## Releasing from CI

`.github/workflows/release.yml` cuts a release, so it does not need `hecks publishing_run.publish --confirm` run
from a laptop. It starts when a commit on `main` changes `lib/hecks/version.rb` (the merged release PR), or by
hand with `gh workflow run release.yml -f tag=vX.Y.Z`. It refuses unless `Hecks::VERSION`,
`packages/hecks-client`, `rust/host/HECKS_RELEASE` and a `## [X.Y.Z]` heading in `CHANGELOG.md` agree. It then
tags the commit, pushes the gem (repository secret `RUBYGEMS_API_KEY`), starts `publish-client.yml` for the npm
package, and creates the GitHub Release from the CHANGELOG section. Each step is skipped when its result already
exists, so re-running a release that stopped halfway finishes it, and a tag that stands on another commit is an
error, never moved. The local command remains for a release made by hand.

## QualityControl, for maintaining Hecks

<!-- generated:begin tools section=QualityControl -->
| launcher | replaces |
|---|---|
| `hecks quality_control sweep.tick` | `bin/qa_tick` |
| `hecks quality_control sweep.run [<target>] [arguments="--all --seeds N --steps N --adversarial F --role-draw F --dry-run F --self-consistency BOOL --modes a,b --persistence-parity --no-parity"]`; `hecks quality_control target.release <to> now= next_streak= capabilities= yield_score=` | `bin/qa_sweep` |
| `hecks quality_control clearance.check_pull_requests` | `bin/qa_pr_check` |
| `hecks quality_control patch.open <bug> number= url= branch= commit= title= now=`; `hecks quality_control improvement.open [<angle>] number= url= branch= title= now=` | `bin/qa_open_pr` |
| `hecks quality_control bug.log <sweep> reference= sequence= title= demonstration= symptom= expectation= submitter= [tags=] [name=] [reproduced=]` | `bin/qa_log_bug` |
| `hecks quality_control angle.seed` | `bin/qa_seed_angles` |
| `hecks quality_control target.seed` | `bin/qa_seed_targets` |
| `hecks quality_control target.check_generated_domains [arguments="--domains 3 --start N --forms a,b --seeds 5 --steps 25 --adversarial 0.3 --rust --shrink-budget 200 --domain-shrink-budget 40 --promote dir --name N --from-dials --blueprint F --source F"]` | `bin/qa_generated_domains` |
| `hecks quality_control target.mine_combinations [arguments="--candidates 3 --rust --seeds 5 --steps 25 --adversarial 0.3 --repair-rounds 1 --agent CMD --from DIR --against PATH --brief"]` | `bin/qa_mine_combinations` |
| `hecks quality_control target.judge_novelty <domain> [arguments="--against PATH …"]` | `bin/qa_domain_novelty` |
| `hecks quality_control target.discover_external_domains [arguments="--projects-dir ~/Projects --max-depth 3 --known-path PATH …"]` | `bin/qa_discover_external_domains` |
| `hecks quality_control sweep.migrate_ledger_from_heki <domain> data= [arguments="[aggregate …] --force"] (a dry run without --force)` | `bin/qa_postgres_migrate` |
| `hecks quality_control sweep.create_ledger_role <database> [role=]` | `bin/qa_postgres_role` |
| `hecks quality_control sweep.race <domain> database= schema= verb= step_arguments= (not user-facing; ProcessPool starts it)` | `bin/qa_concurrency_racer` |
<!-- generated:end tools -->
