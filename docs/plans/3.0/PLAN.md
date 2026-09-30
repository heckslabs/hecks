# Plan: build hecks 3.0 from ADR 0080

> **Status:** this is the original plan, kept as written. The build has moved on: see
> [HANDOFF.md](HANDOFF.md) for what is committed, what remains, the gap register and the
> follow-ups. The design behind it is ADR 0080, on branch `worktree-adr-0080-bins-as-adapters`
> (`docs/decisions/0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md`).


## Context

`bin/` holds 92 hand-written scripts that do IO inline, leave no history, and hide their rules from the model. ADR 0080 (draft PR heckslabs/hecks #921, branch `worktree-adr-0080-bins-as-adapters`) turns every script into a command on one `Hecks` bluebook, with adapters behind ports and one generated launcher.

The design was settled in review on 2026-09-28/29, and every decision is in the ADR:

- **Parts.** Custodian is for clients and Codebase is for maintainers.
- **Packaging.** Everything ships, including the Rust workspace.
- **Chapters.** The framework's own chapters are attached.
- **Commands.** The section 7 command table, and section 12's argument conventions.
- **Production era work.** Section 13: decisions are committed files the host applies at boot.

This plan builds it. **Out of scope:** ADR 0081 (outside facts, 3.x), ADR 0082 (Translation merge), and the section 13 items marked 3.x.

**Outcome:** 2.10.0 ships text-only warnings. Then 3.0.0 ships from one pull request of ordered commits, each keeping the whole suite green. After 3.0:

- `bin/` is gone.
- `exe/hecks` is generated.
- Every script's behavior runs as a journaled command.

## Step 0: fix the flaky pre-push spec, in PR #921

**The symptom:**
- `spec/corpus_rust_spec.rb:42` ("regenerates the committed Cargo default last") failed twice while pushing PR #921.
- `cargo_default` read a different domain each time: `embryonaut_vendoring_demo`, then `ledger_ordering`.
- The regeneration order's last domain was always `read_model_on_target_fixture`.

**The cause:**
- `.githooks/pre-push` runs its checks concurrently (`run_check … &`). `codegen_drift` (`bin/regen_codegen_domains --check`, line 75) runs beside `parallel_rspec`.
- The drift check regenerates every corpus domain in place, into the real `rust/`.
- Each `bin/project_rust` run rewrites `rust/Cargo.toml`'s `default` to its own domain, so the file matches the committed default only once the sweep ends.
- The spec reads `Cargo.toml` mid-sweep.
- Separately, the Rust codegen path (`rust/project_rust_pipeline.rb`) ignores `HECKS_RUST_DIR`: it hardcodes `../rust/src/generated` (line 112) and `../rust/Cargo.toml` (line 346). `bin/project_rust`'s Ruby path already honors it (line 245).

**The fix:** a check should never mutate the working tree.
- **`bin/regen_codegen_domains --check`:**
  - Copy `rust/src/generated/` and `rust/Cargo.toml` into a scratch directory.
  - Run every domain's `bin/project_rust` with `HECKS_RUST_DIR` pointing at the scratch copy; the forked children inherit the env.
  - Compare the scratch output against the committed files with `git diff --no-index --exit-code` on both paths.
  - The worktree is never written.
  - Plain regeneration, without `--check`, keeps writing in place as today.
- **`rust/project_rust_pipeline.rb`:** read `HECKS_RUST_DIR` for `out_root` and `cargo_toml_path` (same default as `bin/project_rust`), so the Rust codegen path can't leak into the real crate either.
- **No change** to `spec/corpus_rust_spec.rb` or the hook's concurrency.

**Verification:**
- `bin/regen_codegen_domains --check` passes, and leaves `git status` clean with `rust/Cargo.toml`'s mtime unchanged.
- A deliberate drift, such as editing a generated file, still fails the check.
- Run `spec/corpus_rust_spec.rb` in a loop while `--check` runs: no failure.
- Push PR #921 through the unchanged hook.

## Progress (local commits only; the user said not to push)

- **Step 0:** codegen race fix, committed on the ADR branch (`8df45d3c`) and cherry-picked to 3.0 (`cf350819`).
- **2.10.0:** branch `hecks-2-10-warnings` (worktree `.claude/worktrees/hecks-2-10-warnings`), commit `6bcaba8a`.
- **3.0:** branch `hecks-3-0` (worktree `.claude/worktrees/hecks-3-0`), on top of 2.10:
  - 1/11 guard spec `5e4f8c47`
  - 2a argument forms and bare queries `69e2ffc3`
  - 2c `attaches` word `38312c0f`
  - 2d routing to attached chapters `32085a07`
  - 2e `namespace` word, and the `::Hecks` refusal `fea89025` (commit 2 of the plan is done)
- **Next:** commit 3 (Hecks root). In it:
  - `lib/hecks/hecks/hecks.bluebook` declares `namespace "Hecks::Domain"`.
  - Drop the `namespace` and `attaches` word_coverage exemptions and the optionality `namespace` entry.
  - Add `lib/hecks/hecks/*` to word_coverage `CORPUS_GLOBS`.
  - Still to do: record the `Hecks::Domain` decision in ADR 0080 on the `worktree-adr-0080-bins-as-adapters` branch.
- **Next, 2e/2f (in progress):**
  - **Decision (user):** the Hecks chapter's constants nest under `Hecks::Domain`, through a new chapter word `namespace "Hecks::Domain"`. This avoids Release, Codemod, Corpus, Fuzzing and Kernel colliding with the gem's own `Hecks` module.
  - **Ruby:** mirror `formerly_known_as` in grammar rows, `BluebookBuilder`, `Chapter` IR, Rust `ir.rs`/`emit.rs`/`parse/chapter.rs`, and the goldens (`GOLDEN=rewrite`).
  - **Install paths:** `Facade.install` / `surface/chapter.rb`, and `router/namespace_installer.rb#namespace_for`.
  - **Refusal (2e):** refuse any chapter whose module would be `::Hecks` itself.
- **Working notes:**
  - Commit with `SKIP_POST_COMMIT_FUZZING=1`, since the post-commit hook runs the whole fuzz suite synchronously.
  - Run `parallel_rspec` before each commit.
  - Record the `Hecks::Domain` decision in ADR 0080 on its own branch.

## Release sequence

1. **2.10.0, the warning release**, from its own small PR off `main`:
   - Each `bin/` script prints its 3.0 form (taken from ADR section 7) beside its result.
   - The `exe/hecks` routes do the same.
   - `project_deploy` writes a comment into generated Makefiles naming the `bin/` calls that change.
   - Every warning names 3.0.0 as the removal version.
2. **3.0.0, the big PR**: the eleven commits below, on a branch off `main` after 2.10.0.

## The 3.0 pull request, commit by commit

Each commit runs the full pre-push gate green. `bin/` scripts keep working until commit 11.

### 1. Runtime-boundary guard spec
- New file `spec/hecks_domain_boundary_spec.rb` (ADR section 10).
- **After `require "hecks"`:** nothing under `lib/hecks/hecks/` is in `$LOADED_FEATURES`.
- **After a client boot:** a boot plus a dispatch through `Hecks::Facade::CliRunner` loads nothing there either.
- **Registry:** the client's registry has no `Hecks` chapter unless its hecksagon attaches it.
- It passes trivially now, and guards every later commit.

### 2. Launcher changes, plus routing to attached chapters
Four changes in `lib/hecks/facade/cli_runner.rb` and `lib/hecks/facade/cli_door.rb` (`CliDoor.arguments`):
- **Positional identity.** The first identifying argument may be positional.
- **Booleans.** `--name` sets a boolean.
- **Bare queries.** A bare name resolves to a query; `ask` is needed only when a command and a query share the name.
- **Routing.** A first argument naming an attached chapter routes to that chapter. Today `bluebooks.values.first` serves one chapter only.

Supporting changes:
- **Attaching.** A new hecksagon word `attaches` in `lib/hecks/bluebook/dsl/hecksagon_builder.rb`, modeled on `uses_framework`. It resolves by chapter name through a chapter index, generalized from `Hecks::Framework.members` (`lib/hecks/framework.rb`) to every chapter the gem carries.
- **Reserved name.** `Hecks` becomes a reserved chapter name through the reserved-names mechanism behind `bin/project_reserved_names`.
- **Specs.** Existing launcher behavior must not change, since these are additive forms.

### 3. The Hecks root, with DomainRuntime and Workspace
- `lib/hecks/hecks/hecks.bluebook`: vision, plus the Release and SyntaxBootCache aggregates.
- `lib/hecks/hecks/hecks.hecksagon`: `uses_framework "Governance"`.
- `lib/hecks/hecks/adapters/`: `in_process_boot`, `local_files`, each with a `.adapter` declaration.
- A `.behaviors` file beside the bluebook, in the style of `examples/pizzas/bluebook/pizzas.behaviors`.
- The checkout `given`: a working tree with `hecks.gemspec` beside `lib/`.

### 4. Custodian, one commit per aggregate
Order: Introspection, Operation, Host, Era, Package, Door, Build, Fuzzing.

- **Where things go:**
  - commands and queries in `lib/hecks/hecks/custodian.bluebook`
  - adapters in `lib/hecks/hecks/adapters/`, from ADR section 11: JournalStore, HostHttp, Terminal, RustToolchain, ProcessPool, PgAdmin, Git, Shell
- **Reuse the logic that exists; only the entry point and the IO boundary move:**
  - `Hecks::CLI::*` (`lib/hecks/cli/`)
  - the era plugin under `lib/hecks/ports/persistence/plugins/era/`, including `EraCheck`, `EraStore#verify_integrity!`, `TailMerge`, `Reattest` and `LineageManager`
  - `Hecks::Bench::CLI`
  - `Hecks::Fuzzing`
  - the `project_rust` pipeline in `rust/project_rust_pipeline.rb`
- **Era's guards:** the flag-style guards become `given`s (`--confirm`, named winners, era beyond 1, one edge leaving). The database-level guards stay in JournalStore.
- **Reading never writes.** `AuditTranslation` and `ScaffoldTranslation` become queries, and the new `HoldFirst` takes over `hold_first!`.
- **Compact** refuses for any aggregate with a bound projection until ADR 0079's floor exists.
- **The committed approval (3.0 scope):**
  - `ApproveTranslation --confirm` writes `translations/<edge>.approval` as JSON: `edge`, `edge_digest`, `approved_by` (git identity), `approved_at`, and a `rehearsal` block required for compute or rekey edges.
  - `rust/host/src/approval.rs` also accepts a committed approval matching the edge digest, and writes it into the journal when it applies it.
  - This needs a Rust change plus a parity spec against Ruby's `ApprovalDigest`.
  - `host_version` is enforced: the host reports the Hecks release it was built for (`rust/host/HECKS_RELEASE`, equal to `Hecks::VERSION`, checked by the release preflight and a spec), and a rehearsal counts only when its `host_version` has the same `major.minor` as that release. Ruby (`ApprovalFile`, on boot) and Rust (`approval.rs`) refuse with the same wording naming both versions; `ApproveTranslation` records `Hecks::VERSION` when `host_version` is omitted.

### 5. Codebase, one commit per aggregate
Order: Language, Kernel, Conformance, Regeneration, Style, Codemod, TestSuite, Corpus, Publishing.

- `lib/hecks/hecks/codebase.bluebook`, with its adapters in `lib/hecks/hecks/adapters/codebase/`: SourceTree, GitHub, GemRegistry, NpmRegistry, SecretVault, RubyChild, TestRunner, SqliteFixture.
- **Reuse:** `Hecks::Release::Runner` (`lib/hecks/release/`) keeps its collaborators; its `Commands` and `Git` become adapters. Also `Hecks::Codemod`, `Hecks::QueryIR` and `Hecks::Corpus`.
- Mode flags become separate commands: `evolve`'s ten, the comment standardizers, `corpus`, `query_ir`.
- `RubyChild` calls between hecks tools become in-process dispatches, except where isolation is the point.

### 6. Attach the language chapters, Tenancy and Deploy
- `hecks.hecksagon` attaches Bluebook (Paging comes with it), Hecksagon, World, Adapter, Port, Translation (the language's chapter only), Expression, Tenancy and Deploy.
- **Deploy gains** `Project`, `Lint`, `Diff`, `ProjectOidc` and `Tenant.Provision`, keeping its `TenantProvisioning` port.

### 7. Move QualityControl into `lib/hecks/quality_control/`
- Move `qa/bluebook/` and `qa/adapters/` there; attach it from `hecks.hecksagon`.
- **Stays in `qa/`:** the `.world`, `settings.yml`, the stress domains, and data.
- **Rules as givens:** the `qa_open_pr` branch prefix, bug fixed and angle investigating.
- **Still in the adapter:** the per-day cap and ancestry stay in the new `GitPr` adapter (ADR 0081, 3.x).
- **Bind** the `IssueTracker` port and add the `Agent` adapter.
- The QA ledger's era and tables keep their chapter name, so no data moves.

### 8. Package the Rust workspace, and the gemspec
- **`hecks.gemspec`:** drop the `dev_tooling` filter; add `rust/` without `target/`, `rust/tests/`, or `rust/src/generated/<corpus domain>`, and with a clean `Cargo.toml` feature list.
- **Build** copies the packaged workspace to `.hecks/rust/<version>/` in the client project before generating, and never writes into the gem.
- **`spec/gemspec_packaging_spec.rb`** changes:
  - The Rust workspace ships.
  - Nothing generated ships.
  - `lib/hecks.rb` loads none of the tooling.
  - This replaces its "leaves every repository-only tool out" example.

### 9. Generated `exe/hecks`
- Generate `exe/hecks` with `project_cli`, replacing the hand-written router in `lib/hecks/cli.rb`'s `when` routes.
- The ten names ADR 0066 shipped keep their form.
- The committed launcher is the bootstrap.

### 10. CI, hooks and docs
- Point the 10 workflows in `.github/workflows/` that call `bin/` at `hecks <verb>`.
- Do the same for the pre-commit and pre-push hooks, and for Makefiles generated by `project_deploy`.
- Also update `docs/`, the README, CONTRIBUTING's release steps, and specs that shell out to `bin/`.
- CI journals only on `main` and in the merge queue; PR runs use Memory.

### 11. Delete `bin/`
- Delete every script.
- Add a spec asserting `bin/` holds no hand-written script.
- Write the CHANGELOG `Breaking:` entry for 3.0.0, listing ADR section 9's breaks.

## Verification

- **Every commit:** the full pre-push gate (suite, fuzzer, engine agreement, model checks, rubocop, codegen, comments).
- **The boundary guard spec** stays green from commit 1 on.
- **Command table coverage:** the section 7 table maps all 92 scripts. A spec checks every row has a command the launcher resolves (`hecks <verb> --help` answers).
- **Installed-gem smoke:**
  - Build the gem and install it into a scratch directory.
  - Run `hecks ir`, `hecks stores`, and `hecks build_wasm` against a sample domain outside a checkout.
  - Confirm a Codebase verb refuses with "needs a hecks checkout".
- **Client launcher smoke:** regenerate a client domain's launcher and confirm today's `verb name=value` calls still work, alongside the new forms.
- **Committed approval:** rehearse on a scratch Postgres with `mint_harness`. A committed approval for an edge boots, and a mismatched digest refuses.
- **Release dry run:** `hecks publish` without `--confirm` does what `bin/release --dry-run` did.

## Risks

- **PR size.** Mitigated by ordered, individually green commits (ADR section 9). Review goes commit by commit.
- **Launcher changes reach every client.** They're additive only, and commit 2 pins today's forms with specs.
- **Host approval change.** It must keep today's tip-bound journal approvals working (ADR section 13: either source satisfies the check).
- **Moving QualityControl** touches the live QA loop. Run a tick against the moved chapter before merging.
