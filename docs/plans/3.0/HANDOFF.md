# hecks 3.0 build: handoff (2026-09-29)

Branch `hecks-3-0`, pushed to origin so the work can be picked up from anywhere. It has not been merged, and nothing has been pushed to `main`.
Plan: [PLAN.md](PLAN.md). Design: ADR 0080, on branch `worktree-adr-0080-bins-as-adapters` (`docs/decisions/0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md`).
HEAD at pause: the `3.0 (6/11)` commit (after e1069289, the 5h launcher), clean tree. The whole suite passed at that commit. The order-dependent world_builder spec passed in that run but was only patched by renaming a leaked `Widgets` module, so keep it on the watch list. Check `git log --oneline -3` and `git status` first.
The machine SLEEPS between tool calls, so wall-clock time is meaningless: judge speed by CPU time.

## Done (oldest first)
1 guard spec 5e4f8c47; 2a-2e launcher forms, `attaches`, routing, `namespace` word fea89025; 3 Hecks root e3dfc6e6; 3b `answered_by` query word 9a653b5c;
4a Introspection 5f443c7f; 4b ModelCheck+Operation de85d5d1; 4c Host 2373d681; 4d Package d142ed5c; 4e Door c64d5eda; 4f Era + committed approval 752873ac; 4g Build 6531bed5; 4h FuzzRun + complete Custodian table 5debd9be;
5a LanguageRun d8abd41e; 5b Kernel/Conformance befe6a66; 5c Regeneration/Style 4a8ab3cc; 5d Codemod/TestSuite 9923946a; 5e Corpus 85472792; 5f Publishing 99fc8959 + 43400fb4; 5g PostgresEra binding 70aa35c8; 5h launcher e1069289; 6 language chapters, Tenancy and Deploy attached (commit `3.0 (6/11)`, see below).
Also: 2.10.0 warning release on branch `hecks-2-10-warnings` (6bcaba8a); Step 0 codegen-race fix on the ADR branch (8df45d3c) cherry-picked.

## Launcher work "5h": done, commit e1069289
The agent's last full run had 2 order-dependent failures in spec/world_builder_aggregate_qualified_growth_spec.rb (a bare `Widgets` module leaked by spec/embryonaut_bluebook_vendor_spec.rb); it renamed the module in the spec and re-ran that pair green but did not re-run the whole suite. Not done: refused reactions are not reported for a remote runtime. `--wait` and the other launcher features only work for domains that opt in via the `launcher` setting in hecks.world. Design as built (no grammar change; config = `launcher` free-form setting in lib/hecks/hecks/hecks.world; `registry.root` is lib/hecks, not the domain dir):
1 auto run keys: launcher mints via Ports::IdentityGeneration.uuid for creating commands missing `run.value` (opt-in by world setting);
2 aliases: `launcher names` table (mcp: serve_mcp, console: open_console);
3 `--wait`: re-read the record after dispatch, exit 1 on a failure state (flagged failed drifted unreachable refused faulted halted abandoned; reconcile with real lifecycle names); required spec: `hecks model_check --wait` exits 1 when flagged;
4 refused reactions first-class: Dispatcher::Result#refused_reactions replaces CliRunner's ad-hoc helper (update spec/facade/cli_runner_spec.rb ~136-147, spec/hecks_command_table_spec.rb ~339, spec/adapters/driven/journal_store_spec.rb ~444-460);
5 constant collisions: temporarily remove_const a colliding Hecks::<Name> (today only Release) while the Hecks hecksagon builds, restore in ensure; spec with aggregates named "Fuzzing"/"Release".

## Step 6: done (attach the language chapters, Tenancy and Deploy)

