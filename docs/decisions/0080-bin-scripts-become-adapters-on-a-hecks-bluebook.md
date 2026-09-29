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

Two chapters are named Translation today; section 6 merges them before Translation is attached.

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
| Adapter | Adapter chapter (exists) | adapter name | gains what the adapter supports, such as saving saga state, which a domain today only learns from a warning at boot | the `.adapter` declarations `lib/hecks/adapters/driven/` already holds |

The Hecks domain's own adapters (InProcessBoot, JournalStore, RustToolchain and the rest in this ADR) get `.adapter` declarations too, so they appear beside the built-in ones.

Release moves to the root because every install has a version, and "what am I running" and "what did we ship" become one record. The steps that publish a release (tagging, pushing to RubyGems and npm) stay in Codebase as Publishing, and advance the root's Release through its lifecycle.

What stays code is the interpreter and the IO inside each adapter.

### 6. One Translation chapter

Two chapters are named Translation, and they are two halves of one concept:

- `lib/hecks/grammar/translation.bluebook` is the register of rule kinds. A `Rule` moves from proposed to admitted to retired and must execute in at least two targets before it is admitted. Its `Map` aggregate is an edge between two eras.
- `lib/hecks/language/translation/` is the meta-model of one `translations/*.bluebook` edge file: the `Translation` aggregate (domain, from era, to era) and `TranslationAggregate` with its typed rule lists. `MetaValidator` loads it into the shared grammar registry, and `TranslationJudge` dispatches to it.

They overlap. `Rule.Kind` repeats the language chapter's rule words, held equal only by `spec/translation_vocabulary_conformance_spec.rb`, and `Map` duplicates the `Translation` aggregate. They have never shared a registry: `Hecks::Grammar.grammar_chapters` loads the grammar chapter alone. That separation is the only reason the shared name works today, and attaching both to Hecks would end it.

They become one chapter, spread over files the way `lib/hecks/language/bluebook/` is:

- `grammar/translation.bluebook` moves to `lib/hecks/language/translation/rule.bluebook` and keeps opening `Hecks.bluebook "Translation"`.
- `Map` folds into `Translation` and `TranslationAggregate`, so an edge has one aggregate.
- `Rule` is where rule kinds are declared. The language chapter's rule words read from it, so the conformance spec that holds two lists equal is no longer needed.
- The `Translation` block in `lib/hecks/grammar/grammar.hecksagon` goes; the merged chapter is wired where the language chapter already is.

What changes with it:

- `Hecks::Grammar.grammar_chapters`, and the globs in `lib/hecks/codemod.rb` and `lib/hecks/corpus.rb`, point at the new file.
- `spec/parser_parity_spec.rb` parses Translation as a chapter of several files.
- The corpus replay `spec/corpus/translation.json` loses its `Translation::Map.*` verbs in favour of the edge aggregate's.
- SyntaxBoot's disk cache is keyed over every chapter in the shared registry, so the merge invalidates it once.

No data moves: the grammar chapter persists to Memory and keeps no records, and neither chapter has an IR golden.

### 7. Where each script goes

