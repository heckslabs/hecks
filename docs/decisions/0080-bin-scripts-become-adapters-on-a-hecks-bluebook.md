# Bin scripts become adapters on a Hecks bluebook

**Status:** Proposed. Date: 2026-09-28. Amends [ADR 0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md): the gem ships the development tooling too, and the `dev_tooling` filter in `hecks.gemspec` goes (section 3). Builds on [ADR 0053](0053-transactional-outbox-for-domain-events-and-effects.md) (the journal every command writes). Nothing below is built yet.

## Context

`bin/` holds 92 hand-written Ruby scripts. Each one parses its own arguments, performs its own checks, shells out to `git`, `gh`, `cargo`, RubyGems or the filesystem inline, and reports by printing and exiting. None of what they do reaches a journal, so a check that starts failing leaves no history, and the rules they enforce are invisible to `model_check`.

The pieces for doing this the domain way already exist:

- `bin/project_cli` (`lib/hecks/cli/project_cli.rb`) generates a launcher beside each domain. The launcher boots the domain and hands `ARGV` to `Hecks::Facade::CliRunner`, which projects verbs, arguments and refusals from the bluebook each time it runs.
- A hecksagon declares ports, and an `adapters/` directory binds them. `qa/bluebook/quality_control.hecksagon` declares the `CI` port and `qa/adapters/github_checks` binds it.
- `lib/hecks/deploy/bluebook/` shows a bluebook that lives inside `lib/`.
- `lib/hecks/language/bluebook/` shows one bluebook spread over several files: `bluebook.bluebook`, `aggregate.bluebook` and the rest each open `Hecks.bluebook "Bluebook"` and add their own aggregates. The boot loads every `*.hecksagon` in the directory.
- `lib/hecks.rb` requires none of the development tooling (ADR 0066), so code that sits in the gem costs nothing until something asks for it.
- Production domains deploy as `rust/host` images, which do not carry the Ruby gem at all.

## Decision

Every bin script becomes a command or query on a bluebook, with its outside-world work in adapters behind ports. All 92 move in one pass.

### 1. A bin becomes adapters plus a generated launcher

- **Rules move into the bluebook.** A refusal a script checks by hand becomes a `given` on the command, with a message that states the rule.
- **Side effects move into driven adapters.** Calls to `git`, `gh`, `cargo`, `gem`, `npm`, Postgres, AWS and the filesystem sit behind ports the hecksagon declares, bound in the domain's `adapters/` directory, in the same shape as `qa/adapters/github_checks`.
- **Results become events.** A check that printed and exited answers with a passed or failed event, so the journal records when a result changed.
- **The entry point is generated.** `project_cli` writes the launcher beside each domain. Nobody writes a launcher by hand, and `bin/<name>` is deleted.

### 2. One Hecks bluebook, in three parts

The framework gets its own domain, `Hecks.bluebook "Hecks"`, in `lib/hecks/hecks/`. Following the language domain, it is spread over files that each open `Hecks.bluebook "Hecks"`:

```
lib/hecks/hecks/
  hecks.bluebook        the root: vision, and the Hecks aggregate itself
  custodian.bluebook    Custodian: operating any domain
  codebase.bluebook     Codebase: working on this repository
  hecks.hecksagon       wiring for the whole domain
  adapters/             driven adapters; Codebase's under adapters/codebase/
  hecks                 the launcher project_cli generates
```

| Part | Files | For | Runs | Holds |
| --- | --- | --- | --- | --- |
| Root | `hecks.bluebook` | Everyone | Anywhere | The framework itself: its vision and version |
| Custodian | `custodian.bluebook` | Clients running their own domains | Anywhere | Looking at a domain, running it, building it for the Rust host, fuzzing it, caring for its stored data, vendoring bluebooks, entry points |
| Codebase | `codebase.bluebook`, `adapters/codebase/` | Maintainers of Hecks | In a hecks checkout; refuses elsewhere | Evolving the language, Rust/Ruby conformance, comment style and codemods, test suite tooling, corpus-wide regeneration, releasing the gem |

The split is by audience, not by packaging: all of it ships. The test for where a command goes is whether a client would run it against their own domain. If so it is Custodian's, even when Hecks maintainers also use it; if it only makes sense on this repository, it is Codebase's. Because `project_cli` names a launcher after its bluebook, the generated launcher is `hecks`, and `exe/hecks` becomes that launcher instead of a hand-written router. Verbs are the Hecks commands directly, for example `hecks verify_engine_agreement` or `hecks merge_tail`.

A script whose concern already has a bluebook joins that bluebook instead: the `qa_*` scripts go to QualityControl and the deploy scripts go to Deploy.

### 3. The gem ships all of it; nothing loads until asked

Everything in this ADR ships in the gem: the Hecks domain with Codebase and its adapters, every attached chapter including QualityControl, and the development tooling ADR 0066 kept out (`fuzzing/`, `bench/`, `corpus.rb`, `codemod.rb`, `query_ir.rb`, `grammar/evolve.rb`, `doc/`). The `dev_tooling` filter in `hecks.gemspec` goes, and `spec/gemspec_packaging_spec.rb` changes from asserting that those files are absent to asserting that `lib/hecks.rb` never loads them.

The gem also packages the Rust workspace, so a client can build their own domain for `rust/host` from an installed gem:

- **What ships.** `rust/Cargo.toml`, `Cargo.lock` and the crates a domain build uses: the kernel (`rust/src/` without `generated/`), `codegen/`, `parser/`, `host/`, `project/`, `build/`, `web/` and `lsp/`. About 4 MB of source.
- **What stays out.** `target/` build output, `rust/tests/`, and the generated corpus domains in `rust/src/generated/` (about 10 MB) with their Cargo features. The packaged workspace is a clean kernel that knows no domains.
- **A build never writes into the gem.** `project_rust` works by writing a domain's code into `rust/src/generated/` and adding a feature for it to `Cargo.toml`. Custodian's Build therefore copies the packaged workspace into the client project, keyed by gem version (for example `.hecks/rust/<version>/`), generates the domain there, and points `CARGO_TARGET_DIR` there. The RustToolchain adapter does the copying. In a hecks checkout, Codebase's Regeneration keeps writing corpus domains into the checkout's own `rust/`.
- **The kernel version is the gem version.** A domain built with hecks 3.0.0 compiles against the 3.0.0 kernel, so the Release aggregate and the Kernel aggregate name the same version.

