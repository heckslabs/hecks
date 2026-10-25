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

**Derived (retire the variable):**
`HECKS_RUST_DIR`, `CARGO_TARGET_DIR` (from the copy's root and the shared cache, as
`TargetDir` already does); `HECKS_LIB` (the Gemfile or vendored hecks says which);
`HECKS_TRAIN_HOME` (the launcher lives at `~/.claude/hecks-train`);
`EMBRYONAUT_BLUEBOOKS_SRC` (a sibling checkout, or the registry URL in project config);
`HECKS_CACHE_DIR` and the other cache locations (from the shared cache root);
`HECKS_IR_PATH`, `HECKS_WASM_PATH` (the host reads the build output beside it);
`HECKS_STOREHOUSE_ROOT` (the checkout root); `HECKS_QA_SETTINGS_PATH` (the default path
exists); `QA_REPO_DIR` (the working directory); `HECKS_PARSE_BIN` (found beside the
install; the editor extension passes its setting as an argument);
`HECKS_VALIDATE_HARNESS` (a harness path, with a built fallback).

**Declared in the world (retire the variable):**
`HECKS_DATABASE` (the copy's `environments/local.world`, else a database named for the
domain), `HECKS_SCHEMA`, `HECKS_PROJECT_ENVIRONMENT`, `DATABASE_URL`, `POSTGRES_URL` and
`SHOP_DATABASE_URL` for era tooling, `HECKS_DOMAIN`, `HECKS_SERVICE_URL`, `SITE_URL`,
`DOMAIN_NAME`.

**Declared as settings (the world or the hecksagon, with defaults):**
host wiring (`HECKS_SESSION_COOKIE`, `HECKS_ROLE_ENFORCEMENT`, `HECKS_SERVE_MODE`),
analytics hosts and ids, the OAuth client ids and redirect URIs, smoke settings
(`SMOKE_CONFIG`), `SETTLE_TIMEOUT_SECS`, `HECKS_CONTRACT_WAIT_SECONDS`,
`HECKS_CONTRACT_PAYMENTS`. Which adapter and binary to use (`HECKS_COMPOSER_AGENT`,
`HECKS_JEV`, `QA_MINER_AGENT`) belongs in the hecksagon, not the world. `HECKS_SCAFFOLD`
is a flag on the era command.

**Arguments of the command that runs (retire the variable):**
- `GOLDEN=rewrite`, `EXISTING_TAG`, `HECKS_FUZZ_SCHEMA`: a hecks command already hands
  each to its child process, so only the hand-off remains.
- `SEEDS`, `STEPS`: `build.fuzz_conformance` already takes `seeds` and `steps`; the
  variable fallback is removed.
- `HECKS_WASM_PROFILE`: the `profile` argument of `build.build_wasm!` (built on this branch).
- `HECKS_PREBUILT=off`: the `prebuilt` argument of `build.build_host!` (built on this branch).
- `HECKS_ENVIRONMENT`: the world declares the default per command, as `MEMORY_COMMANDS`
  and `hecks.world` already do for the launcher; `run_spec_example!` needs the argument.
- `HECKS_CLOUDFRONT_TEST`: a tag filter on the spec-run command.
- `PROPERTY_SEEDS`: a seeds argument on the spec-run command, which sets it for the child.
- `CI`, `HECKS_PRE_PUSH_GATE`: both mean "run the specs strictly" (`spec_helper.rb`,
  `postgres_probe.rb`, `ci_skip_backstop.rb`, `generated_rust.rb`) and nothing in `lib/`
  reads either. One `strict` argument on `gate_run.gate!` and the spec runs replaces them.
  The pre-push hook chooses the gate's stage from the variable, so the hook calls the
  command with the stage instead. A workflow passes `strict` instead of relying on the
  provider's `CI`.
- `HECKS_PUSH_TRAIN=off`: not running `push_train.board!`, or an argument on it.

**Retired outright:**
- `HECKS_EVAL=string` forced the text path of rule evaluation. No spec or workflow set it
  and it compared nothing; the switch and its branch are removed.
- `HECKS_SYNTAX_BOOT_CACHE=off`, `HECKS_VERDICT_CACHE=off`, `HECKS_NO_USAGE_CACHE`: each
  turned a disk cache off to rule it out. `test_suite_run.clear_caches!` empties all three
  caches instead. The variables still work and warn once; they are removed a release
  later.

**Kept (the whole remaining list):**
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

1. Done on this branch: `HECKS_EVAL` and the `SEEDS`/`STEPS` fallback removed; the cache
   switches warn; `test_suite_run.clear_caches!` empties the syntax-boot, verdict and usage
   caches.
2. Derived variables: no schema change.
3. Arguments: `profile` and `prebuilt` are built, and `run_spec_example!` takes `strict`,
   `seeds` and `environment`, which set `CI`, `PROPERTY_SEEDS` and `HECKS_ENVIRONMENT` for
   that run only. Still to build: `strict` on `gate_run.gate!` (with the pre-push hook
   choosing its stage by command), a tag filter for `HECKS_CLOUDFRONT_TEST`, and the
   `board!` argument for `HECKS_PUSH_TRAIN=off`.
4. World-declared variables: `environments/*.world` becomes the one place a copy says
   what it connects to.
5. Declared settings: needs a decision on where in the hecksagon they are written.

## Consequences

- A fresh copy runs with no shell setup.
- A variable that is still read but not listed above is a finding the gate can report.
- `HECKS_DATABASE` set globally in a shell, which once let dev checkouts boot newer
  bluebooks against the records database, stops being possible by construction.
