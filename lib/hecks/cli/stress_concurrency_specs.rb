# frozen_string_literal: true

require "etc"
require "open3"
require "fileutils"
require_relative "stress_concurrency_specs/usage"
require_relative "stress_concurrency_specs/reporting"

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

      # The value flags and the settings they fill.
      FLAGS = { "--runs" => :runs, "--parallel" => :parallel, "--seed-start" => :seed_start }.freeze

      extend Reporting

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
        settings = { parallel: Etc.nprocessors }
        status = parse!(argv, settings, out)
        return status if status

        return 64 if missing_defaults?(settings)

        results = run_all(root, settings, out)
        report(root, results, out)
      end

      # Warns when the launcher did not supply `--runs` and `--seed-start`.
      #
      # @param settings [Hash{Symbol => Integer}] the parsed flags
      # @return [Boolean] whether a default is missing
      def missing_defaults?(settings)
        missing = %i[runs seed_start].reject { |name| settings.key?(name) }
        return false if missing.empty?

        warn "missing #{missing.map { |name| "--#{name.to_s.tr("_", "-")}" }.join(", ")}: " \
             "`hecks stress_concurrency` supplies the defaults its bluebook declares (--help for usage)"
        true
      end

      # @param argv [Array<String>] the arguments; consumed
      # @param settings [Hash{Symbol => Integer}] filled in from the flags
      # @param out [IO] where the usage goes for `--help`
      # @return [Integer, nil] an exit status to stop with, or nil to go on
      def parse!(argv, settings, out)
        until argv.empty?
          arg = argv.shift
          return stop_for(arg, out) unless FLAGS.key?(arg)

          settings[FLAGS[arg]] = Integer(argv.shift)
        end
        nil
      end

      # @param arg [String] a command-line word that is not a value flag
      # @param out [IO] where the usage goes for `--help`
      # @return [Integer] 0 for `--help`, 64 for an unknown argument
      def stop_for(arg, out)
        if %w[--help -h].include?(arg)
          out.puts USAGE
          return 0
        end

        warn "unrecognized argument: #{arg.inspect} (--help for usage)"
        64
      end

      # @param root [String] the checkout the specs run in
      # @param settings [Hash{Symbol => Integer}] `runs`, `parallel` and `seed_start`
      # @param out [IO] where the progress goes
      # @return [Array<Hash>] one result per run
      def run_all(root, settings, out)
        seeds = (settings[:seed_start]...(settings[:seed_start] + settings[:runs])).to_a
        announce(settings, out)

        results = run_parallel_group(root, seeds, settings[:parallel], out) + run_serial_group(root, seeds, out)
        out.puts
        out.puts
        results
      end

      # @param root [String] the checkout the specs run in
      # @param seeds [Array<Integer>] the seeds to run
      # @param parallel [Integer] how many runs go at the same time
      # @param out [IO] where the progress goes
      # @return [Array<Hash>] one result per seed
      def run_parallel_group(root, seeds, parallel, out)
        seeds.each_slice(parallel).flat_map do |batch|
          progress(run_batch(root, PARALLEL_SAFE_SPEC_FILES, batch, label: "parallel-safe"), out)
        end
      end

      # @param root [String] the checkout the specs run in
      # @param seeds [Array<Integer>] the seeds to run, one process at a time
      # @param out [IO] where the progress goes
      # @return [Array<Hash>] one result per seed
      def run_serial_group(root, seeds, out)
        seeds.flat_map do |seed|
          progress([run_once(root, SERIAL_ONLY_SPEC_FILES, seed, label: "postgres (serial)")], out)
        end
      end

      # Says what is about to run.
      #
      # @param settings [Hash{Symbol => Integer}] `runs`, `parallel` and `seed_start`
      # @param out [IO] where the announcement goes
      # @return [void]
      def announce(settings, out)
        runs = settings[:runs]
        seed_start = settings[:seed_start]
        out.puts "Stress-running the parallel-safe group #{runs} time(s) (#{settings[:parallel]} at a time), " \
                 "seeds #{seed_start}..#{seed_start + runs - 1}:"
        PARALLEL_SAFE_SPEC_FILES.each { |f| out.puts "  - #{f}" }
        out.puts "...and the Postgres-backed group #{runs} time(s), ONE PROCESS AT A TIME:"
        SERIAL_ONLY_SPEC_FILES.each { |f| out.puts "  - #{f}" }
        out.puts
      end

      # Prints one dot per passing run and an F per failing one.
      #
      # @param results [Array<Hash>] the runs just finished
      # @param out [IO] where the progress goes
      # @return [Array<Hash>] `results`
      def progress(results, out)
        results.each { |result| out.print result[:success] ? "." : "F" }
        out.flush
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
          reproduce: "CI=true bundle exec rspec #{spec_files.join(" ")} --seed #{seed}" }
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
    end
  end
end