Keeping a deployment small does not depend on the package:

- **Shipping is not loading.** The Hecks domain boots only when `exe/hecks` runs, never from `lib/hecks.rb`. A Ruby deployment that requires `hecks` and boots its own domain loads none of Custodian, Codebase, QualityControl or the tooling; they are files on disk.
- **Production runs on Rust.** `rust/host` images do not carry the gem.
- **Checkout-only commands refuse outside a checkout.** Every Codebase and QualityControl command carries a `given` that the working tree is a hecks checkout, so an installed gem answers "needs a hecks checkout" instead of globbing an absent `rust/` or rewriting its own `lib/`. The `SourceTree` and `Workspace` adapters answer that question.

### 4. Hecks attaches the framework's own chapters

The Hecks domain also takes in every chapter that describes the framework itself: the language declared in itself, Tenancy, Deploy and QualityControl. Each stays a chapter of its own: it keeps its name, its namespace (`QualityControl::Patch`, `Deploy::Tenant`, `Bluebook::Aggregate`), its store and its directory. The Hecks hecksagon attaches them the way `uses_framework` attaches Governance, and cross-chapter reactions go through `translates`.

| Group | Chapter | Lives in | For | Runs |
| --- | --- | --- | --- | --- |
| Language | Bluebook | `lib/hecks/language/bluebook/` | Both | Anywhere |
| Language | Paging (extends Bluebook through `attaches_to`, comes with it) | `lib/hecks/language/bluebook/attaches/` | Both | Anywhere |
| Language | Hecksagon | `lib/hecks/language/hecksagon/` | Both | Anywhere |
| Language | World | `lib/hecks/language/world/` | Both | Anywhere |
| Language | Adapter | `lib/hecks/language/adapter.bluebook` | Both | Anywhere |
| Language | Port | `lib/hecks/language/port.bluebook` | Both | Anywhere |
| Language | Translation | `lib/hecks/language/translation/` | Both | Anywhere |
| Language | Expression | `lib/hecks/grammar/expression.bluebook` | Both | Anywhere |
| Runtime | Tenancy | `lib/hecks/tenancy/bluebook/` | Clients | Anywhere |
| Operations | Deploy | `lib/hecks/deploy/bluebook/` | Clients | Anywhere |
| Operations | QualityControl | `lib/hecks/quality_control/`, moved from `qa/` | Maintainers | In a hecks checkout |

The language chapters serve both audiences: clients' domains run on them, and maintainers change them.

QualityControl's chapter, hecksagon and adapters move from `qa/bluebook/` and `qa/adapters/` into `lib/hecks/quality_control/` so they ship with the rest. What belongs to this repository's QA practice stays in `qa/`: the `.world` file naming the ledger database, `settings.yml`, the stress domains and the specs. The QA ledger keeps its PostgresEra era and tables, because they are keyed by the chapter name, which does not change.

Two chapters are named Translation today; Hecks attaches only the language's (section 6).

Some chapters stay out on purpose:

- The framework members (Governance, Identity, Privacy, Compliance, ConsoleSettings) are libraries application domains attach. Hecks uses Governance the way QualityControl does; it does not own them.
- The QA stress domains under `qa/stress_domains/` are subjects QualityControl rotates through, not part of the framework.
- Test fixtures (`rust/parser/tests/fixtures/`, the `Fixture*` chapters) are inputs to specs.

The one `hecks` launcher reaches every chapter's verbs, for example `hecks quality_control log_bug` or `hecks deploy lint`. No chapter gets a launcher of its own.

```ruby
# lib/hecks/hecks/hecks.hecksagon
Hecks.hecksagon "Hecks" do
  uses_framework "Governance"

  attaches "Bluebook", "Hecksagon", "World", "Adapter", "Port", "Translation", "Expression"
  attaches "Tenancy"
  attaches "Deploy", "QualityControl"
end
```

`attaches` stands for the attaching word; see Open items.

### 5. The hand-written floor, and the aggregates around it

The Bluebook chapter's own vision names what stays hand-written: "the interpreter — evaluating a predicate held as data — and IO". The floor is only that. The parser's output, the IR and the meta-validator's judgments are already modelled: "Loading a domain becomes dispatching commands into this meta-domain; the IR it stores must equal the IR the DSL builder produces." They are the attached Bluebook chapter's aggregates.

Around the floor, every part that has identity and changing state becomes an aggregate, so its changes are journaled like any other domain's:

| Aggregate | Held by | Identified by | State and lifecycle | Takes over |
| --- | --- | --- | --- | --- |
| Release | Root | gem version | tagged → published → verified; carries the IR version (`Bluebook::Chapter::IR_VERSION`) it shipped | `Hecks::VERSION` as the record of what is running and what was shipped |
| SyntaxBootCache | Root | digest of the grammar chapters | fresh → stale → rebuilt; `Invalidate`, `Rebuild` | the on-disk cache under `Hecks::CacheDir`, whose invalidations are silent today |
| Host | Custodian | stack or URL | `Observe` records the version and era a running `rust/host` reports; emits `EraChanged` | `check_era`, which becomes a command on it |
| FrameworkMember | Custodian | member name | the capabilities it provides | `Hecks::Framework.members` and `providers_of`, read as records; Hecks catalogs members without attaching them |
| Kernel | Codebase | kernel version | the capability tables and a coverage result per run | `project_kernel_capabilities`, `rust_kernel_coverage` |
| Adapter | Adapter chapter (exists) | adapter name | gains the optional port operations it `implements` and the `guarantees` it gives (section 10), which a domain today only learns from a warning at boot | the `.adapter` declarations `lib/hecks/adapters/driven/` already holds |

The Hecks domain's own adapters (InProcessBoot, JournalStore, RustToolchain and the rest in this ADR) get `.adapter` declarations too, so they appear beside the built-in ones.

Release moves to the root because every install has a version, and "what am I running" and "what did we ship" become one record. The steps that publish a release (tagging, pushing to RubyGems and npm) stay in Codebase as Publishing, and advance the root's Release through its lifecycle.

What stays code is the interpreter and the IO inside each adapter.

#### The Hecks door wraps operations on the runtime, never the runtime's own dispatch

Three rules keep the Hecks domain beside a client domain, not in front of it:

1. **A client's commands never pass through the Hecks domain.** A client domain's generated launcher and `rust/host` call the runtime directly. A client's command takes no extra hop, writes no second journal entry, and depends on neither the Hecks domain's store nor its version.
2. **The Hecks domain reaches a target domain only through the DomainRuntime port.** It boots and operates on another domain the way any adapter-driven caller would, and never through the runtime's internals.
3. **Booting the Hecks domain depends on no Hecks command.** It boots the way any domain boots, without `exe/hecks` or any of its own verbs. The committed `exe/hecks` stays the bootstrap, so regenerating the launcher never needs a working launcher.

### 6. Translation: attach the language's chapter only

Two chapters are named Translation: the grammar's register of rule kinds (`lib/hecks/grammar/translation.bluebook`) and the language's meta-model of an edge file (`lib/hecks/language/translation/`). They are two halves of one concept, and [ADR 0082](0082-the-two-translation-chapters-become-one.md) merges them.

3.0 does not wait for that. Hecks attaches only the language's Translation chapter. The grammar chapter stays unattached, as it is today, since it only ever loads alone in `Hecks::Grammar.grammar_chapters`. The names never meet, so nothing is renamed.

### 7. Where each script goes

Every script becomes one or more commands or queries, named for the domain action (section 12). The launcher column shows the 3.0 form; the Hecks domain's own verbs are bare, and an attached chapter's verbs follow its name (`hecks quality_control …`, `hecks deploy …`). `<x>` is the positional identifying argument, `--flag` a boolean, `name=value` everything else. Destructive commands dry-run without `--confirm`.

**Custodian, for clients**

| Script | Aggregate · command | Launcher |
| --- | --- | --- |
| `ir` | Introspection · IR (query) | `hecks ir [domain] [--translations] [--meta]` |
| `shape` | Introspection · Shape (query) | `hecks shape <domain>` |
| `stores` | Introspection · Stores (query) | `hecks stores <domain>` |
| `history` | Introspection · History (query) | `hecks history <domain>` |
| `statements` | Introspection · Statements (query) | `hecks statements <domain> chapter=Name` |
| `narrate` | Introspection · Narrative (query) | `hecks narrative [domain] [aggregate=Name]` |
| `docs` | Introspection · Document (query) | `hecks document [domain] [aggregate=Name]` |
| `project_diagrams` | Introspection · Diagrams (query) | `hecks diagrams <domain> chapter=Name` |
| `project_glossary` | Introspection · Glossary (query) | `hecks glossary <domain> chapter=Name` |
| `model_check` | Introspection · ModelCheck | `hecks model_check [domains=a,b] [--strict] [profile=client]` |
| `run` | Operation · Run | `hecks run [domain] script=steps.json`, or `hecks run [domain] <verb> name=value …` |
| `project` | Operation · RefreshProjections | `hecks refresh_projections <domain>` |
| `behaviors` | Operation · RunBehaviors | `hecks run_behaviors <path>` |
| `console` | Operation · OpenConsole | `hecks console [domain]` |
| `follow` | Operation · Follow (query, streams) | `hecks follow <domain> [aggregate=Name] [interval=0.5] [--from-now]` |
| `smoke_test` | Operation · SmokeTest | `hecks smoke_test [domain]` |
| `smoke_http` | Operation · SmokeHttp | `hecks smoke_http path=/p secret=… [url=] [header=] [scheme=timestamped] [payload=] [payload_file=] [health_path=] [state_path=]` |
| `check_era` | Host · CheckEra | `hecks check_era <url> expected=era-file [timeout=10]` |
| `merge_tail` | Era · MergeTail | `hecks merge_tail <domain> winners=id:old,id:new --confirm` |
| `reattest_era` | Era · Reattest | `hecks reattest <domain> era=N --confirm` |
| `backfill_era_projections` | Era · BackfillProjections | `hecks backfill_projections <domain>` |
| `scaffold_translation` | Era · ScaffoldTranslation (query) | `hecks scaffold_translation <domain>` |
| `translation_audit` | Era · AuditTranslation (query) and Era · ApproveTranslation | `hecks audit_translation <domain>`; `hecks approve_translation <domain> --confirm` |
| `compact` | Era · Compact | `hecks compact <domain> [aggregates=A,B] --confirm` |
| `heki_compact` | Era · CompactHeki | `hecks compact_heki <domain> [aggregates=A,B] --confirm` |
| (new) | Era · HoldFirst | `hecks hold_first <domain> --confirm` |
| `vendor_bluebook` | Package · Vendor | `hecks vendor <package[@version]> [from=path] [root=path]` |
| `project_cli` | Door · ProjectCli | `hecks project_cli [domains=a,b]` |
| `hecks_mcp_door` | Door · ServeMcp | `hecks serve_mcp` (stdio) |
| `project_rust` | Build · ProjectRust | `hecks project_rust <domain>` |
| `project_wasm` | Build · BuildWasm | `hecks build_wasm <domain>` |
| `project_wasm_browser` | Build · BuildBrowserWasm | `hecks build_browser_wasm <domain>` |
| `rust_coverage` | Build · RustCoverage (query) and Build · CheckCoverageAllowlist | `hecks rust_coverage <module> [codegen=ruby]`; `hecks check_coverage_allowlist` |
| `rust_conformance` | Build · CheckConformance | `hecks check_conformance <domain> script=steps.json [artifact=native]` |
| `rust_conformance_fuzz` | Build · FuzzConformance | `hecks fuzz_conformance <domain> artifact=native [seeds=10] [steps=25]` |
| `fuzz` | Fuzzing · Fuzz | `hecks fuzz [domain] [seeds=20] [steps=30] [workers=] [adapter=memory]` |
| `generate` | Fuzzing · GenerateSequence (query) | `hecks generate_sequence <domain> [seed=1] [steps=30] [adversarial=0.0]` |
| `bench` | Fuzzing · Bench | `hecks bench [domains=pizzas,banking] [targets=] [iterations=1000] [warmup=200] [runs=3] [rust_binary=] [format=markdown] [output=]` |

**Deploy, for clients** (attached chapter)

| Script | Aggregate · command | Launcher |
| --- | --- | --- |
| `project_deploy` | Deploy · Project | `hecks deploy project <domain> [tenant=] [schema=] [out=] [environment=]` |
| `lint_deploy_recipes` | Deploy · Lint | `hecks deploy lint [makefiles=a,b]` |
| `deploy_template_diff` | Deploy · Diff (query) | `hecks deploy diff before=a.yaml after=b.yaml [--json] [--strict]` |
| `project_oidc` | Deploy · ProjectOidc | `hecks deploy project_oidc [domains=a,b]` |
| `project_tenant` | Tenant · Provision | `hecks deploy provision <domain_dir> slug=s domain= realm= schema= database= [adapter=PostgresEra]` |

