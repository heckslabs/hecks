require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "self_consistency"
require_relative "replay/filters"
require_relative "replay/fan_out"
require_relative "replay/guard_check"
require_relative "replay/role_check"
require_relative "replay/mutation_trace"
require_relative "replay/session"

module Hecks
  module Fuzzing
    # Replays a step list in-process against a fresh boot, returning the
    # observable history as data instead of JSON on stdout.
    module Replay
      # The two classes Admissibility#enforce_givens/#enforce_lifecycle_guard raise;
      # any other DOMAIN_REFUSAL proves the guard itself did not fire.
      GUARD_REFUSAL_CLASSES = [Runtime::GivenNotMet, Runtime::LifecycleRefused].freeze

      # The boot options a replay passes through to `IsolatedBoot.call`.
      BOOT_OPTIONS = [:adapter, :database, :schema].freeze

      extend Filters
      extend FanOut

      module_function

      # Replays +steps+ against a fresh boot of +domain_path+. The oracle snapshots taken
      # inside the loop are timed relative to dispatch; do not reorder them.
      #
      # @param domain_path [String] filesystem path to the domain directory to replay
      # @param steps [Array<Hash>] the step list to replay
      # @param self_consistency [Boolean] also run SelfConsistency.check before returning
      # @param boot [Hash] `adapter:` the persistence adapter to boot the copy with (default
      #   `:memory`), `database:` the PostgresEra database name (required for `:postgres_era`)
      #   and `schema:`
      # @return [Hash] instances, events, refusals, reactions, sagas, queries, oracle traces
      def call(domain_path, steps, self_consistency: false, **boot)
        # See isolated_boot.rb's own header: resets data/ and rebinds persistence to the
        # chosen adapter, since a Postgres-bound domain's real store lives outside the
        # copied directory and can't be reached by resetting data/ alone.
        IsolatedBoot.call(domain_path, **boot_options(boot)) do |copy|
          runtime = Hecks.boot(copy, environment: nil)
          Session.new(runtime).play(steps).history(self_consistency: self_consistency)
        end
      end

      # The keywords for `IsolatedBoot.call`, with `adapter:` defaulting to `:memory`.
      #
      # @raise [ArgumentError] if `boot` holds a keyword a replay does not take
      def boot_options(boot)
        unknown = boot.keys - BOOT_OPTIONS
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" if unknown.any?

        { adapter: :memory }.merge(boot)
      end

      # Runs the block with this step's `role:`/`actor_id:` bound as the ambient
      # caller, if it declares one; a step with no `role:` dispatches bare.
      def as_step_caller(step, &)
        return yield unless step["role"]

        Hecks.as_caller(role: step["role"], actor_id: step["actor_id"], &)
      end

      # Every persisted record's state, keyed by `"Domain::Aggregate#id"`. Called once
      # per query step, not only at the end, so a property recomputing "the eligible
      # rows" reads the state as that query actually saw it, not a shared final one.
      def snapshot_instances(runtime)
        instances = {}
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.aggregates.each do |aggregate|
            runtime.registry.repository(domain_name, aggregate).all.each do |record|
              instances["#{domain_name}::#{aggregate.name}##{record.id}"] = record.state
            end
          end
        end
        instances
      end

      # The id of the record a command's args address: the aggregate's own identity, an `id`
      # arg, or the command's declared reference key; nil when none resolves.
      def identity_for(aggregate, command, args)
        reference_key = command.references.to_s.empty? ? nil : Naming.reference_key(command.references)
        Runtime::Identity.of(aggregate, args) ||
          Runtime::Identity.from(aggregate, args, :id) ||
          (reference_key && Runtime::Identity.from(aggregate, args, reference_key))
      end

      # Names the outcome class a recorded refusal row should carry: an evaluation
      # fault is `"Fault"` (matching the Rust kernel's `Refusal::Fault`), never a raw
      # Ruby exception name.
      def refusal_kind(error)
        error.is_a?(Bluebook::Expression::EvaluationError) ? "Fault" : error.class.name
      end
    end
  end
end