| Bluebook or part | Aggregate | Scripts |
| --- | --- | --- |
| Custodian | Introspection | `ir`, `shape`, `stores`, `history`, `statements`, `narrate`, `docs`, `project_diagrams`, `project_glossary`, `model_check` |
| Custodian | Operation | `run`, `project`, `behaviors`, `console`, `follow`, `smoke_test`, `smoke_http` |
| Custodian | Host | `check_era` |
| Custodian | Era | `merge_tail`, `reattest_era`, `backfill_era_projections`, `scaffold_translation`, `translation_audit`, `compact`, `heki_compact` |
| Custodian | Package | `vendor_bluebook` |
| Custodian | Door | `project_cli`, `hecks_mcp_door` |
| Custodian | Build | `project_rust`, `project_wasm`, `project_wasm_browser`, `rust_coverage`, `rust_conformance`, `rust_conformance_fuzz` |
| Custodian | Fuzzing | `fuzz`, `generate`, `bench` |
| Deploy (existing) | Deploy | `project_deploy`, `lint_deploy_recipes`, `deploy_template_diff`, `project_oidc`, `project_tenant` |
| Codebase | Language | `project_model`, `project_vocabulary`, `project_rust_vocabulary`, `project_refusal_wording`, `project_reserved_names`, `project_parser_table`, `project_bootstrap_table`, `project_field_hints`, `expression_projection`, `reference`, `evolve` |
| Codebase | Regeneration | `regen_codegen_domains` |
| Codebase | Kernel | `project_kernel_capabilities`, `rust_kernel_coverage` |
| Codebase | Conformance | `check_engine_agreement`, `doc_coverage`, `argument_gate_matrix` |
| Codebase | Style | `standardize_comments`, `standardize_comments_rust`, `canonicalise` |
| Codebase | Codemod | `codemod_hoist_local_givens`, `codemod_implicit_append_fields` |
| Codebase | TestSuite | `rspec_shard_files`, `rspec_io_parallel_files`, `refresh_rspec_runtime_baseline`, `spec_example`, `stress_concurrency_specs`, `regenerate_persistence_legacy_fixtures`, `seed_semantics_corpus`, `pattern-cases` |
| Codebase | Corpus | `corpus`, `query_ir`, `hecks_query_ir_mcp`, `present` |
| Codebase | Publishing | `release`, `release_gem` |
| QualityControl (existing) | as listed per script | `qa_tick`, `qa_sweep`, `qa_pr_check`, `qa_open_pr`, `qa_log_bug`, `qa_seed_angles`, `qa_seed_targets`, `qa_generated_domains`, `qa_mine_combinations`, `qa_domain_novelty`, `qa_discover_external_domains`, `qa_postgres_migrate`, `qa_postgres_role`, `qa_concurrency_racer` |

Publishing goes to Codebase rather than Custodian because it publishes this repository's gem, so it only runs in a checkout. The Release it advances lives in the root (section 5).

Building for the Rust host is split by the same test. Custodian's Build generates and compiles one domain, the way a client deploying to `rust/host` does, and checks that build against the Ruby engine: `rust_conformance` replays a script through both, `rust_conformance_fuzz` does the same with generated sequences, and `rust_coverage` reports which of the domain's constructs are routed. Codebase's Regeneration rebuilds every corpus domain's committed output, which only this repository has, and Codebase's Conformance keeps the checks on the language itself (the kernel, the query engines, the reference docs).

`project_refusal_wording` is an alias for `project_rust_vocabulary`; it becomes a second name for the same Language command, not a command of its own.

### 8. QualityControl

The rules hand-coded in `qa_open_pr` and `qa_pr_check` move onto `Patch.Open` and `Improvement.Open`. Three are `given`s today: the branch prefix (a `pattern:` on the branch), the bug being fixed and the angle being under investigation (givens that read through the reference, as `customer.status == "active"` does in the banking example). The other two follow [ADR 0081](0081-commands-declare-the-outside-facts-they-need-and-a-rule-across-records-gets-an-aggregate-that-owns-it.md), and stay in the `GitPr` adapter until it lands:

- **The per-day PR cap** becomes a `DailyQuota` aggregate, identified by date, from which each `Patch.Open` takes a slot.
- **"The fix commit is an ancestor of `HEAD`"** becomes a fact `Patch.Open` declares and the `GitPr` adapter answers at dispatch. Their `git` and `gh` calls move into a `GitPr` adapter. The declared `IssueTracker` port gets a bound adapter.

### 9. This ships as 3.0.0

Under [ADR 0068](0068-releases-keep-their-pace-and-state-a-two-tier-promise.md) a major version means a breaking DSL or runtime change with a CHANGELOG `Breaking:` entry, and this ADR makes several:

- `exe/hecks` stops being a hand-written router and becomes the generated launcher. The command names stay, but arguments are projected from the bluebook by `CliRunner`, so flags and argument order change.
- `bin/` goes. `Makefile`s that `project_deploy` generated in client repositories call `bin/<name>` and stop working until they are regenerated.
- A domain whose chapter is named `Hecks` collides with the new Hecks domain.
- `Translation::Map` is removed by the Translation merge.
- The gem's contents change: everything ships (section 3).