**Codebase, for maintaining Hecks**

| Script | Aggregate · command | Launcher |
| --- | --- | --- |
| `project_model` | Language · ProjectModel | `hecks project_model` |
| `project_vocabulary` | Language · ProjectVocabulary | `hecks project_vocabulary` |
| `project_rust_vocabulary` | Language · ProjectRustVocabulary | `hecks project_rust_vocabulary` |
| `project_refusal_wording` | the same command, a second name | `hecks project_refusal_wording` |
| `project_reserved_names` | Language · ProjectReservedNames | `hecks project_reserved_names` |
| `project_parser_table` | Language · ProjectParserTable | `hecks project_parser_table` |
| `project_bootstrap_table` | Language · ProjectBootstrapTable | `hecks project_bootstrap_table` |
| `project_field_hints` | Language · ProjectFieldHints | `hecks project_field_hints` |
| `expression_projection` | Language · ProjectExpressionTables | `hecks project_expression_tables [--stdout]` |
| `reference` | Language · ProjectReference | `hecks project_reference` |
| `evolve` | Language · WordStatus (query); Propose, Admit, Deprecate, Retire, Rename; ProposeArgument, AdmitArgument, DeprecateArgument, RetireArgument | `hecks word_status`; `hecks propose <word> context=X [body=none] [inner=] [opens=] [fills=]`; `hecks rename <word> context=X to=Y`; `hecks propose_argument <word> context=X kind=K [required=false] [at=N] [named=] [pairs_shape=]`; the rest take `<word> context=X` |
| `project_kernel_capabilities` | Kernel · ProjectCapabilities | `hecks project_kernel_capabilities` |
| `rust_kernel_coverage` | Kernel · MeasureCoverage | `hecks measure_kernel_coverage` |
| `check_engine_agreement` | Conformance · CheckEngineAgreement | `hecks check_engine_agreement` |
| `doc_coverage` | Conformance · MeasureDocCoverage | `hecks measure_doc_coverage` |
| `argument_gate_matrix` | Conformance · ArgumentGateMatrix | `hecks argument_gate_matrix [--confirm]` (writes only with `--confirm`) |
| `regen_codegen_domains` | Regeneration · RegenerateCorpus | `hecks regenerate_corpus [--check]` |
| `standardize_comments` | Style · ReportComments (query), CheckComments, FixComments, WriteCommentBaseline, CheckCommentsUnchanged | `hecks report_comments paths=a,b [only=] [--json] [top=20]`; `hecks check_comments paths=…`; `hecks fix_comments paths=… --confirm`; `hecks write_comment_baseline --confirm`; `hecks check_comments_unchanged ref=REF` |
| `standardize_comments_rust` | Style · ReportRustComments (query), CheckRustComments, FixRustComments | `hecks report_rust_comments paths=…`; `hecks check_rust_comments paths=…`; `hecks fix_rust_comments paths=… --confirm` |
| `canonicalise` | Style · Canonicalise | `hecks canonicalise <file.json>` |
| `codemod_hoist_local_givens` | Codemod · HoistLocalGivens | `hecks hoist_local_givens --confirm` |
| `codemod_implicit_append_fields` | Codemod · DropImplicitAppendFields | `hecks drop_implicit_append_fields --confirm` |
| `rspec_shard_files` | TestSuite · ShardSpecs (query) | `hecks shard_specs group=1 groups=N [runtime_log=]` |
| `rspec_io_parallel_files` | TestSuite · ListIoParallelSpecs (query) | `hecks list_io_parallel_specs exclude=REGEX [tags=] [check=file] [write=file]` |
| `refresh_rspec_runtime_baseline` | TestSuite · RefreshRuntimeBaseline | `hecks refresh_runtime_baseline [workers=6] [from_run=ID]` |
| `spec_example` | TestSuite · RunSpecExample | `hecks run_spec_example file=path example=text` |
| `stress_concurrency_specs` | TestSuite · StressConcurrency | `hecks stress_concurrency [runs=30] [parallel=] [seed_start=1]` |
| `regenerate_persistence_legacy_fixtures` | TestSuite · RegenerateLegacyFixtures | `hecks regenerate_legacy_fixtures --confirm` |
| `seed_semantics_corpus` | TestSuite · SeedSemanticsCorpus | `hecks seed_semantics_corpus` |
| `pattern-cases` | TestSuite · RecordPatternCases | `hecks record_pattern_cases` |
| `corpus` | Corpus · RustDomains, RegenOrder, RustCoverage (queries) | `hecks rust_domains`; `hecks regen_order`; `hecks corpus_rust_coverage` |
| `query_ir` | Corpus · IrConstructs, IrDuplicates, IrImpact (queries) | `hecks ir_constructs [names=a,b]`; `hecks ir_duplicates [domains=a,b] [--meta]`; `hecks ir_impact name=N field=F` |
| `hecks_query_ir_mcp` | Corpus · ServeQueryIrMcp | `hecks serve_query_ir_mcp` (stdio) |
| `present` | Corpus · Present | `hecks present [port=4567]` |
| `release` | Publishing · Publish | `hecks publish [--gem-only] [--npm-only] [--npm-local] [--no-wait] --confirm` (without `--confirm`, the old `--dry-run`) |
| `release_gem` | Publishing · PublishGem | `hecks publish_gem --confirm` |

**QualityControl, for maintainers** (attached chapter)

