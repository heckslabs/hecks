# frozen_string_literal: true

require "etc"
require "open3"
require "fileutils"

module Hecks
  module CLI
    # The command behind `hecks stress_concurrency`: reruns the thread-safety specs under many
    # seeds, several OS processes at a time. A clean run shows only "not in this many tries", never
    # "impossible".
    #
    # CI can call it gated to pull requests that touch `lib/hecks/runtime/**`, as its own job so the
    # repetition does not tax the single-pass suite; a GitHub Actions matrix leg can also run
    # `--runs 1 --parallel 1 --seed-start N`.
    module StressConcurrencySpecs
      # The specs that prove a shared-state race is closed, listed by hand: a glob would also
      # catch specs that only use threads for fixture setup. In-process specs share no external
      # resource, so concurrent copies are safe.
      PARALLEL_SAFE_SPEC_FILES = [
        "spec/runtime/dispatcher_spec.rb",
        "spec/adapters/driven/in_process_concurrent_dispatch_spec.rb"
      ].freeze

      # The Postgres spec drops and recreates one fixed database, so overlapping copies would fail
      # with `PG::ConnectionBad`; it runs one process at a time.
      SERIAL_ONLY_SPEC_FILES = [
        "spec/adapters/driven/postgres_concurrent_dispatch_spec.rb"
      ].freeze

      USAGE = <<~TEXT
        Usage: hecks stress_concurrency [--runs N] [--parallel N] [--seed-start N]

          --runs N        How many times to run EACH group below (default 30).
                           Each run uses a different --seed (seed-start + run
                           index).
          --parallel N    How many parallel-safe-group runs to have going as
                           separate OS processes AT THE SAME TIME (default: this
                           machine's own core count, via Etc.nprocessors) — real
                           concurrent scheduler/CPU contention, not just varied
                           seeds one after another. The Postgres-backed group
                           always runs one process at a time regardless of this
                           flag.
          --seed-start N  First --seed value (default 1); runs use seed_start,
                           seed_start + 1, ... seed_start + runs - 1.

        Exits 0 if every run's every example passed, 1 if anything failed -
        failing runs' full output is saved under tmp/stress-failures/
        for a real repro (same seed, same command, just add CI=true).
      TEXT

      module_function

      # Runs both groups under every seed and reports.
      #
      # @param argv [Array<String>] `--runs N`, `--parallel N`, `--seed-start N`, `--help`
      # @param root [String] the checkout the specs run in
      # @param out [IO] where the progress and verdict go
      # @return [Integer] 0 when every run passed (or for `--help`), 1 on flakiness, 64 for an
      #   unknown argument
      def call(argv, root:, out: $stdout)
        argv = argv.dup
        settings = { runs: 30, parallel: Etc.nprocessors, seed_start: 1 }
        status = parse!(argv, settings, out)
        return status if status

        results = run_all(root, settings, out)
        report(root, results, out)
      end

      # @param argv [Array<String>] the arguments; consumed
      # @param settings [Hash{Symbol => Integer}] filled in from the flags
      # @param out [IO] where the usage goes for `--help`
      # @return [Integer, nil] an exit status to stop with, or nil to go on
      def parse!(argv, settings, out)
        flags = { "--runs" => :runs, "--parallel" => :parallel, "--seed-start" => :seed_start }
        until argv.empty?
          arg = argv.shift
          if flags.key?(arg)
            settings[flags[arg]] = Integer(argv.shift)
          elsif %w[--help -h].include?(arg)
            out.puts USAGE
            return 0
          else
            warn "unrecognized argument: #{arg.inspect} (--help for usage)"
            return 64
          end
        end
        nil
      end

      # @param root [String] the checkout the specs run in
      # @param settings [Hash{Symbol => Integer}] `runs`, `parallel` and `seed_start`
      # @param out [IO] where the progress goes
      # @return [Array<Hash>] one result per run
      def run_all(root, settings, out)
        runs = settings[:runs]
        seed_start = settings[:seed_start]
        seeds = (seed_start...(seed_start + runs)).to_a
        out.puts "Stress-running the parallel-safe group #{runs} time(s) (#{settings[:parallel]} at a time), " \
                 "seeds #{seed_start}..#{seed_start + runs - 1}:"
        PARALLEL_SAFE_SPEC_FILES.each { |f| out.puts "  - #{f}" }
        out.puts "...and the Postgres-backed group #{runs} time(s), ONE PROCESS AT A TIME:"
        SERIAL_ONLY_SPEC_FILES.each { |f| out.puts "  - #{f}" }
        out.puts

        results = []
        seeds.each_slice(settings[:parallel]) do |batch|
          batch_results = run_batch(root, PARALLEL_SAFE_SPEC_FILES, batch, label: "parallel-safe")
          results.concat(batch_results)
          batch_results.each { |result| out.print result[:success] ? "." : "F" }
          out.flush
        end
        seeds.each do |seed|
          result = run_once(root, SERIAL_ONLY_SPEC_FILES, seed, label: "postgres (serial)")
          results << result
          out.print result[:success] ? "." : "F"
          out.flush
        end
        out.puts
        out.puts
        results
      end

      # `CI=true` un-excludes the `io: true` Postgres spec, which self-skips without a reachable
      # server.
      #
      # @param root [String] the checkout to run in
      # @param spec_files [Array<String>] the spec files
      # @param seed [Integer] the `--seed` value
      # @param label [String] which group this run belongs to
      # @return [Hash] `label`, `seed`, `success`, `output` and how to `reproduce` it
      def run_once(root, spec_files, seed, label:)
        command = ["bundle", "exec", "rspec", *spec_files, "--seed", seed.to_s, "--format", "progress"]
        stdout, status = Open3.capture2e({ "CI" => "true" }, *command, chdir: root)
        { label: label, seed: seed, success: status.success?, output: stdout,
          reproduce: "CI=true bundle exec rspec #{spec_files.join(' ')} --seed #{seed}" }
      end

      # One thread per child process: `Open3.capture2e` already spawns a real process per call.
      #
      # @param root [String] the checkout to run in
      # @param spec_files [Array<String>] the spec files
      # @param seeds [Array<Integer>] the seeds to run at the same time
      # @param label [String] which group these runs belong to
      # @return [Array<Hash>] one result per seed
      def run_batch(root, spec_files, seeds, label:)
        seeds.map { |seed| Thread.new { run_once(root, spec_files, seed, label: label) } }.map(&:value)
      end

      # @param root [String] the checkout; failing runs' output is saved under its `tmp/`
      # @param results [Array<Hash>] every run's result
      # @param out [IO] where the verdict goes
      # @return [Integer] 0 when every run passed, else 1
      def report(root, results, out)
        failures = results.reject { |r| r[:success] }
        if failures.empty?
          out.puts "CLEAN — #{results.size}/#{results.size} runs passed. " \
                   "No new flakiness beyond a single ordinary `rspec` run found in this many tries."
          return 0
        end

        dir = File.join(root, "tmp/stress-failures")
        FileUtils.mkdir_p(dir)
        out.puts "FOUND FLAKINESS — #{failures.size}/#{results.size} runs failed:"
        failures.each do |failure|
          path = File.join(dir, "#{failure[:label].tr(' ', '_').gsub(/[()]/, '')}-seed#{failure[:seed]}.log")
          File.write(path, failure[:output])
          out.puts "  [#{failure[:label]}] seed #{failure[:seed]} — output saved to #{path.sub("#{root}/", '')}"
          out.puts "    reproduce: #{failure[:reproduce]}"
        end
        out.puts
        1
      end
    end
  end
end
