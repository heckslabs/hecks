# The commands

Every job the `bin/` scripts did is a command of the `Hecks` chapter or of a chapter it attaches, and the
`hecks` launcher answers it: `hecks` lists the verbs, `hecks <verb> --help` prints one's usage, and
`hecks <verb> name=value …` runs it. A verb that changes the tree, a database or a registry does nothing
until it is given `--confirm`. The Custodian verbs ship in the installed gem; the Codebase verbs need a
checkout of this repository and refuse without one. The `bin/` script named in the last column is a shim
over the same command until `bin/` is removed. The QualityControl scripts (`bin/qa_*`) are not commands yet.

Each launcher form below is the ADR 0080 section 7 table; `spec/hecks_adr_command_table_spec.rb` checks that
every row's verb is declared and answers `--help`.


## Custodian, for clients

| launcher | replaces |
|---|---|
| `hecks ir [domain] [--translations] [--meta]` | `bin/ir` |
| `hecks shape <domain>` | `bin/shape` |
| `hecks stores <domain>` | `bin/stores` |
| `hecks history <domain>` | `bin/history` |
| `hecks statements <domain> chapter=Name` | `bin/statements` |
| `hecks narrate [domain] [aggregate=Name]` | `bin/narrate` |
| `hecks docs [domain] [aggregate=Name]` | `bin/docs` |
| `hecks project_diagrams <domain-path> <ChapterName>` | `bin/project_diagrams` |
| `hecks glossary <domain> chapter=Name` | `bin/project_glossary` |
| `hecks model_check [domains=a,b] [--strict] [profile=client]` | `bin/model_check` |
| `hecks run [domain] steps.json`, or `hecks run [domain] <verb> name=value …` | `bin/run` |
| `hecks refresh_projections <domain>` | `bin/project` |
| `hecks run_behaviors <path>` | `bin/behaviors` |
| `hecks console [subject=<domain>]` | `bin/console` |
| `hecks follow <domain> [aggregate=Name] [interval=0.5] [--from-now]` | `bin/follow` |
| `hecks smoke_test [domain]` | `bin/smoke_test` |
| `hecks smoke_http path=/p secret=… [url=] [header=] [scheme=timestamped] [payload=] [payload_file=] [health_path=] [state_path=]` | `bin/smoke_http` |
| `hecks check_era <url> expected=era-file [timeout=10]` | `bin/check_era` |
| `hecks merge_tail <domain> winners=id:old,id:new --confirm` | `bin/merge_tail` |
| `hecks reattest <domain> era=N --confirm` | `bin/reattest_era` |
| `hecks backfill_projections <domain>` | `bin/backfill_era_projections` |
| `hecks scaffold_translation <domain>` | `bin/scaffold_translation` |
| `hecks audit_translation <domain>`; `hecks approve_translation <domain> --confirm` | `bin/translation_audit` |
| `hecks compact <domain> [aggregates=A,B] --confirm` | `bin/compact` |
| `hecks compact_heki <domain> [aggregates=A,B] --confirm` | `bin/heki_compact` |
| `hecks vendor <package[@version]> [from=path] [root=path]` | `bin/vendor_bluebook` |
| `hecks project_cli [domains=a,b]` | `bin/project_cli` |
| `hecks mcp` (stdio) | `bin/hecks_mcp_door` |
| `hecks project_rust <domain>` | `bin/project_rust` |
| `hecks build_wasm <domain>` | `bin/project_wasm` |
| `hecks build_browser_wasm <domain>` | `bin/project_wasm_browser` |
| `hecks rust_coverage <module> [codegen=ruby]`; `hecks check_coverage_allowlist` | `bin/rust_coverage` |
| `hecks check_conformance <domain> script=steps.json [artifact=native]` | `bin/rust_conformance` |
| `hecks fuzz_conformance <domain> artifact=native [seeds=10] [steps=25]` | `bin/rust_conformance_fuzz` |
| `hecks fuzz [domain] [seeds=20] [steps=30] [workers=] [adapter=memory]` | `bin/fuzz` |
| `hecks generate_sequence <domain> [seed=1] [steps=30] [adversarial=0.0]` | `bin/generate` |
| `hecks bench [domains=pizzas,banking] [targets=] [iterations=1000] [warmup=200] [runs=3] [rust_binary=] [format=markdown] [output=]` | `bin/bench` |

## Deploy, for clients

