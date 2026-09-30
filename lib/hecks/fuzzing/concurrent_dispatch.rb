require "fileutils"
require "tmpdir"
require "tempfile"
require "json"
require_relative "isolated_boot"
require_relative "../naming"
require_relative "../quality_control/cli/child"

module Hecks
  module Fuzzing
    # Races a generated sequence's own command step across two real OS processes
    # against a live domain, checking the outcome against a sequential oracle to catch a broken
    # cross-process lock.
    module ConcurrentDispatch
      module_function

      COMMAND_STEP = ->(step) { step["verb"] && !step["query"] && !step["dry_run"] }

      # `database:` is the shared, never-dropped scratch database; `race_schema:`
      # and `reference_schema:` are this call's own disposable schemas.
      def check(domain_path, steps, database:, race_schema:, reference_schema:)
        normalized = steps.map { |step| step.transform_keys(&:to_s) }
        lockable, probe_errors = lockable_verbs(domain_path, normalized, database: database, schema: reference_schema)
        race_index = pick_race_index(normalized, lockable)
        unless race_index
          # `[]` must mean "nothing to race" (a query/dry-run-only sequence,
          # a legitimate clean result), never a probe failure for every verb —
          # see lockable_verbs, which distinguishes the two below.
          return [] if probe_errors.empty?

          return [{ field:  "concurrency_unraceable",
                    detail: "no command step could be raced because the cross-process-lock probe failed: " \
                            "#{probe_errors.uniq.join('; ')}" }]
        end

        setup_steps = normalized[0...race_index]
        race_step   = normalized[race_index]

        reference  = reference_outcomes(domain_path, setup_steps, race_step, database: database, schema: reference_schema)
        concurrent = concurrent_outcomes(domain_path, setup_steps, race_step, database: database, schema: race_schema)

        divergences_for(race_step, reference, concurrent)
      rescue StandardError => e
        [{ field: "process", detail: "#{e.class}: #{e.message}" }]
      end

      # Picks the command step closest to the middle of the sequence (best odds of
      # conflicting with itself); nil if no step is eligible after lockable_verbs filters.
      def pick_race_index(steps, lockable_verbs = nil)
        command_indices = steps.each_index.select { |i| COMMAND_STEP.call(steps[i]) }
        command_indices = command_indices.select { |i| lockable_verbs.include?(steps[i]["verb"]) } if lockable_verbs
        return nil if command_indices.empty?

        command_indices[command_indices.size / 2]
      end

      # Filters to verbs whose aggregate resolves to a `:cross_process_lock`-declaring
      # adapter — a Memory-backed aggregate (e.g. one only `uses_framework`s) can never
      # agree with the sequential oracle across two processes, a guaranteed false positive.
      def lockable_verbs(domain_path, steps, database:, schema:)
        verbs = steps.select { |step| COMMAND_STEP.call(step) }.map { |step| step["verb"] }.uniq
        lockable = []
        probe_errors = []
        boot_preserving_schema(domain_path, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy)
          verbs.each do |verb|
            lockable << verb if verb_cross_process_lockable?(runtime, verb, probe_errors)
          end
        end
        [lockable, probe_errors]
      end

      # false (with a recorded probe error) for a verb this boot cannot resolve, not a guess.
      def verb_cross_process_lockable?(runtime, verb, probe_errors = [])
        domain, aggregate_name, = Naming.split_verb(verb)
        return false unless domain && aggregate_name

        aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        return false unless aggregate

        repository = runtime.registry.repository(domain, aggregate)
        repository.capabilities.include?(:cross_process_lock)
      rescue StandardError => e
        # Still `false` — a verb this boot cannot resolve is not raced on a
        # guess — but never silent: `check` needs to tell "nothing here
        # declares a cross-process lock" from "asking broke".
        probe_errors << "#{verb}: #{e.class}: #{e.message}"
        false
      end

      def divergences_for(race_step, reference, concurrent)
        crashes = (reference + concurrent).select { |outcome| outcome.start_with?("crashed:") }.uniq
        return crashes.map { |c| { field: "concurrency_crash", verb: race_step["verb"], detail: c } } if crashes.any?

        return [] if reference.sort == concurrent.sort

        [{ field: "concurrency_race", verb: race_step["verb"], reference: reference, concurrent: concurrent,
           detail: "two concurrent cross-process dispatches of #{race_step['verb']} settled as #{concurrent.sort} " \
                   "where the identical pair, dispatched sequentially with no contention, settled as " \
                   "#{reference.sort} — the cross-process write lock did not correctly serialize this write" }]
      end

      # The oracle: one boot, one process, setup then the race step twice in a row.
      # Nothing else touches this schema, so the outcome is correct by construction.
      def reference_outcomes(domain_path, setup_steps, race_step, database:, schema:)
        outcomes = []
        IsolatedBoot.call(domain_path, adapter: :postgres_era, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy)
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
          dispatch_all!(Hecks.boot(copy), setup_steps)
        end

        root = File.expand_path("../../..", __dir__)
        args_json = JSON.generate(race_step["args"] || {})
        logs = Array.new(2) { Tempfile.new(["qa-concurrency-racer-", ".log"]) }
        logs.each(&:unlink)

        pids = logs.map do |log|
          racer = Hecks::QualityControlCli::Child.argv(root, "qa_concurrency_racer", domain_path, database, schema,
                                                       race_step["verb"], args_json)
          Process.spawn(*racer, out: log, err: log, chdir: root)
        end

        pids.each { |pid| Process.wait(pid) }
        logs.map do |log|
          log.rewind
          output = log.read
          log.close
          output.strip.empty? ? "crashed:no output from the concurrency racer" : output.lines.last.chomp
        end
      end

      # Never raises: a declared domain refusal maps to "refused"; anything else
      # escaping maps to "crashed:<class>: <message>" instead of killing a racer.
      def dispatch_one(runtime, step)
        args = (step["args"] || {}).transform_keys(&:to_sym)
        runtime.dispatch_flat(step["verb"], args)
        "succeeded"
      rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError
        "refused"
      rescue StandardError => e
        "crashed:#{e.class}: #{e.message}"
      end

      # Setup tolerates an ordinary refusal but never a crash — an unexpected
      # exception here leaves the schema in an unknown state, not safe to race against.
      def dispatch_all!(runtime, steps)
        steps.each do |step|
          outcome = dispatch_one(runtime, step)
          raise "setup step #{step['verb']} #{outcome}" if outcome.start_with?("crashed:")
        end
      end

      # Same copy-and-rebind IsolatedBoot.call(..., adapter: :postgres_era) does,
      # minus the schema wipe — this schema already holds what setup wrote, and
      # the race must run against that, not a blank one.
      def boot_preserving_schema(domain_path, database:, schema:)
        Dir.mktmpdir("hecks-concurrency") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          IsolatedBoot.copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          IsolatedBoot.rewrite_bindings!(copy, "PostgresEra")
          write_postgres_era_world!(copy, database: database, schema: schema)
          yield copy
        end
      end

      # One world file per directory, merging every hecksagon name found there,
      # replacing any other `.world` file the copy already carries.
      def write_postgres_era_world!(copy, database:, schema:)
        worlds_by_dir = Hash.new { |h, k| h[k] = [] }
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
          names = File.read(hecksagon_path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten
          worlds_by_dir[File.dirname(hecksagon_path)].concat(names)
        end
        worlds_by_dir.each do |dir, names|
          names = names.uniq
          next if names.empty?

          world_path = File.join(dir, "hecks_fuzz_postgres_era.world")
          File.write(world_path, names.map do |name|
            <<~WORLD
              Hecks.world "#{name}" do
                persisted_by("PostgresEra") do
                  database "#{database}"
                  schema "#{schema}"
                  allow_superuser true
                end
              end
            WORLD
          end.join("\n"))
        end

        Dir.glob(File.join(copy, "**", "*.world")).each do |path|
          File.delete(path) unless File.basename(path) == "hecks_fuzz_postgres_era.world"
        end
      end
    end
  end
end