ADR 0068's rule 4 gives a break that reaches an installed client site one release of warning where a warning is possible. The two parts that reach client sites get one:

- **The last 2.x minor warns.** `exe/hecks` accepts the old argument forms and prints the new form beside each result, and `project_deploy` regenerates Makefiles against `hecks <verb>` while the old `bin/` paths still resolve. Each warning names 3.0.0 as the removal version.
- **3.0.0 removes them.** The old argument forms and every `bin/` path go.

Inside this repository the move is still one pass: there is never a second way for a maintainer to run a tool. Client pins move to `3.0.0` explicitly, because deploys pin exactly (ADR 0068, rule 3). 3.0.0 is the first release the root's Release aggregate records.

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
- **The adapter list, checked against the code:**
  - **Release.** Release calls `git`, the RubyGems API and `gem`, `npm`, and the filesystem. It never runs `gh`; the command appears only in hint text. It also needs a SecretVault adapter (1Password `op run`), the existing `clock` port, and the Terminal adapter for its y/N confirmations.
  - **Deploy.** Deploy makes no AWS, Docker or `make` calls from Ruby. `project_deploy` renders the Makefile and scripts, and those run `aws`, `docker` and the rest when an operator runs them. Deploy therefore needs only Workspace and TenantProvisioning (which writes an environment's `.world` file). Lint runs `make` as a subprocess to check recipes, and that is Deploy's one other adapter.
  - **Environment variables** (`HECKS_PROJECT_ENVIRONMENT`, `HECKS_SCHEMA`) are read through the world configuration rather than inline.
- **Rules found inline become givens.** On Release: releasing from `main` equal to `origin/main` on a clean tree, the client package version matching the gem's, a CHANGELOG heading for the version, and an existing tag pointing at the release commit. On Deploy: `--schema` requiring `--tenant`, and the adapter being AwsLambda or AwsFargate.

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
- **Renaming the grammar chapter to `TranslationGrammar`** instead of merging. A few lines of change, and it would unblock attaching. Rejected: it keeps two lists of rule kinds and two edge aggregates, held together by a spec instead of by the model.
- **Attaching the framework members too** (Governance, Identity, Privacy, Compliance, ConsoleSettings). Rejected: they are libraries application domains use; Hecks uses Governance rather than owning it.
- **All aggregates in a single `hecks.bluebook` file.** Rejected: fourteen aggregates in one file is hard to read; the root, Custodian and Codebase files each hold one concern.
- **Repository-level directories, like `qa/`.** Rejected in favour of `lib/hecks/`, so everything ships and sits beside the runtime it operates on.
- **Phased migration** (Release first, then checks, then Codebase). Rejected in favour of one pass, so the repository never has two ways to run the same tool. The only overlap is the one 2.x release of warnings ADR 0068 requires for client sites (section 9).
- **Leave the scripts as they are.** Rejected: results keep leaving no history, and the rules stay out of the model.

## Open items

- Whether the `.adapter` language can already state what an adapter supports (saga state, transactions, the outbox), or needs a word for it before those become queries.
- If a Ruby deployment ever needs a smaller footprint on disk, Deploy prunes the unloaded tooling when it builds the image, instead of the gem leaving it out.
- Two defects the survey of the store scripts found, to fix with the move or before it: `bin/compact` does not yet apply ADR 0079's per-projection floor, and `translation_audit` and `scaffold_translation` write to the store (`hold_first!`) while reading.
- Which store each part persists to. A shared history of CI checks needs a durable store that CI can reach. Local runs may use Sqlite under `Hecks::CacheDir`.
- The exact command names and arguments for each script, written out per aggregate before the migration starts.
- Whether `rust/host` needs any of Custodian, or whether it stays Ruby-only operational tooling.
- Where the new bluebooks' specs live: beside each bluebook as `.behaviors` files, or under `spec/`.