| launcher | replaces |
|---|---|
| `hecks deploy project <domain> [tenant=] [schema=] [out=] [environment=]` | `bin/project_deploy` |
| `hecks deploy lint [makefiles=a,b]` | `bin/lint_deploy_recipes` |
| `hecks deploy diff before=a.yaml after=b.yaml [--json] [--strict]` | `bin/deploy_template_diff` |
| `hecks deploy project_oidc [domains=a,b]` | `bin/project_oidc` |
| `hecks deploy provision <domain_dir> slug=s domain= realm= schema= database= [adapter=PostgresEra]` | `bin/project_tenant` |

## Codebase, for maintaining Hecks

| launcher | replaces |
|---|---|
| `hecks project_model` | `bin/project_model` |
| `hecks project_vocabulary` | `bin/project_vocabulary` |
| `hecks project_rust_vocabulary` | `bin/project_rust_vocabulary` |
| `hecks project_refusal_wording` | `bin/project_refusal_wording` |
| `hecks project_reserved_names` | `bin/project_reserved_names` |
| `hecks project_parser_table` | `bin/project_parser_table` |
| `hecks project_bootstrap_table` | `bin/project_bootstrap_table` |
| `hecks project_field_hints` | `bin/project_field_hints` |
| `hecks project_expression_tables [--stdout]` | `bin/expression_projection` |
| `hecks project_reference` | `bin/reference` |
| `hecks word_status`; `hecks propose <word> context=X [body=none] [inner=] [opens=] [fills=]`; `hecks rename <word> context=X to=Y`; `hecks propose_argument <word> context=X kind=K [required=false] [at=N] [named=] [pairs_shape=]`; the rest take `<word> context=X` | `bin/evolve` |
| `hecks project_kernel_capabilities` | `bin/project_kernel_capabilities` |
| `hecks measure_kernel_coverage` | `bin/rust_kernel_coverage` |
| `hecks check_engine_agreement` | `bin/check_engine_agreement` |
| `hecks measure_doc_coverage` | `bin/doc_coverage` |
| `hecks argument_gate_matrix [--confirm]` (writes only with `--confirm`) | `bin/argument_gate_matrix` |
| `hecks regenerate_corpus [--check]` | `bin/regen_codegen_domains` |
| `hecks report_comments paths=a,b [only=] [--json] [top=20]`; `hecks check_comments paths=…`; `hecks fix_comments paths=… --confirm`; `hecks write_comment_baseline --confirm`; `hecks check_comments_unchanged ref=REF` | `bin/standardize_comments` |
| `hecks report_rust_comments paths=…`; `hecks check_rust_comments paths=…`; `hecks fix_rust_comments paths=… --confirm` | `bin/standardize_comments_rust` |
| `hecks canonicalise <file.json>` | `bin/canonicalise` |
| `hecks hoist_local_givens --confirm` | `bin/codemod_hoist_local_givens` |
| `hecks drop_implicit_append_fields --confirm` | `bin/codemod_implicit_append_fields` |
| `hecks shard_specs group=1 groups=N [runtime_log=]` | `bin/rspec_shard_files` |
| `hecks list_io_parallel_specs exclude=REGEX [tags=] [check=file] [write=file]` | `bin/rspec_io_parallel_files` |
| `hecks refresh_runtime_baseline [workers=6] [from_run=ID]` | `bin/refresh_rspec_runtime_baseline` |
| `hecks run_spec_example file=path example=text` | `bin/spec_example` |
| `hecks stress_concurrency [runs=30] [parallel=] [seed_start=1]` | `bin/stress_concurrency_specs` |
| `hecks regenerate_legacy_fixtures --confirm` | `bin/regenerate_persistence_legacy_fixtures` |
| `hecks seed_semantics_corpus` | `bin/seed_semantics_corpus` |
| `hecks record_pattern_cases` | `bin/pattern-cases` |
| `hecks rust_domains`; `hecks regen_order`; `hecks corpus_rust_coverage` | `bin/corpus` |
| `hecks ir_constructs [names=a,b]`; `hecks ir_duplicates [domains=a,b] [--meta]`; `hecks ir_impact name=N field=F` | `bin/query_ir` |
| `hecks serve_query_ir_mcp` (stdio) | `bin/hecks_query_ir_mcp` |
| `hecks present [port=4567]` | `bin/present` |
| `hecks publish [--gem-only] [--npm-only] [--npm-local] [--no-wait] --confirm` (without `--confirm`, the old `--dry-run`) | `bin/release` |
| `hecks publish_gem --confirm` | `bin/release_gem` |
