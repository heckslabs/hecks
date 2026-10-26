# An environment variable is a one-off override or a secret

**Status:** Proposed. Date: 2026-10-25. Partly built on this branch, not released.

## Context

Hecks reads many environment variables. Most exist because a thing had no default
location or no default name, not because a person needs to vary it per run. Each one is
a hidden input: it is absent from the bluebook, the hecksagon and the world, and a copy
works or fails depending on the shell that launched it.

## Decision

1. **If it describes what something is connected to, it is declared** in a world or a
   hecksagon (the same split bluebook and hecksagon already make).
2. **If it is derivable from where the copy lives, it is derived.** Nobody declares it.
3. **If it varies per run, it is an argument of the hecks command that runs.** A command
   may set a variable for its child process (as `GOLDEN` and `CI` are set), but a person
   does not set it.
4. **Only a secret, a platform variable, or an override for a process no hecks command
   runs is an environment variable.** A secret is read from 1Password and never written to
   config.
5. **Precedence:** an explicit variable, then the world, then the derived default.
6. **`hecks config` prints each resolved value and which of the three supplied it**, so
   derivation is never hidden.
7. **Retirement:** a variable that has a replacement logs a deprecation warning for one
   release, then is no longer read.

## Classification

**Derived by default, the variable only an override (keep as a documented override):**
These already compute their value from where the copy lives; the variable exists to point
somewhere else, and nothing needs it set. Surveying the reads showed each is also how a value
crosses a process boundary, so retiring them is a larger change than deleting a read.
- `HECKS_RUST_DIR`: `RustBuild.rust_dir` defaults to the checkout's `rust/`, and a
  workspace copy of an installed gem is passed to in-process tools by swapping `ENV` under a
  lock (`RustBuild.with_env`, `RustWorkspace#environment`), and to forked or spawned
  children through their environment. An explicit workspace parameter would replace the
  in-process swap; the variable would stay for children.
- `CARGO_TARGET_DIR`: Cargo's own variable. Hecks sets it for the Cargo it starts and
  honours the user's (`TargetDir`); it is not hecks's to retire.
- `HECKS_CACHE_DIR`, `HECKS_STOREHOUSE_ROOT` (the sandbox root the MCP servers widen on
  purpose), `HECKS_QA_SETTINGS_PATH`, `QA_REPO_DIR`, `HECKS_PARSE_BIN` (the editor
  extension's setting), `HECKS_VALIDATE_HARNESS`: each has a computed default and exists as a
  deliberate override for a subprocess, a sandbox or an editor.

**Derived (done, the variable stays an override):**
- `EMBRYONAUT_BLUEBOOKS_SRC`: `VendorCli.default_source` finds the `embryonaut_bluebooks`
  checkout beside the project when neither `--from` nor the variable names one.

**Interface of a deployed host (declared by the deploy projection, not derived):**
`HECKS_IR_PATH`, `HECKS_WASM_PATH` are set by the generated CloudFormation, Dockerfile and
Lambda templates to tell the Rust host where its sidecars are, and the host refuses to boot
without the first. A default of "beside the binary" would retire them, but it changes the
Rust host and every template together, so it is its own change.

**Not in this repository:** `HECKS_LIB` and `HECKS_TRAIN_HOME` are read by other projects'
tooling and the user's launcher, not by hecks.

**Declared in the world (retire the variable):**
`HECKS_DATABASE` (the copy's `environments/local.world`, else a database named for the
domain), `HECKS_SCHEMA`, `HECKS_PROJECT_ENVIRONMENT`, `DATABASE_URL`, `POSTGRES_URL` and
`SHOP_DATABASE_URL` for era tooling, `HECKS_DOMAIN`, `HECKS_SERVICE_URL`, `SITE_URL`,
`DOMAIN_NAME`.

**Already declared; the variable is only how a generated deploy delivers it:**
The host's wiring (`HECKS_SESSION_COOKIE`, `HECKS_ROLE_ENFORCEMENT`, `HECKS_SERVE_MODE`,
`HECKS_DOMAIN`, `HECKS_SCHEMA`), the OAuth ids and redirect URIs, and the analytics settings
are declared in the deploy block and written into the task definition or CloudFormation
environment by the deploy projection (`projections/deploy/preview/task_yaml.rb`, the
`template.yaml.tmpl` files). A person sets none of them; the deployed Rust host reads its
environment, as it reads `HECKS_IR_PATH`. So the question of where host wiring is declared
is answered, and there is nothing to move: the deploy block declares it and the environment
carries it to a process that has no other channel.

**Interface of the generated scripts (moves with them, in one change):**
`SMOKE_CONFIG`, `SETTLE_TIMEOUT_SECS`, `SKIP_POST_DEPLOY_SMOKE`, `LOCAL_IMAGE`,
`SMOKE_BY_COMMAND` and `EXISTING_TAG` are the knobs of `deploy-service.sh`,
`smoke-after-deploy.sh` and the smoke harness. They become flags together when the scripts
take flags.

