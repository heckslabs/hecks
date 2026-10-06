require_relative "../../../../../../runtime/errors"
require_relative "../../../../../../runtime/instance"
require_relative "../../../../../../runtime/value/invariant_violation"
require_relative "../../../../../../bluebook/model_check"

module Hecks
  module Translation
    module Audit
      # Layer 1: every translated state must pass the new era's types, invariants and lifecycle.
      # Old records that violate a stricter invariant surface here; no translation rule fixes them.
      module LayerOne
        # Hydrates every translated state as a current-era instance and records each one
        # the era's types, invariants or lifecycle refuse.
        #
        # @param violations [Array<String>] collector this method appends messages to
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param after [Hash{String => Hash}] translated state per record id, as parsed JSON
        # @return [void]
        def layer_one!(violations, aggregate, after)
          after.each { |id, state| check_record!(violations, aggregate, id, state) }
        end

        private

        def check_record!(violations, aggregate, id, state)
          symbolized = JSON.parse(JSON.generate(state), symbolize_names: true)
          instance = Runtime::Instance.new(aggregate: aggregate, id: id, state: symbolized)
          lifecycle = aggregate.lifecycle
          return unless lifecycle

          check_lifecycle_state!(violations, aggregate, id, lifecycle, instance[lifecycle.field])
        rescue Runtime::InvariantViolation, Runtime::TypeMismatch => e
          violations << "#{aggregate.name}##{id}: #{e.message}"
        end

        def check_lifecycle_state!(violations, aggregate, id, lifecycle, held)
          # `Lifecycle#states` omits states declared only as a `from:`; `full_states` has them.
          allowed = Bluebook::ModelCheck.full_states(lifecycle)
          return if held.nil? || allowed.include?(held.to_s)

          violations << "#{aggregate.name}##{id}: #{lifecycle.field} is #{held.inspect}, " \
                        "a state this era's lifecycle never reaches"
        end
      end
    end
  end
end
