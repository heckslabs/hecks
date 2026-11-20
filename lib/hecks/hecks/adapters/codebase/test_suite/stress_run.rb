# frozen_string_literal: true

require "etc"
require "open3"
require_relative "../../console_capture"
require_relative "stress_run/verdict"

module Hecks
  module Adapters
    module Codebase
      module TestSuite
        # Reruns the thread-safety specs under many seeds, several OS processes at a time, for
        # `TestSuiteRun.StressConcurrency`. A clean run shows only "not in this many tries", never
        # "impossible".
        module StressRun
          # The specs that prove a shared-state race is closed, listed by hand: a glob would also
          # catch specs that only use threads for fixture setup. In-process specs share no external
          # resource, so concurrent copies are safe.
          PARALLEL_SAFE_SPEC_FILES = [
            "spec/runtime/dispatcher_spec.rb",
            "spec/adapters/driven/in_process_concurrent_dispatch_spec.rb"
          ].freeze

          # The Postgres spec drops and recreates one fixed database, so overlapping copies would
          # fail with `PG::ConnectionBad`; it runs one process at a time.
          SERIAL_ONLY_SPEC_FILES = [
            "spec/adapters/driven/postgres_concurrent_dispatch_spec.rb"
          ].freeze

          module_function

          # Runs both groups under every seed.
          #
          # @param root [String] the checkout the specs run in
          # @param runs [Integer] how many times each group runs, one seed each
          # @param seed_start [Integer] the first seed
          # @param parallel [Integer] how many parallel-safe runs go at the same time
          # @return [String] what ran and the clean verdict
          # @raise [ConsoleCapture::Failure] naming each failing run's saved log, on flakiness
          def call(root:, runs:, seed_start:, parallel: Etc.nprocessors)
            seeds = (seed_start...(seed_start + runs)).to_a
            results = parallel_group(root, seeds, parallel) + serial_group(root, seeds)
            Verdict.new(root, results).text(announcement(seeds, parallel))
          end

          # @param seeds [Array<Integer>] the seeds run
          # @param parallel [Integer] how many runs went at the same time
          # @return [String] what was run
          def announcement(seeds, parallel)
            lines = ["Stress-ran the parallel-safe group #{seeds.size} time(s) (#{parallel} at a time), " \
                     "seeds #{seeds.first}..#{seeds.last}:"]
            lines.concat(PARALLEL_SAFE_SPEC_FILES.map { |file| "  - #{file}" })
            lines << "...and the Postgres-backed group #{seeds.size} time(s), ONE PROCESS AT A TIME:"
            lines.concat(SERIAL_ONLY_SPEC_FILES.map { |file| "  - #{file}" }).join("\n")
          end

          # @param root [String] the checkout the specs run in
          # @param seeds [Array<Integer>] the seeds to run
          # @param parallel [Integer] how many runs go at the same time
          # @return [Array<Hash>] one result per seed
          def parallel_group(root, seeds, parallel)
            seeds.each_slice(parallel).flat_map do |batch|
              batch.map { |seed| Thread.new { run_once(root, PARALLEL_SAFE_SPEC_FILES, seed, "parallel-safe") } }.map(&:value)
            end
          end

          # @param root [String] the checkout the specs run in
          # @param seeds [Array<Integer>] the seeds to run, one process at a time
          # @return [Array<Hash>] one result per seed
          def serial_group(root, seeds)
            seeds.map { |seed| run_once(root, SERIAL_ONLY_SPEC_FILES, seed, "postgres (serial)") }
          end

          # `CI=true` un-excludes the `io: true` Postgres spec, which self-skips without a reachable
          # server.
          #
          # @param root [String] the checkout to run in
          # @param spec_files [Array<String>] the spec files
          # @param seed [Integer] the `--seed` value
          # @param label [String] which group this run belongs to
          # @return [Hash] `label`, `seed`, `success`, `output` and how to `reproduce` it
          def run_once(root, spec_files, seed, label)
            command = ["bundle", "exec", "rspec", *spec_files, "--seed", seed.to_s, "--format", "progress"]
            stdout, status = Open3.capture2e({ "CI" => "true" }, *command, chdir: root)
            { label: label, seed: seed, success: status.success?, output: stdout,
              reproduce: "CI=true bundle exec rspec #{spec_files.join(" ")} --seed #{seed}" }
          end
        end
      end
    end
  end
end