| Script | Aggregate · command | Launcher |
| --- | --- | --- |
| `qa_tick` | Sweep · Tick | `hecks quality_control tick` |
| `qa_sweep` | Sweep · Run, and Target · Release | `hecks quality_control sweep [target] [--all] [seeds=] [steps=] [adversarial=] [role_draw=] [dry_run_share=] [self_consistency=] [modes=a,b] [--persistence-parity] [--no-parity]`; `hecks quality_control release_target <target> notes=text` |
| `qa_pr_check` | Clearance · CheckPullRequests | `hecks quality_control check_pull_requests` |
| `qa_open_pr` | Patch · Open, and Improvement · Open | `hecks quality_control open_patch bug=BUG#n title=… [body=]`; `hecks quality_control open_improvement angle=ANGLE-n title=… [body=]` |
| `qa_log_bug` | Bug · Log | `hecks quality_control log_bug sweep= title= demonstration= symptom= expectation= submitter= triage=self_contained [tags=a,b] [reproduced=yes]` |
| `qa_seed_angles` | Angle · Seed | `hecks quality_control seed_angles` |
| `qa_seed_targets` | Target · Seed | `hecks quality_control seed_targets` |
| `qa_generated_domains` | Target · CheckGeneratedDomains | `hecks quality_control check_generated_domains [domains=3] [start=] [forms=a,b] [seeds=5] [steps=25] [adversarial=0.3] [--rust] [shrink_budget=200] [domain_shrink_budget=40] [promote=dir name=N] [--from-dials] [blueprint=] [sources=a,b]` |
| `qa_mine_combinations` | Target · MineCombinations | `hecks quality_control mine_combinations [candidates=3] [--rust] [seeds=5] [steps=25] [adversarial=0.3] [repair_rounds=1] [agent=cmd] [from=dir] [against=a,b] [--brief]` |
| `qa_domain_novelty` | Target · JudgeNovelty (query) | `hecks quality_control judge_novelty <domain> against=a,b` |
| `qa_discover_external_domains` | Target · DiscoverExternalDomains (query) | `hecks quality_control discover_external_domains [projects_dir=~/Projects] [max_depth=3] [known_paths=a,b]` |
| `qa_postgres_migrate` | Sweep · MigrateLedgerFromHeki | `hecks quality_control migrate_ledger domain_dir= heki_dir= [aggregates=A,B] --confirm` |
| `qa_postgres_role` | Sweep · CreateLedgerRole | `hecks quality_control create_ledger_role <database> [role=hecks_qa]` |
| `qa_concurrency_racer` | Sweep · Race (run only as a child process) | not user-facing; ProcessPool starts it with `domain= database= schema= verb= args=` |

Internal flags that exist only for one tool to call itself (`qa_generated_domains --check/--binary/--match`) become a child command the ProcessPool adapter starts, not launcher arguments. Where a script's usage header disagreed with its code, the table follows the code.

Publishing goes to Codebase rather than Custodian because it publishes this repository's gem, so it only runs in a checkout. The Release it advances lives in the root (section 5).

Building for the Rust host is split by the same test. Custodian's Build generates and compiles one domain, the way a client deploying to `rust/host` does, and checks that build against the Ruby engine: `rust_conformance` replays a script through both, `rust_conformance_fuzz` does the same with generated sequences, and `rust_coverage` reports which of the domain's constructs are routed. Codebase's Regeneration rebuilds every corpus domain's committed output, which only this repository has, and Codebase's Conformance keeps the checks on the language itself (the kernel, the query engines, the reference docs).

`project_refusal_wording` is an alias for `project_rust_vocabulary`; it becomes a second name for the same Language command, not a command of its own.

### 8. QualityControl

The rules hand-coded in `qa_open_pr` and `qa_pr_check` move onto `Patch.Open` and `Improvement.Open`. Three are `given`s today: the branch prefix (a `pattern:` on the branch), the bug being fixed and the angle being under investigation (givens that read through the reference, as `customer.status == "active"` does in the banking example). The other two follow [ADR 0081](0081-commands-declare-the-outside-facts-they-need-and-a-rule-across-records-gets-an-aggregate-that-owns-it.md), and stay in the `GitPr` adapter until it lands in a 3.x minor after 3.0:

- **The per-day PR cap** becomes a `DailyQuota` aggregate, identified by date, from which each `Patch.Open` takes a slot.
- **"The fix commit is an ancestor of `HEAD`"** becomes a fact `Patch.Open` declares and the `GitPr` adapter answers at dispatch. Their `git` and `gh` calls move into a `GitPr` adapter. The declared `IssueTracker` port gets a bound adapter.

### 9. This ships as 3.0.0

Under [ADR 0068](0068-releases-keep-their-pace-and-state-a-two-tier-promise.md) a major version means a breaking DSL or runtime change with a CHANGELOG `Breaking:` entry, and this ADR makes several:

- `exe/hecks` stops being a hand-written router and becomes the generated launcher. The command names stay, but arguments are projected from the bluebook by `CliRunner`, so flags and argument order change.
- `bin/` goes. `Makefile`s that `project_deploy` generated in client repositories call `bin/<name>` and stop working until they are regenerated.
- `Hecks` becomes a reserved chapter name. A client chapter named `Hecks` is refused at boot with a message to rename it, through the reserved-names check `project_reserved_names` already maintains.
- The gem's contents change: everything ships (section 3).

ADR 0068's rule 4 gives a break that reaches an installed client site one release of warning where a warning is possible. The two parts that reach client sites get one:

- **The last 2.x minor warns, as text only.** The new forms exist only in 3.0, so 2.x cannot run them. Instead each old command prints the form it becomes (for example "in 3.0: `hecks compact pizzas --confirm`"), and `project_deploy` notes in each Makefile it generates which `bin/` calls change. Each warning names 3.0.0 as the removal version.
- **3.0.0 removes them.** The old argument forms and every `bin/` path go.

Inside this repository the move is one pull request, so there is never a second way for a maintainer to run a tool. It is built as ordered commits, each keeping the whole suite green, so it can be reviewed and bisected one step at a time:

1. The runtime-boundary guard spec.
2. The launcher changes (section 12) and routing to attached chapters.
3. The Hecks root, with the DomainRuntime and Workspace adapters.
4. Custodian's aggregates, one commit each.
5. Codebase's aggregates, one commit each.
6. Attaching the language chapters, Tenancy and Deploy.
7. Moving QualityControl into `lib/hecks/quality_control/`.
8. Packaging the Rust workspace, and the gemspec.
9. The generated `exe/hecks`.
10. CI workflows, hooks and docs, pointed at the new commands.
11. Deleting `bin/`.

 Client pins move to `3.0.0` explicitly, because deploys pin exactly (ADR 0068, rule 3). 3.0.0 is the first release the root's Release aggregate records.

### 10. Details the layout settles

