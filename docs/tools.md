# The commands

Every job the `bin/` scripts did is a command of the `Hecks` chapter or of a chapter it attaches, and the
`hecks` launcher answers it: `hecks` lists the verbs, `hecks <verb> --help` prints one's usage, and
`hecks <verb> name=value …` runs it. A verb that changes the tree, a database or a registry does nothing
until it is given `--confirm`. The Custodian verbs ship in the installed gem; the Codebase verbs need a
checkout of this repository and refuse without one. The `bin/` script named in the last column is the
script the command replaced: `bin/` was removed in 3.0.0. The QualityControl scripts (`bin/qa_*`) are commands
of the attached QualityControl chapter, spelled `hecks quality_control <verb>`.

Each launcher form below is the form `exe/hecks` executes, copied from `lib/hecks/three_zero/forms.yml`. Those
are the positional spellings, which can differ from the ADR 0080 section 7 spelling of a command's arguments.
`spec/hecks_tools_doc_spec.rb` pins every row to that file, and `spec/hecks_adr_command_table_spec.rb` checks
that every row's verb is declared and answers `--help`. A `|` inside a form is escaped as `\|` in the cell.


## Custodian, for clients

| launcher | replaces |
|---|---|
| `hecks ir <domain> [--translations] \| hecks ir --meta` | `bin/ir` |
| `hecks shape <domain>` | `bin/shape` |
| `hecks stores <domain>` | `bin/stores` |
| `hecks history <domain>` | `bin/history` |
| `hecks statements <domain> chapter=Name` | `bin/statements` |
| `hecks narrate [domain-path] [aggregate]` | `bin/narrate` |
| `hecks docs [domain-path] [aggregate]` | `bin/docs` |
| `hecks project_diagrams <domain-path> <ChapterName>` | `bin/project_diagrams` |
| `hecks glossary <domain> chapter=Name` | `bin/project_glossary` |
| `hecks model_check [--strict] [--profile client] [<domain> …]` | `bin/model_check` |
| `hecks run [domain] <verb [name=value …] \| script.json \| - \| '{"steps":[…]}'>` | `bin/run` |
| `hecks refresh_projections subject=<domain>` | `bin/project` |
| `hecks run_behaviors subject=<path>` | `bin/behaviors` |
| `hecks console [subject=<domain>]` | `bin/console` |
| `hecks follow <domain> [aggregate=Name] [since=N] [interval=0.5] [wait=N] [--from-now] [--stream]` | `bin/follow` |
| `hecks smoke_test [domain]` | `bin/smoke_test` |
| `hecks smoke_http path=/p [url=] [header=] [scheme=timestamped] [payload=] [payload_file=] [health_path=] [state_path=]` | `bin/smoke_http` |
| `hecks check_era <url> expected=era-file [timeout=10]` | `bin/check_era` |
| `hecks merge_tail <domain> winners=id:old,id:new --confirm` | `bin/merge_tail` |
| `hecks reattest <domain> era=N --confirm` | `bin/reattest_era` |
| `hecks backfill_projections <domain>` | `bin/backfill_era_projections` |
| `hecks scaffold_translation <domain>` | `bin/scaffold_translation` |
| `hecks audit_translation <domain>`; `hecks approve_translation <domain> [snapshot=] [host_version=] [rehearsal=pass\|fail] [rehearsed_at=] --confirm` | `bin/translation_audit` |
| `hecks compact <domain> [aggregates=A,B] --confirm` | `bin/compact` |
| `hecks compact_heki <domain> [aggregates=A,B] --confirm` | `bin/heki_compact` |
| `hecks vendor <package[@version]> [from=path] [root=path]` | `bin/vendor_bluebook` |
| `hecks project_cli [domain-path …]` | `bin/project_cli` |
| `hecks mcp [--stdio]` | `bin/hecks_mcp_door` |
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
| `hecks deploy provision <domain_dir> slug=s domain= realm= schema= database= [adapter=PostgresEra]`; `hecks deploy reprovision <tenant> directory= database= [adapter=PostgresEra]` | `bin/project_tenant` |

## Site, for clients

| launcher | replaces |
|---|---|
| `hecks site project_site <project> [out=] [--check]` | (new: no `bin/` script) |

