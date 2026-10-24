require_relative "isolated_boot"
require_relative "replay"
require_relative "projection_agreement/binding"
require_relative "projection_agreement/comparison"

module Hecks
  module Fuzzing
    # Whether a projection answers a rooted read model the way the in-process loop answers it
    # from the authoritative records (ADR 0121): the `client_native_read_model` agreement.
    module ProjectionAgreement
      # The name a finding is reported under, beside the standard battery's.
      PROPERTY = :projected_read_models_agree_with_loop

      # Each fuzz adapter that has a projection, and the projection adapter it checks.
      ADAPTERS = { sqlite: "SqliteProjection", postgres: "PostgresProjection" }.freeze

      module_function

      # Boots a copy of the domain on Memory with every chapter `projected_by` the projection
      # `projection` names, replays the steps, catches every projection up, and compares the
      # two answers to every rooted read model for every record its reference can name.
      #
      # @param domain_path [String] the domain directory
      # @param steps [Array<Hash>] the sequence to replay
      # @param projection [Symbol] `:sqlite` (`SqliteProjection`) or `:postgres`
      #   (`PostgresProjection`, needing a reachable local Postgres)
      # @param scratch [Hash] `database:` and `schema:` of the Postgres projection; default the
      #   fuzz database and a schema of its own beside the process's scratch schema
      # @return [Array<String>] one message per disagreement; empty when every answer agrees
      # @raise [ArgumentError] if `projection` is not `:sqlite` or `:postgres`
      def check(domain_path, steps, projection: :sqlite, **scratch)
        run(domain_path, steps, projection: projection, **scratch).offenders
      end

      # The same comparison as `check`, answering how many asks it compared beside what
      # disagreed, so a caller can tell an agreement from a run with nothing to compare.
      #
      # @param (see #check)
      # @return [Comparison::Outcome] `offenders` and `compared`, the asks answered both ways
      # @raise (see #check)
      def run(domain_path, steps, projection: :sqlite, **scratch)
        IsolatedBoot.call(domain_path, adapter: :memory) do |copy|
          Binding.bind!(copy, projection, **scratch)
          runtime = Hecks.boot(copy, environment: nil)
          Replay::Session.new(runtime).play(steps)
          Comparison.new(runtime.registry).outcome
        end
      end

      # Whether a fuzz sweep on `adapter` runs this check.
      #
      # @param adapter [Symbol] the sweep's persistence adapter
      # @return [Boolean] true for `:sqlite` and `:postgres`
      def checks?(adapter) = ADAPTERS.key?(adapter)

      # The check as a sweep reports a property: true, or the disagreements joined.
      #
      # @param domain_path [String] the domain directory
      # @param steps [Array<Hash>] the sequence to replay
      # @param adapter [Symbol] the sweep's persistence adapter, `:sqlite` or `:postgres`
      # @return [true, String] true when every answer agrees, else each disagreement
      def property(domain_path, steps, adapter)
        offenders = check(domain_path, steps, projection: adapter)
        offenders.empty? || offenders.join("; ")
      end
    end
  end
end