- **`rust/host` images build from the packaged gem.** An image installs the exact gem version (deploys pin exactly, ADR 0068 rule 3) and runs Custodian's Build, instead of building from a tag of this repository. Builds from a checkout still work the same way, for testing unreleased changes.
- **The attaching word is `attaches`, resolved by chapter name.** `Hecks::Framework.members` generalizes into an index of every chapter the gem carries, so a hecksagon names a chapter and never a path. `uses_framework` keeps its narrower meaning (a bounded context with governance). The launcher reads a first argument that names an attached chapter as that chapter (`hecks quality_control log_bug`); the Hecks domain's own verbs stay bare (`hecks merge_tail`).
- **A checkout is a working tree with `hecks.gemspec` beside `lib/`.** The package carries `lib/`, `exe/hecks` and the Rust workspace but never `hecks.gemspec`, so the check cannot mistake an install for a checkout. `rust/` no longer tells them apart, since it ships.
- **JournalStore keeps the guards the database must enforce, and the rest become `given`s on Era commands.**
  - *Stay in the adapter* (transactional or database-level, and already named methods):
    - digest verification on every read (`EraStore#verify_integrity!`)
    - append-only re-attestation
    - the per-domain advisory lock with its timeout
    - the superuser write fence and the refusal of writes to a superseded era
    - rollback when the audit before COMMIT fails
    - the monotonic `compacted_through` floor
    - the row-level-security DELETE check
  - *Become givens* (the adapter supplies the facts: digests, the tip, conflicts, the projection floor):
    - explicit acceptance to re-attest, where `--accept` is today
    - explicit confirmation to compact, where `--force` is today
    - a named winner for every conflicting id in a tail merge
    - an era beyond the first before a merge
    - no projection reading a Heki journal before it is compacted to empty
    - an approval whose digest matches the edge and whose ordinal matches the tip
    - exactly one edge leaving the era
  - *The era capability check* is pasted into five scripts although `EraCheck.lineage_capable?` exists; it becomes one given, "the store keeps eras".
- **Compaction waits for ADR 0079's floor.** `bin/compact` deletes up to the aggregate's own checkpoint only, not ADR 0079's per-projection floor (the minimum `entry_count` across every bound projection). Era's `Compact` command lands with or after ADR 0079 and carries its floor as a given ("every bound projection has caught up past the target"), with JournalStore supplying the projection positions as facts. Until then, `Compact` refuses for any aggregate with a bound projection, as `heki_compact` already does.
- **Reading never writes.** `translation_audit` and `scaffold_translation` hold era 1 (`hold_first!`) when they find an empty lineage, so running an audit changes the store. The move splits that apart:
  - The audit and scaffold are queries. On an empty lineage they answer "no era held yet" and change nothing.
  - Holding the first era is its own Era command, `HoldFirst`, which an operator runs on purpose or the first boot runs as it does today.
- **Where each part persists.** Each part binds its store in its world file, as any domain does:
  - **Custodian, for clients:** Sqlite under the client project's `.hecks/` directory by default, so a check's history lives beside the domain it checks.
  - **Codebase, in this repository:** CI runs on main and in the merge queue journal to the same PostgresEra database as the QualityControl ledger, so history is shared. Pull-request runs use Memory and report without journaling, so no pull request's code gets database credentials. A maintainer's local runs journal to Sqlite under `.hecks/`, as a client's do.
  - **QualityControl:** unchanged, on PostgresEra.
- **An adapter declares what it supports, in the port's own terms.** Today a `.adapter` declares only its `port`, `field`s and `secrets`, and what an adapter can do is found at runtime by asking the class (a missing `save_saga` produces a boot warning that saga state is lost on restart). Four pieces replace that:
  - **Optional operations.** A port marks some of its operations optional, such as `SaveSaga`, `LoadSaga` and `AppendOutbox` on the persistence port, and an adapter lists the optional ones it `implements`. A capability is an operation the port already defines, so no new vocabulary is needed.
  - **Guarantees.** Qualities that are not operations, such as atomic saves across aggregates, ordered appends, durability and optimistic locking, are a closed set the port declares. Each adapter states which it gives: `guarantees :atomic_save, :durable`.
  - **Needs.** A domain's needs mostly come from its IR: a process manager needs `SaveSaga` and `LoadSaga`, and a policy with an effect needs `AppendOutbox`. Where the IR cannot tell, a hecksagon states a need on the binding: `persisted_by "Heki", requires: :durable`. Boot matches needs against declarations and refuses a binding that falls short, the way a chapter's `provides` is matched to its users. Today's saga warning becomes that refusal.
  - **Conformance.** Every optional operation and guarantee has a shared conformance suite, and declaring one enrolls the adapter in it, as the adapter-parity specs do today. Boot also checks that the class implements each declared operation. A false claim fails CI instead of production.

  The Adapter aggregate records `implements` and `guarantees`, so "which bound adapters cannot do what this domain needs" is a query.
- **Where the specs live.** Specs follow what they test:
  - A command's behavior (its givens, events and refusals) lives in `.behaviors` files beside its bluebook, such as `lib/hecks/hecks/custodian.behaviors`, as `examples/pizzas/bluebook/pizzas.behaviors` does today.
  - Each adapter capability's shared conformance suite lives at `spec/adapters/conformance/<capability>_spec.rb`, and every adapter that declares the capability runs it.
  - An adapter's own IO lives in `spec/adapters/driven/<adapter>_spec.rb`, where the existing adapters' specs already are. That includes the `io: true` specs for anything that needs a real `git`, `cargo` or Postgres.
  - QualityControl's specs move with it out of `qa/`, into `.behaviors` beside `lib/hecks/quality_control/`.
- **The runtime-boundary guard spec comes first.** `spec/hecks_domain_boundary_spec.rb` lands as the first commit of the implementation, before `lib/hecks/hecks/` exists, so the boundary is guarded from the start. It asserts three things:
  - After `require "hecks"`, no file under `lib/hecks/hecks/` is in `$LOADED_FEATURES`.
  - Booting a client domain and dispatching one command through `Hecks::Facade::CliRunner`, as a generated launcher does, loads nothing under `lib/hecks/hecks/` either.
  - That boot's registry holds no `Hecks` chapter, and holds one only when the client's hecksagon says `attaches "Hecks"`.
- **Rules found inline become givens.** On Release: releasing from `main` equal to `origin/main` on a clean tree, the client package version matching the gem's, a CHANGELOG heading for the version, and an existing tag pointing at the release commit. On Deploy: `--schema` requiring `--tenant`, and the adapter being AwsLambda or AwsFargate.

### 11. The adapters, from a scan of the code

