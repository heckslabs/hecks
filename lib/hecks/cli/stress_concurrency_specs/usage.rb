module Hecks
  module CLI
    module StressConcurrencySpecs
      USAGE = <<~TEXT.freeze
        Usage: hecks stress_concurrency [--runs N] [--parallel N] [--seed-start N]

          --runs N        How many times to run EACH group below. Each run uses
                           a different --seed (seed-start + run index).
          --parallel N    How many parallel-safe-group runs to have going as
                           separate OS processes AT THE SAME TIME (default: this
                           machine's own core count, via Etc.nprocessors) — real
                           concurrent scheduler/CPU contention, not just varied
                           seeds one after another. The Postgres-backed group
                           always runs one process at a time regardless of this
                           flag.
          --seed-start N  First --seed value; runs use seed_start,
                           seed_start + 1, ... seed_start + runs - 1.

        `hecks stress_concurrency` fills --runs and --seed-start from the defaults its
        bluebook declares (`hecks stress_concurrency --help` shows them).

        Exits 0 if every run's every example passed, 1 if anything failed -
        failing runs' full output is saved under tmp/stress-failures/
        for a real repro (same seed, same command, just add CI=true).
      TEXT
    end
  end
end