**Tooling choices, overrides with a computed default:** `HECKS_COMPOSER_AGENT` (`claude`, or
`fake` for a scripted agent in the editor's browser tests; `Workbench` already takes the
agent as an argument), `HECKS_JEV` (the `jev` binary, on `PATH` by default) and
`QA_MINER_AGENT` (the command `QaSettings` names). `corpus_run.compose` could take an `agent`
argument for the first. `HECKS_SCAFFOLD` is a flag on the era command, and
`HECKS_CONTRACT_WAIT_SECONDS` and `HECKS_CONTRACT_PAYMENTS` belong to the client package's
contract test.

**Arguments of the command that runs (retire the variable):**
- `GOLDEN=rewrite`, `EXISTING_TAG`: a hecks command already hands each to its child
  process, so only the hand-off remains. `EXISTING_TAG` is the generated
  `deploy-service.sh`'s own interface, with `LOCAL_IMAGE`, `SETTLE_TIMEOUT_SECS`,
  `SKIP_POST_DEPLOY_SMOKE` and `SMOKE_BY_COMMAND`; it moves to flags with them, in one change
  to the projection and the projects that vendor its output, not alone.
- `HECKS_FUZZ_SCHEMA`: removed. A forked sweep child's default schema, `hecks_fuzz_<pid>`,
  is the name the sweep used to set, so the variable named nothing the default did not.
- `SEEDS`, `STEPS`: `build.fuzz_conformance` already takes `seeds` and `steps`; the
  variable fallback is removed.
- `HECKS_WASM_PROFILE`: the `profile` argument of `build.build_wasm!`, passed on to the tool
  as `--profile=` (built). `ci-rust-host.yml` passes `profile=dev`.
- `HECKS_PREBUILT=off`: the `prebuilt` argument of `build.build_host!`, passed on to the tool
  as `--no-prebuilt` (built).
- `HECKS_ENVIRONMENT`: the world declares the default per command, as `MEMORY_COMMANDS`
  and `hecks.world` already do for the launcher; `run_spec_example!` needs the argument.
- `HECKS_CLOUDFRONT_TEST`: a tag filter on the spec-run command.
- `PROPERTY_SEEDS`: a seeds argument on the spec-run command, which sets it for the child.
- `CI`, `HECKS_PRE_PUSH_GATE`: both mean "run the specs strictly" (`spec_helper.rb`,
  `postgres_probe.rb`, `ci_skip_backstop.rb`, `generated_rust.rb`) and nothing in `lib/`
  reads either. `run_spec_example!` takes `strict` (built). A git hook takes no arguments, so
  the push reaches it as `push_train.board!`'s `full_gate`, which pushes with
  `git -c hecks.fullGate=true` for that push only (built). The pre-push hook and
  `generated_rust.rb` read `git config --type=bool --get hecks.fullGate`, so
  `HECKS_PRE_PUSH_GATE` is retired (nothing reads it; `hecks config` reports it as ignored
  when set), and a repository can keep the full gate on with `git config hecks.fullGate true`. A
  workflow passes `strict` instead of relying on the provider's `CI`.
- `HECKS_PUSH_TRAIN=off`: nothing reads it today (no file in this repository or the user's
  hook configuration names it), so there is nothing to retire; the train needs no argument
  for "not running".

**Retired outright:**
- `HECKS_EVAL=string` forced the text path of rule evaluation. No spec or workflow set it
  and it compared nothing; the switch and its branch are removed.
- `HECKS_PRE_PUSH_GATE`: replaced by `git config hecks.fullGate`; the hook and
  `generated_rust.rb` no longer read it.

**Test switches, kept:** `HECKS_SYNTAX_BOOT_CACHE=off`, `HECKS_VERDICT_CACHE=off` and
`HECKS_NO_USAGE_CACHE` each turn a disk cache off for a child process that must boot
uncached (`verdict_cache_spec`, `syntax_boot_memo_spec`, `cache_dir_spec`,
`usage_cache_spec`). A person ruling a cache out as the cause empties it with
`test_suite_run.clear_caches!`, so the switches are not deprecated and do not warn: they are
how a test process, which no hecks command starts, asks for the uncached path.

**Kept (the whole remaining list):**
- *Overrides with a derived default, nobody needs to set:* `HECKS_RUST_DIR`,
  `CARGO_TARGET_DIR`, `HECKS_CACHE_DIR`, `HECKS_STOREHOUSE_ROOT`, `HECKS_QA_SETTINGS_PATH`,
  `QA_REPO_DIR`, `HECKS_PARSE_BIN`, `HECKS_VALIDATE_HARNESS`, `EMBRYONAUT_BLUEBOOKS_SRC`.
- *Interface of a deployed host, written by the generated deploy:* `HECKS_IR_PATH`,
  `HECKS_WASM_PATH`, `HECKS_SESSION_COOKIE`, `HECKS_ROLE_ENFORCEMENT`, `HECKS_SERVE_MODE`,
  `HECKS_DOMAIN`, `HECKS_SCHEMA`, `DOMAIN_NAME`, the OAuth ids and redirect URIs.