`project_site` has no retired script to point at, so it has no row in `lib/hecks/three_zero/forms.yml`; see
`docs/site-routes.md`. It writes `routes.ts` and, when the project declares an edge, rewrites the marked regions
of the infrastructure template with the CloudFront behaviours and the load balancer's listener rules.

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
| `hecks word_status`; `hecks propose <word> context=X [body=none] [inner=] [opens=] [fills=]`; `hecks admit\|deprecate\|retire <word> context=X`; `hecks rename <word> context=X new_name=Y`; `hecks propose_argument <word> context=X kind=K [required=false] [at=N] [named=] [fills=] [pairs_shape=]`; `hecks admit_argument\|deprecate_argument\|retire_argument <word> context=X [at=N] [named=]` | `bin/evolve` |
| `hecks project_kernel_capabilities` | `bin/project_kernel_capabilities` |
| `hecks measure_kernel_coverage` | `bin/rust_kernel_coverage` |
| `hecks check_engine_agreement` | `bin/check_engine_agreement` |
| `hecks measure_doc_coverage` | `bin/doc_coverage` |
| `hecks argument_gate_matrix [--confirm] (writes only with --confirm)` | `bin/argument_gate_matrix` |
| `hecks regenerate_corpus [--check]` | `bin/regen_codegen_domains` |
| `hecks report_comments paths=a,b [only=] [--json] [top=20]`; `hecks check_comments paths=…`; `hecks fix_comments paths=… --confirm`; `hecks write_comment_baseline --confirm`; `hecks check_comments_unchanged ref=REF` | `bin/standardize_comments` |
| `hecks report_rust_comments paths=a,b [only=] [--json] [top=N]`; `hecks check_rust_comments paths=… [only=]`; `hecks fix_rust_comments paths=… [only=] --confirm` | `bin/standardize_comments_rust` |
| `hecks canonicalise <file.json>` | `bin/canonicalise` |
| `hecks hoist_local_givens --confirm` | `bin/codemod_hoist_local_givens` |
| `hecks drop_implicit_append_fields --confirm` | `bin/codemod_implicit_append_fields` |
| `hecks shard_specs group=1 groups=N [runtime_log=]` | `bin/rspec_shard_files` |
| `hecks list_io_parallel_specs exclude=REGEX [tags=] [check=file]`; `hecks write_io_parallel_spec_list exclude=REGEX [tags=] write=file --confirm` | `bin/rspec_io_parallel_files` |
| `hecks refresh_runtime_baseline [workers=6] [from_run=ID]` | `bin/refresh_rspec_runtime_baseline` |
| `hecks run_spec_example file=path example=text` | `bin/spec_example` |
| `hecks stress_concurrency [runs=30] [parallel=] [seed_start=1]` | `bin/stress_concurrency_specs` |
| `hecks regenerate_legacy_fixtures --confirm` | `bin/regenerate_persistence_legacy_fixtures` |
| `hecks seed_semantics_corpus [fixture=name]` | `bin/seed_semantics_corpus` |
| `hecks record_pattern_cases` | `bin/pattern-cases` |
| `hecks rust_domains`; `hecks regen_order`; `hecks corpus_rust_coverage` | `bin/corpus` |
| `hecks ir_constructs [names=a,b]`; `hecks ir_duplicates [domains=a,b] [--meta]`; `hecks ir_impact name=N field=F` | `bin/query_ir` |
| `hecks serve_query_ir_mcp` | `bin/hecks_query_ir_mcp` |
| `hecks present [port=4567]` | `bin/present` |
| `hecks publish [--gem-only] [--npm-only] [--npm-local] [--no-wait] --confirm (without --confirm, the old --dry-run)` | `bin/release` |
| `hecks publish_gem --confirm` | `bin/release_gem` |

## QualityControl, for maintaining Hecks

| launcher | replaces |
|---|---|
| `hecks quality_control tick` | `bin/qa_tick` |
| `hecks quality_control ask run [target=] [arguments="--all --seeds N --steps N --adversarial F --role-draw F --dry-run F --self-consistency BOOL --modes a,b --persistence-parity --no-parity"]`; `hecks quality_control release <target> [now=] [next_streak=] [capabilities=] [yield_score=]` | `bin/qa_sweep` |
| `hecks quality_control check_pull_requests` | `bin/qa_pr_check` |
| `hecks quality_control patch.open bug=BUG#n number=N url=… branch=… commit=SHA title=… [now=]`; `hecks quality_control improvement.open [angle=ANGLE-n] number=N url=… branch=… title=… [now=]` | `bin/qa_open_pr` |
| `hecks quality_control log sweep=<sweep id> reference= sequence=N title= demonstration= symptom= expectation= submitter= [tags=a,b] [name=] [reproduced=yes\|no]` | `bin/qa_log_bug` |
| `hecks quality_control angle.seed` | `bin/qa_seed_angles` |
| `hecks quality_control target.seed` | `bin/qa_seed_targets` |
| `hecks quality_control check_generated_domains [arguments="--domains 3 --start N --forms a,b --seeds 5 --steps 25 --adversarial 0.3 --rust --shrink-budget 200 --domain-shrink-budget 40 --promote dir --name N --from-dials --blueprint F --source F"]` | `bin/qa_generated_domains` |
| `hecks quality_control mine_combinations [arguments="--candidates 3 --rust --seeds 5 --steps 25 --adversarial 0.3 --repair-rounds 1 --agent CMD --from DIR --against PATH --brief"]` | `bin/qa_mine_combinations` |
| `hecks quality_control judge_novelty <domain> [arguments="--against PATH …"]` | `bin/qa_domain_novelty` |
| `hecks quality_control discover_external_domains [arguments="--projects-dir ~/Projects --max-depth 3 --known-path PATH …"]` | `bin/qa_discover_external_domains` |
| `hecks quality_control migrate_ledger_from_heki domain=<domain_dir> data=<heki_dir> [arguments="[aggregate …] --force"] (a dry run without --force)` | `bin/qa_postgres_migrate` |
| `hecks quality_control create_ledger_role <database> [role=hecks_qa]` | `bin/qa_postgres_role` |
| not user-facing; ProcessPool starts it as `hecks quality_control race domain= database= schema= verb= step_arguments=` | `bin/qa_concurrency_racer` |
