require "json"
require "tempfile"
require_relative "../isolated_boot"
require_relative "../../quality_control/cli/child"

module Hecks
  module Fuzzing
    module ConcurrentDispatch
      # The oracle run and the two-process race that `ConcurrentDispatch.check` compares.
      module Racing
        # The oracle: one boot, one process, setup then the race step twice in a row.
        # Nothing else touches this schema, so the outcome is correct by construction.
        def reference_outcomes(domain_path, setup_steps, race_step, database:, schema:)
          outcomes = []
          IsolatedBoot.call(domain_path, adapter: :postgres_era, database: database, schema: schema) do |copy|
            runtime = Hecks.boot(copy, environment: nil)
            dispatch_all!(runtime, setup_steps)
            outcomes << dispatch_one(runtime, race_step)
            outcomes << dispatch_one(runtime, race_step)
          end
          outcomes
        end

        # Setup replays once, sequentially, before either racer starts, against the
        # already-wiped schema. Real OS processes, not threads, race it —
        # Runtime::AggregateLock's in-process registry would serialize threads
        # regardless of the lock fix. Process.spawn, not Process.fork — forking
        # duplicates open file descriptors, including this process's own live
        # Postgres connection, which corrupted it when tried here.
        def concurrent_outcomes(domain_path, setup_steps, race_step, database:, schema:)
          IsolatedBoot.call(domain_path, adapter: :postgres_era, database: database, schema: schema) do |copy|
            dispatch_all!(Hecks.boot(copy, environment: nil), setup_steps)
          end

          logs = Array.new(2) { Tempfile.new(["qa-concurrency-racer-", ".log"]) }
          logs.each(&:unlink)

          pids = spawn_racers(logs, domain_path, race_step, database, schema)
          pids.each { |pid| Process.wait(pid) }
          logs.map { |log| racer_outcome(log) }
        end

        # Starts one racer process per log, each writing its outcome line to its own log.
        def spawn_racers(logs, domain_path, race_step, database, schema)
          root = File.expand_path("../../../..", __dir__)
          args_json = JSON.generate(race_step["args"] || {})
          logs.map do |log|
            racer = Hecks::QualityControlCli::Child.argv(root, "qa_concurrency_racer", domain_path, database, schema,
                                                         race_step["verb"], args_json)
            Process.spawn(*racer, out: log, err: log, chdir: root)
          end
        end

        # The last line a racer wrote, or a crash outcome when it wrote nothing.
        def racer_outcome(log)
          log.rewind
          output = log.read
          log.close
          output.strip.empty? ? "crashed:no output from the concurrency racer" : output.lines.last.chomp
        end
      end
    end
  end
end