This list comes from a static scan, not an estimate. The scan starts from each of the 92 scripts and follows `require`/`require_relative` into `lib/` and `qa/`, recording every subprocess, network, database, file, environment, clock, randomness, terminal and process-control call with its file and line. It then resolves by hand every call whose command is built at runtime, and every subprocess helper (`git(...)`, `gh(...)`, `Release::Runner::Commands`, `Vendoring::GitSource`). The core runtime that `require "hecks"` loads is scanned once, separately, since every script shares it.

**Driven adapters the scripts need:**

| Port | Adapter wraps | Scripts that reach it |
| --- | --- | --- |
| Git | `git` | `qa_open_pr`, `qa_tick`, `qa_mine_combinations`, `regen_codegen_domains`, `standardize_comments`, `bench` (commit id), `release` (preflight, tagging), `vendor_bluebook` (`git archive`, through `Vendoring::GitSource`) |
| GitHub | `gh` | `qa_open_pr`, `qa_pr_check`, `refresh_rspec_runtime_baseline` |
| GemRegistry | `gem build`, `gem push`, the RubyGems versions API over `curl` | `release`, `release_gem` |
| NpmRegistry | `npm ci`, `npm publish`, `npm view` | `release` |
| SecretVault | 1Password `op run` | `release`, `release_gem` |
| RustToolchain | `cargo`, `rustup`, `wasm-bindgen`, `wasmtime`, and the binaries they build (`hecks-build`, the parser, each domain's binary) | `project_rust`, `project_wasm`, `project_wasm_browser`, `rust_coverage`, `rust_conformance`, `rust_conformance_fuzz`, `fuzz`, `bench`, `qa_generated_domains` |
| RubyChild | `bundle exec ruby` / `bundle exec rspec`, `ruby` | `corpus`, `evolve`, `lint_deploy_recipes`, `rust_coverage`, `rspec_io_parallel_files`, `stress_concurrency_specs`, `refresh_rspec_runtime_baseline`, `qa_concurrency_racer`, `qa_discover_external_domains`, `qa_domain_novelty`, `qa_generated_domains`, `qa_mine_combinations`, `qa_sweep`, `qa_tick` |
| TestRunner | `RSpec::Core::Runner` in process | `spec_example` |
| Agent | `claude -p` (`QA_MINER_AGENT` overrides) | `qa_mine_combinations` |
| Shell | `sh -c`, `rsync`, `tar` | `qa_log_bug` (a bug's demonstration), `qa_generated_domains`, `vendor_bluebook` |
| PgAdmin | `PG.connect` outside the persistence adapters: roles, scratch databases | `qa_postgres_role`, `fuzz`, `bench`, `qa_sweep`, `regenerate_persistence_legacy_fixtures` |
| SqliteFixture | `sqlite3` and `SQLite3::Database` | `regenerate_persistence_legacy_fixtures` |
| HostHttp | `Net::HTTP` | `check_era`, `smoke_http` |
| ProcessPool | `fork`, `Process.wait`, signal traps | `fuzz`, `follow`, `qa_mine_combinations`, `qa_sweep`, `qa_tick`, `regen_codegen_domains` |
| Terminal | IRB, stdin, y/N prompts | `console`, `run`, `release`, `standardize_comments`, `bench` |
| Workspace | file writes (52 scripts) and reads (68) | most scripts; SourceTree is the part that rewrites tracked source |
| `clock` (exists) | `Time.now`, `sleep` | `fuzz`, `bench`, `release`, `smoke_http`, `qa_open_pr`, `qa_sweep`, `qa_tick`, `qa_seed_angles`, `qa_generated_domains`, `qa_mine_combinations` |

Environment variables are read by 25 scripts; they become world configuration, not an adapter. The fuzzing generators' `Random` is seeded and deterministic, so it is logic, not IO.

**RubyChild mostly disappears.** Most `bundle exec ruby bin/<name>` calls are one hecks tool running another. Once both are commands on the same domain, the call becomes a dispatch. It stays a subprocess only where isolation is the point: the concurrency racer, the stress specs, and checking a generated domain in a clean process.

**What the scan rules out:**

- **Aws.** No script calls AWS. `project_deploy` renders a Makefile and scripts, and those run `aws`, `docker` and `sam` when an operator runs them. The runtime's one AWS SDK call is inside the Lambda persistence adapter.
- **Make.** `lint_deploy_recipes` runs `ruby bin/project_deploy` and reads the generated Makefile as text; nothing runs `make`.
- **GitHub for Release.** Release never runs `gh`; the command appears only in hint text.
- **GemRegistry for `qa_discover_external_domains`.** It runs `bundle`, not `gem`.

**Already adapters in the runtime** (reached through `Hecks.boot`, used by Custodian's DomainRuntime and JournalStore):

- the persistence adapters: Memory, Heki, Sqlite, Postgres with its outbox, PostgresEra, D1 over HTTP, Lambda over the AWS SDK
- `SystemClock`, `SecureRandomIdentity`, `InProcessKeyVault`, `GoogleAuthentication`
- the `TenantProvisioner` file write
- the storehouse log and the syntax-boot cache under `Hecks::CacheDir`

`Ports::Persistence::PostgresDump` runs `pg_dump` and `pg_restore`, but no script reaches it.

**Driving adapters:**

- the generated `exe/hecks`
- the two MCP stdio doors (`hecks_mcp_door`, `hecks_query_ir_mcp`)
- the Rack app `present` serves (`Forms::App`)
- the existing CI webhook

### 12. Commands and arguments

- **Commands are named for the domain action,** such as `Era.Compact`, `Era.MergeTail` and `Build.BuildWasm`. The launcher shows the snake form (`hecks compact`). The old script names survive only in the 2.x warnings, which point at the 3.0 form.
- **The launcher accepts three argument forms,** in every generated launcher, clients' included. All three add to what launchers accept today and remove nothing:
  - the first identifying argument, positionally (`hecks compact pizzas`)
  - booleans as `--name` (`--confirm`, `--strict`)
  - everything else as `name=value`, as today; a list is comma-separated
- **Destructive commands dry-run unless confirmed.** `--confirm` is an argument and the command's `given` requires it before anything changes. It replaces `--force`, `--accept`, `--approve`, `--write` and `--yes`. `qa_sweep`'s fractional `--dry-run` becomes `dry_run_share`.
- **A flag that picks a mode becomes its own command.** `standardize_comments --fix` becomes `FixComments`, `corpus --rust-domains` becomes `RustDomains`, and `evolve`'s ten subcommands become ten commands. Each gets its own givens and events, so `FixComments` can require `--confirm` while `CheckComments` does not.
- **A query needs `ask` only when a command shares its name.** Otherwise the bare name answers (`hecks ir`, `hecks history pizzas`).
- **A flag used only for one tool to call itself becomes a child command,** started by the ProcessPool adapter and absent from the launcher's help.

### 13. Era operations in production

Today the host mints eras and checks approvals itself, at every boot (ADR 0030). The Ruby era tools reach a production database only from a laptop, through a temporary bastion and an SSM tunnel that `make mint-era` sets up. For a domain on a shared database, not even that is generated. `merge_tail`, `compact`, `heki_compact`, `reattest_era` and `backfill_era_projections` have no production path at all, although the host's own tamper refusal tells an operator to run `reattest_era`. A shared-database domain also cannot approve an edge in production. An edge with compute or rekey rules would therefore stop it booting.

- **Custodian's database-touching commands run as a one-off task inside the VPC.** Build produces a small ops image from the pinned gem. Deploy runs one Custodian command in it as a one-off ECS task beside the database (`hecks deploy run_era <domain> <command> …`), following the pattern previews already use for database setup. RDS stays private, and no laptop needs a tunnel. A laptop tunnel remains for rehearsing against a scratch database.
- **The host stays runtime only.** It keeps minting and checking approvals at boot, and serves nothing for Custodian beyond `GET /version`.
- **Each operation has one owner.** The host mints a host-run domain; Custodian never does. Custodian owns what an operator starts: approving an edge, re-attesting, merging a tail, compacting, backfilling and holding the first era. The mint's audit and the approval digest stay implemented in both languages, held together by the existing parity specs.
- **Shared-database domains get the same path,** which gives them their first way to approve an edge in production.

## Consequences

- Checks and lifecycle actions leave a history in the journal, so a regression such as the runtime baseline going stale shows up as an event instead of passing unnoticed.
- `model_check` can see the rules that were hidden inside scripts, including QualityControl's PR-opening rules.
- The `hecks` launcher replaces 92 separate front doors, and its help text comes from the bluebook.
- Every reference to `bin/<name>` changes in the same pass: `.github/workflows/`, `Makefile`s generated by `project_deploy`, pre-commit and pre-push hooks, specs that shell out, `docs/`, the README, and the `exe/hecks` routes from ADR 0066, which become Hecks commands with the same names.
- Some scripts are processes by nature: `console` and `follow` are interactive, `qa_concurrency_racer` and `stress_concurrency_specs` must run as separate OS processes, and `qa_tick` forks other steps. Their commands exist, but the adapter behind them still starts the process or session, and the journal records that it ran, not what the session did.
- `project_cli` generates every launcher, including `hecks` itself, and `project_cli` is itself a Hecks command. The generated `exe/hecks` is committed, so the cycle only matters when regenerating it: the previous `exe/hecks` produces the next one.
- The Hecks domain boots only when `exe/hecks` runs, never from `lib/hecks.rb`, so boot cost for an ordinary domain does not change.
- The gem grows by the tooling ADR 0066 left out, the new domain and about 4 MB of Rust source. That is disk, not memory: none of it loads unless `exe/hecks` runs.
- `spec/gemspec_packaging_spec.rb` asserts that the Rust workspace ships without `target/`, `rust/tests/` or any generated corpus domain, and that `lib/hecks.rb` loads none of the tooling.
- An installed gem's `hecks --help` lists the Codebase and QualityControl verbs too, each refusing with "needs a hecks checkout" when run outside one.
- The publish adapters (RubyGems, npm) ship in every copy of the gem. They hold no credentials; publishing still needs the maintainer's own keys, and the checkout `given` refuses first.

## Alternatives considered

- **Hand-written launchers per command.** Keeps `bin/<name>` as a short script that dispatches one verb. Rejected: `project_cli` already generates a launcher from the bluebook, and hand-written ones drift from it.
- **One bluebook per concern** (Release, RuntimeBaseline, LanguageContract, DocCoverage, Codemod, and so on). Rejected: it produces a dozen front doors and a dozen hecksagons with the same wiring.
- **Custodian and Codebase as two separate bluebooks.** Rejected: two launchers beside `exe/hecks`, and no domain for the framework itself.
- **Splitting Custodian from Codebase by what ships.** Rejected once everything ships: the only difference left is who the command is for, and splitting by packaging had put client needs such as building a domain's wasm behind the checkout refusal.
- **Keeping Codebase and QualityControl out of the gem** (ADR 0066's split, with the gemspec filter excluding `codebase.bluebook`, a second `codebase.hecksagon` and `adapters/codebase/`). Rejected: keeping deployments small is already handled by not loading the tooling and by Rust images, and the split cost a second hecksagon for one domain, file-level packaging rules, and two kinds of install that boot different domains.
- **Merging Bluebook, Deploy and QualityControl into the Hecks chapter** (`QualityControl::Patch` becoming `Hecks::Patch`, and so on). Rejected: the QA ledger's era and tables are keyed by the chapter name and would need a data migration, and renaming the self-hosted Bluebook chapter reaches into the meta-validator.
- **Merging the two Translation chapters as part of this ADR.** Rejected: it is a language change with its own risks, now [ADR 0082](0082-the-two-translation-chapters-become-one.md); this ADR only needs the names not to collide.
- **Attaching the framework members too** (Governance, Identity, Privacy, Compliance, ConsoleSettings). Rejected: they are libraries application domains use; Hecks uses Governance rather than owning it.
- **All aggregates in a single `hecks.bluebook` file.** Rejected: fourteen aggregates in one file is hard to read; the root, Custodian and Codebase files each hold one concern.
- **Repository-level directories, like `qa/`.** Rejected in favour of `lib/hecks/`, so everything ships and sits beside the runtime it operates on.
- **Phased migration** (Release first, then checks, then Codebase, across several releases or pull requests). Rejected in favour of one pull request of ordered commits (section 9), so the repository never has two ways to run the same tool. The 2.x warning release only prints text; it runs nothing new.
- **Leave the scripts as they are.** Rejected: results keep leaving no history, and the rules stay out of the model.

## Open items

- The ops image's contents and size, and whether it is built per domain or once per gem version.
