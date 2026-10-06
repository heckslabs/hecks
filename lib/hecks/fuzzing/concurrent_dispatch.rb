require "fileutils"
require "tmpdir"
require "tempfile"
require "json"
require_relative "isolated_boot"
require_relative "../naming"
require_relative "../quality_control/cli/child"
require_relative "concurrent_dispatch/racing"
require_relative "concurrent_dispatch/world_copy"

module Hecks
  module Fuzzing
    # Races a generated sequence's own command step across two real OS processes
    # against a live domain, checking the outcome against a sequential oracle to catch a broken
    # cross-process lock.
    module ConcurrentDispatch
      extend Racing
      extend WorldCopy

      module_function

      COMMAND_STEP = ->(step) { step["verb"] && !step["query"] && !step["dry_run"] }

      # `database:` is the shared, never-dropped scratch database; `race_schema:`
      # and `reference_schema:` are this call's own disposable schemas.
      def check(domain_path, steps, database:, race_schema:, reference_schema:)
        normalized = steps.map { |step| step.transform_keys(&:to_s) }
        lockable, probe_errors = lockable_verbs(domain_path, normalized, database: database, schema: reference_schema)
        race_index = pick_race_index(normalized, lockable)
        return unraceable(probe_errors) unless race_index

        schemas = { race: race_schema, reference: reference_schema }
        race(domain_path, normalized, race_index, database: database, schemas: schemas)
      rescue StandardError => e
        [{ field: "process", detail: "#{e.class}: #{e.message}" }]
      end

      # `[]` must mean "nothing to race" (a query/dry-run-only sequence, a legitimate clean
      # result), never a probe failure for every verb — see lockable_verbs, which distinguishes
      # the two.
      def unraceable(probe_errors)
        return [] if probe_errors.empty?

        [{ field:  "concurrency_unraceable",
           detail: "no command step could be raced because the cross-process-lock probe failed: " \
                   "#{probe_errors.uniq.join("; ")}" }]
      end

      # Runs the oracle and the race over the setup that precedes `race_index`.
      def race(domain_path, steps, race_index, database:, schemas:)
        setup_steps = steps[0...race_index]
        race_step   = steps[race_index]

        reference  = reference_outcomes(domain_path, setup_steps, race_step, database: database, schema: schemas[:reference])
        concurrent = concurrent_outcomes(domain_path, setup_steps, race_step, database: database, schema: schemas[:race])

        divergences_for(race_step, reference, concurrent)
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
      # adapter — a Memory-backed aggregate (e.g. one only `attaches`s) can never
      # agree with the sequential oracle across two processes, a guaranteed false positive.
      def lockable_verbs(domain_path, steps, database:, schema:)
        verbs = steps.select { |step| COMMAND_STEP.call(step) }.map { |step| step["verb"] }.uniq
        lockable = []
        probe_errors = []
        boot_preserving_schema(domain_path, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy, environment: nil)
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
           detail: "two concurrent cross-process dispatches of #{race_step["verb"]} settled as #{concurrent.sort} " \
                   "where the identical pair, dispatched sequentially with no contention, settled as " \
                   "#{reference.sort} — the cross-process write lock did not correctly serialize this write" }]
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
          raise "setup step #{step["verb"]} #{outcome}" if outcome.start_with?("crashed:")
        end
      end
    end
  end
end