- *Tooling overrides:* `HECKS_COMPOSER_AGENT`, `HECKS_JEV`, `QA_MINER_AGENT`.
- *Per-run, with no hecks command that runs them:* `HOST_FUZZ_SEEDS`, `JSON_FUZZ_SEEDS`,
  `HECKS_PARSE_FUZZ_SEED`, `HECKS_PARSE_FUZZ_ITERATIONS`. They widen a plain `cargo test`
  fuzz run and CI never sets them. A command wrapping `cargo test` could carry them as
  arguments later.
- *Secrets, from 1Password:* the analytics reader password, `API_TOKEN`, `AUTH_SECRET`,
  `SESSION_SECRET*`, `PAYMENT_WEBHOOK_SECRET`, `GOOGLE_CLIENT_SECRET`, `PGPASSWORD`. A
  world file names the 1Password item, never the value.
- *System and platform, not hecks's to remove:* `PATH`, `HOME`, `PORT`, `HOST`,
  `NODE_ENV`, `RAILS_ENV`, `XDG_CACHE_HOME`, `GIT_DIR`, `LAMBDA`, `PGOPTIONS`,
  `OBJC_DISABLE_INITIALIZE_FORK_SAFETY`.

**Not configuration:** `CAPTURE_LOCK_A`, `HECKS_RELEASE_SPEC` and `VERBS` are values a
spec invents to prove a child process sees its environment. `HECKS_NO_DECLARATION_CACHE`
turns off a per-process in-memory memo in `spec/support/declaration_cache.rb`, which no
command can clear; it stays a spec-support switch until the spec runner takes an argument
for it.

## Order of work

1. Done: `HECKS_EVAL` and the `SEEDS`/`STEPS` fallback removed; `HECKS_PRE_PUSH_GATE`
   retired; `test_suite_run.clear_caches!` empties the syntax-boot, verdict and usage caches,
   and the three cache switches remain as test switches.
2. Derived variables: done for the registry source (`EMBRYONAUT_BLUEBOOKS_SRC` now has a
   sibling-checkout default). The rest were already derived with an override, and stay
   overrides (see the classification); `HECKS_RUST_DIR` becoming an explicit workspace
   parameter in process, and `HECKS_IR_PATH`/`HECKS_WASM_PATH` defaulting to the sidecars
   beside the host binary, are separate changes.
3. Arguments: `profile` and `prebuilt` are built, and `run_spec_example!` takes `strict`,
   `seeds` and `environment`, which set `CI`, `PROPERTY_SEEDS` and `HECKS_ENVIRONMENT` for
   that run only, and `push_train.board!` takes `full_gate`. Still to build: a tag filter
   for `HECKS_CLOUDFRONT_TEST`.
4. World-declared variables: `environments/*.world` becomes the one place a copy says
   what it connects to. `hecks config` (the `Checkout.Settings` query, built) prints each
   setting, its value with any password hidden, and which source supplied it: the variable,
   the copy's `environments/local.world`, or the world. `HECKS_DATABASE` is not retired: an
   installed gem's Hecks domain has no copy to hold an `environments/local.world`, so the
   variable is how a client points that domain at their own Postgres (`hecks.world` says so).
   What went wrong was a *global* export that every checkout inherited, and that is gone:
   the push train's launcher names its records database in its own `local.world`
   (`hecks_train`), the export is removed from `~/.zshenv`, and `hecks config` shows which
   source supplies the value. A superseded boot no longer restores era 1's head views.
5. Declared settings: surveyed, nothing to move. The host wiring is already declared in the
   deploy block and delivered by the generated environment; the script knobs move with the
   scripts; the three tooling choices stay overrides.

## Consequences

- A fresh copy runs with no shell setup.
- A variable that is still read but not listed above is a finding the gate can report.
- `HECKS_DATABASE` set globally in a shell, which once let dev checkouts boot newer
  bluebooks against the records database, is gone from the shell profile, and `hecks config`
  shows which source supplies the value.

## The shape ledger

A shape that changed without its translation edge reached `main` green, because specs and gates
run on the memory environment, where eras do not exist, and a database then refused every boot.
`lib/hecks/hecks/shapes.json` records each chapter's storage-shape hash, and
`conformance_run.check_shape_ledger` (a gate check in `unguarded_push`, `pre_push` and `ci`)
holds the loaded chapters against it with no database: a hash that differs needs a committed
translation edge from the ledgered one, the failure prints the edge to write, and `--confirm`
rewrites the ledger only when every moved chapter has such an edge. A boot that is superseded no
longer restores era 1's head views (`Boot#provision!`), and the push train's launcher refresh
names the file that keeps it from moving.

Not built: making minting an admitted operator step (boot mints today when an edge covers the
move, and the deploy flows rely on it), a role that dev checkouts cannot mint with, a snapshot
before the launcher first boots a new shape, and rehearsing shape changes in CI (the
`rehearsal_run` commands need a Postgres the gate does not have). Each needs the deploy and
hosting flows reviewed together, so they are their own changes.