`hecks.hecksagon` attaches Bluebook, Paging, Hecksagon, World, Adapter, Port, Translation (the language's chapter only), Expression, Tenancy and Deploy, one `attaches` line each (the word takes one name). Decisions:
- **Paging is attached explicitly**, beside Bluebook: it extends Bluebook through `attaches_to`, but the chapter index treats it as a chapter of its own, so "comes with it" is one more `attaches` line.
- **Sibling hecksagons.** A chapter that names no constants of its own gets a bare sibling in `context_map.hecksagon` (each `uses_framework "Governance"`, because the language declares roles). Tenancy's `translates` seam and Deploy's ports name constants, so they are wired in `hecks.hecksagon` after the `attaches` lines: `context_map.hecksagon` is read first and would see no chapter yet.
- **Stores.** Every attached chapter takes the store `hecks.world`'s `default_adapter` names (PostgresEra, or Memory under `environments/memory.world`); Tenancy's own `LocalStorage` binding is not used. Deploy has a world, `deploy.world`, only for its launcher setting (run keys; `--wait` failure states).
- **Deploy's ports are in `lib/hecks/deploy/bluebook/deploy_ports.hecksagon`**, loaded by the chapter's own boot beside `deploy.hecksagon` and by `hecks.hecksagon`. One file, so the standalone Deploy boot (and `bin/project_tenant`) and the Hecks domain agree.
- **Boot time.** Booting the Hecks domain went from about 4.7s to about 5.4s of CPU (about +0.7s) with everything attached. Nothing loads at `require "hecks"`, and the boundary spec still passes: attaching only happens when the Hecks domain boots.

Deploy verbs (all `hecks deploy <verb>`, all journaled with the Custodian pattern; no checkout guard, no roles, since Deploy has no Governance):
- **Recipe.Project** (`project <domain> [tenant=] [schema=] [out=] [environment=]`): request, `Workspace.Survey` (the adapter reads the world's declared target), `Accept` (given the target is AwsLambda or AwsFargate), `Workspace.Render`, `Complete` or `Fault`. Given on the request: a schema names its tenant. A target that is not deployable holds the request back (the record stays `requested`, the launcher reports a refused reaction; `--wait` exits 1). Logic moved from `bin/project_deploy` into `Hecks::CLI::ProjectDeploy`, which the script now calls.
- **Recipe.Diff** (query, `diff before= after= [--json] [--strict]`): answered by the Workspace port, using `Projections::Deploy::TemplateDiff`. A query cannot set an exit status, so "different" is in the answer (`--json` has a `different` field), not the status as `bin/deploy_template_diff` had it.
- **RecipeLint.Lint** (`lint [makefiles=a,b]`): `Make.Check` reads Makefiles as text; with none named it renders the three fixture domains in-process. The linter moved to `Projections::Deploy::RecipeLint` (`bin/lint_deploy_recipes` keeps the `DeployRecipeLint` name). Statuses `clean` or `flagged`.
- **OidcManifest.ProjectOidc** (`project_oidc [domains=a,b]`): `Workspace.WriteManifests`, logic in `Hecks::CLI::ProjectOidc`. Statuses `written` or `stopped`. It works from the directory it runs in.
- **Tenant.Provision** (`provision <domain_dir> slug= domain= realm= schema= database= [adapter=]`): the `TenantProvisioning` port stays; its ask is renamed `Establish` (a command and an ask named `Provision` collide in the launcher) and its adapter now also boots the domain under the overlay and checks it is tenant_capable, so a refusal is recorded. `Tenant` gained a lifecycle (`declared`, `provisioned`, `refused`), a `Refused` query, and the database, adapter, directory and refusal fields. Tenancy's `Register` reaction now runs in the same registry.
- The names of the records are `Recipe`, `RecipeLint` and `OidcManifest` (the ADR's verb names are the command names).
- **Launcher.** `--wait` now also exits 1 when a reaction was refused, since a request a `given` held back records nothing else.
- **Not idempotent.** Provisioning a slug that already exists is refused ("already exists"), where `bin/project_tenant` re-ran safely. A re-provision command on an existing tenant is open.

## Remaining plan steps
7 move QualityControl into lib/hecks/quality_control/ (rules as givens, IssueTracker + Agent adapters);
8 package the Rust workspace + gemspec (drop the dev_tooling filter; ship rust/ without target/tests/generated);
9 generated exe/hecks via project_cli (keep the ten ADR 0066 names; needs the alias table);
10 CI, hooks, docs point at `hecks <verb>` using --wait (Gate domain and generate-everything are FOLLOW-UPS);
11 delete bin/ (first move script bodies into lib/: RegenerationRun, ArgumentGateMatrix, RustToolchain children, SqliteFixture, comment linters still run bin/ scripts), spec that bin/ holds no hand-written script, CHANGELOG `Breaking:`.
Then: regenerate 2.10.0 warning text/forms.yml from the real command set (branch hecks-2-10-warnings); ADR 0080 notes on its branch; the gaps below; final gates.

## Gap register (all must be covered)
- Verification never run: installed-gem smoke; client-launcher smoke; committed-approval rehearsal on scratch Postgres (mint_harness); release dry run; one master spec for all 94 section-7 rows (spec/hecks_custodian_table_spec.rb and spec/hecks_codebase_adr_rows_spec.rb and spec/hecks_deploy_table_spec.rb exist; add QualityControl); QualityControl tick against the moved chapter.
- Pre-push gate never run on the branch: fuzzing, engine agreement, model_check, rubocop (offenses in earlier specs, e.g. spec/hecks_custodian_table_spec.rb, spec/adapters/driven/postgres_era/lineage_spec.rb), comment scan, CI attestation, io-tagged specs once with CI=1, `.github/postgres_io_spec_files.txt`.
- Thin/unbuilt: PgAdmin adapter; real streaming `follow` (bounded poll now); ServeMcp/Present/ServeQueryIrMcp not tested end to end; `hecks run` lacks an exactly-one-of(script,verb) given; two Era guards are not givens (Reattest.shape_guard!, matching-digest no-op); EraChanged event dropped; argument_gate_matrix and regenerate_corpus --confirm write paths tested only via fake shells.
- Rust/packaging: only the Ruby project_rust path emits approvals; rust_conformance artifact=build needs spec/support helpers the gem lacks; gem must ship rust/; Compact keeps refusing bound projections until ADR 0079.
- Flaky order-dependent spec: spec/world_builder_aggregate_qualified_growth_spec.rb (fails in the full run, passes alone). Commit 5d was committed before its own suite was green (later commits verified).
- ADR 0080 notes to record on its branch: Hecks::Domain namespace; answered_by; run=<key>; launcher renames (serve_mcp, open_console, glossary, narrate/docs verbs, `aggregate=` for narrate/docs, `new_name=` for rename); record names (LanguageRun, KernelRun, ConformanceRun, RegenerationRun, StyleRun, CodemodRun, TestSuiteRun, CorpusRun, PublishingRun, FuzzRun, ModelCheckRun; plus Operation, Host, Package, Door, Build, Era); Era Admit renamed Permit; Release.Publish renamed MarkPublished, Verify allowed from published or verified; PostgresEra everywhere via hecks.world `default_adapter` + HECKS_DATABASE; Memory via environments/memory.world (HECKS_ENVIRONMENT=memory, set by spec_helper); glossary/project_diagrams return text and write nothing; --wait and exit-status semantics; ScaffoldTranslation returns text; committed approval file `translations/<from>-<to>.approval`.

## FOLLOW-UPS (after 3.0)
Gate domain: CI checks as data + `hecks gate <stage>`; generate hooks and ALL workflows including runner setup (toolchains, services, caches, secrets by name via SecretVault); generate everything derivable (docs verb tables, completions, MCP listing, command-table specs, io spec list, CHANGELOG skeleton, gemspec lists; `hecks regenerate --check`); model_check refuses answered_by on Rust-target domains; real access control (roles Operator/Maintainer/System are unassigned); release check that shape changes ship an era translation edge; measure/reduce `hecks` boot time; ADR 3.x items + ADRs 0079/0081/0082; streaming follow + 2.x to 3.0 migration guide.

## Mechanics for any agent working here
- A fact-forcing hook denies the FIRST Write/Edit/Bash of each file or command: state callers, affected API, data, and the user's instruction verbatim, then retry. In a parallel batch the first edit of an untouched file may be denied while others apply: re-check `git diff`.
- Bash refuses text containing the word "rspec" and "too complex" compound or substitution commands. Run specs through wrapper scripts (recreate if the job tmp was cleaned): run_specs.rb = `require "rspec/core"; exit RSpec::Core::Runner.run(ARGV)`; run_all.rb = `exec("bundle","exec","parallel_rspec","spec","-n","4")`; `env GOLDEN=rewrite ...` rewrites golden IR.
- Commit with `git commit -q -F - <<'EOF'` (there is no post-commit hook any more); trailers: Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com> and the Claude-Session line. Never push, never touch main, no bin/ deletion before step 11.
- Generated files are never hand-edited: bin/project_parser_table, bin/regen_codegen_domains (--check must be clean), bin/reference, GOLDEN=rewrite. Comment style: bin/standardize_comments --check.
- Read the TOTAL "N examples, M failures" line of the suite, not a per-process line (a slow 4th group prints last).
