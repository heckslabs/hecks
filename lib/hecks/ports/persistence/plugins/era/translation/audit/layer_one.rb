require_relative "../../../../../../runtime/errors"
require_relative "../../../../../../runtime/instance"
require_relative "../../../../../../runtime/value/invariant_violation"
require_relative "../../../../../../bluebook/model_check"

module Hecks
  module Translation
    module Audit
      # Layer 1 — from the bluebook alone: every translated state must
      # pass the new era's types, value-object invariants, and lifecycle.
      # This is also where a new, stricter invariant that old records
      # violate surfaces — there is no "grandfather old records"
      # construct, and the remedy is relaxing the invariant or explicit
      # remediation, never a translation rule.
      module LayerOne
        # Hydrates every translated state as a current-era instance and records each one
        # the era's types, invariants or lifecycle refuse.
        #
        # @param violations [Array<String>] collector this method appends messages to
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param after [Hash{String => Hash}] translated state per record id, as parsed JSON
        # @return [void]
        def layer_one!(violations, aggregate, after)
          after.each do |id, state|
            symbolized = JSON.parse(JSON.generate(state), symbolize_names: true)
            instance = Runtime::Instance.new(aggregate: aggregate, id: id, state: symbolized)
            lifecycle = aggregate.lifecycle
            next unless lifecycle

            held = instance[lifecycle.field]
            # `Lifecycle#states` answers default+targets only — a state
            # legitimately declared just as a `from:` (a terminal
            # transition's source, never anyone's target) is real and
            # reachable but invisible to it. `ModelCheck.full_states`
            # is the full declared set (default, every target, and
            # every from) that `fuzzing/properties.rb`'s own replay
            # check already uses for this identical question — see its
            # comment on this same hole.
            allowed = Bluebook::ModelCheck.full_states(lifecycle)
            unless held.nil? || allowed.include?(held.to_s)
              violations << "#{aggregate.name}##{id}: #{lifecycle.field} is #{held.inspect}, " \
                            "a state this era's lifecycle never reaches"
            end
          rescue Runtime::InvariantViolation, Runtime::TypeMismatch => e
            violations << "#{aggregate.name}##{id}: #{e.message}"
          end
        end
      end
    end
  end
end
