# Keeping CI under three minutes

Read this before you add a spec that builds Rust, a CI step or job, or change a cache key or
the shard plan. `CLAUDE.md` holds the rules every session needs; this holds the detail.

## Keep CI under three minutes

CI on `main` ran in about 160s with every job run for real; by 2026-10-23 it took
10 minutes or more. Nothing was skipped wrongly: work had landed in jobs where it
runs cold. Before adding a spec or a step, check where it runs:

- **A spec that runs `cargo` goes in a Rust job that holds that crate's cache**, never
  in a Postgres io shard (`IO_PARALLEL_EXCLUDE_PATTERN` in
  `.github/workflows/ci-postgres-io-parallel.yml`). A shard has no Rust cache, so one
  `cargo build` there costs minutes. A host harness spec belongs in
  `rspec_rust_host_lineage`, and a `cargo test` of the host in `rspec_rust_host_cargo`,
  whose `target-test` build is warm.
- **`rust/src/generated` is committed; no job regenerates it.** The `generated-rust`
  action only checks the tree is in the checkout (its `domains:` input has no effect).
  `checks_codegen_drift` is the one job that sets `regenerate: "true"`, rewrites the whole
  tree and diffs it with the committed one; without that rewrite its `git diff` compares
  the tree with itself, and a stale module goes through green. After you change a bluebook
  or the generator, run `exe/hecks regeneration_run.regenerate_corpus! --confirm --wait` and
  commit what it changed; a conflict in the tree is settled by regenerating, never by
  editing. The Vocabulary rows are part of the `meta` module's IR, so changing a gate row
  moves it too. A spec that reads the whole tree is tagged `:generated_all`: the shards run
  `--tag ~generated_all`, and the drift job runs it.
- **Two jobs that share a cargo cache name must build the same thing, from the same
  directory, with the same flags.** The first job to save an entry wins, and an entry is
  never replaced under its key, so a second job whose build differs (a `--manifest-path`
  build from the repo root skips `rust/host/.cargo/config.toml`; `cargo test -p x --lib`
  resolves features differently from `cargo test --workspace`) rebuilds every dependency on
  every run. The warm job in `cache-warm.yml` must build each form its consumers build. The
  key (`.github/actions/cargo-cache`) hashes the crate's manifest, path dependencies and the
  toolchain pin; the saved target leaves out `debug/incremental` and the `rust-*` binaries.
- **Split a job that sets the run's length into matrix legs, each its own gate check**:
  the fuzz sweeps run as `shard=I/N` legs (`fuzz_<I>_of_<N>` in the Vocabulary gate rows,
  `fuzz_shards` listing the split) and still report as `checks_fuzz` and
  `checks_fuzz_sqlite`, which are red when any leg is. The cost table
  `spec/fuzzing/fuzz_runtime_baseline.log` must come from CI sweeps, not a laptop: a laptop's
  disk prices banking and deploy in other proportions than a runner's and the legs split
  worse. A file that parallel_tests cannot split (one spec file) sets a shard's length, so
  split the file.
- **The rspec and Postgres io shards are balanced per run, not from a committed baseline.** A
  `shard_plan` job (`postgres_io_shard_plan` in the Postgres workflow) runs the CiSpeed bluebook's
  `ShardPlan.Request` through `Operation.run!`: it reads the per-file timings the shard legs uploaded
  as artifacts on the newest recent successful `ci.yml` run that kept them (any branch: a push of an attested tree
  skips the shards and keeps none, so that is usually the pull-request run that tested the tree; a file the
  run never timed is priced at the median), splits the files once with the shared
  `Hecks::Tools::ShardPlanner` (longest processing time first) and publishes the plan; every leg
  reads that plan. When no timing can be read (no previous run, expired artifacts, an API error)
  the `PlanBySizeWhenTimingsUnavailable` policy plans by file size and the run does not fail. The
  plan job's summary and the `shard-plan-trace-*` artifact list each event and the policy that
  reacted. When you add io spec files run `test_suite_run.write_io_parallel_spec_list!`; a file with
  no timing is priced at the median. The specs that need `rust/parser` stay
  in `IO_PARALLEL_EXCLUDE_PATTERN`, or the Postgres shards skip them and the skip backstop
  fails; the file-list check runs only on pull requests, so a stale list shows on a PR first.
- **A fast green on `main` may be a skipped green.** A push of an attested tree skips the
  heavy jobs. `nightly-main.yml` runs all of `ci.yml` once a day with attestation ignored
  (`check-attestation` answers "not attested" for it) and opens one issue a day naming the
  failed jobs; read its latest run, not a push run, to know whether the suites pass.
- **Look at the job times after your push** (`gh run view <id> --json jobs`). A job
  that grew by a minute is the regression; say so rather than leave it.
- **Measure the right run.** The wall is `run_started_at` to `updated_at` of the attempt
  (`gh api repos/<owner>/<repo>/actions/runs/<id>/attempts/<n>`). Take attempt 1 of a run on
  a tree no earlier run had: a rerun, or a run on a tree already attested (the PR's own tree
  after a squash merge; any rerun after the pre-push hook's note lands), skips the heavy jobs
  and reads fast. A change to a cache key, to `rust/src` or to `ci-rust-io.yml` makes the next
  run cold once. `main`'s runs and the cache-warm job share the runner pool, so a busy pool
  adds queueing; a single cache download can also stall, so one slow job is not a regression
  until it repeats.
