require_relative "../../../../../../runtime/errors"
require_relative "../../../../../../runtime/instance"
require_relative "../../../../../../runtime/value/invariant_violation"
require_relative "../../../../../../bluebook/model_check"

module Hecks
  module Translation
    module Audit
      # Layer 1 — from the bluebook alone: every translated state must
      # pass the new era's types, value-object invariants, and lifecycle.
      # This is also where a NEW, stricter invariant that old records
      # violate surfaces — there is no "grandfather old records"
      # construct, and the remedy is relaxing the invariant or explicit
      # remediation, never a translation rule.
      module LayerOne
        def layer_one!(violations, aggregate, after)
          after.each do |id, state|
            begin
              symbolized = JSON.parse(JSON.generate(state), symbolize_names: true)
              instance = Runtime::Instance.new(aggregate: aggregate, id: id, state: symbolized)
              lifecycle = aggregate.lifecycle
              next unless lifecycle

              held = instance[lifecycle.field]
              # `Lifecycle#states` answers default+targets only — a state
              # legitimately declared just as a `from:` (a terminal
              # transition's source, never anyone's target) is real and
              # reachable but invisible to it. `ModelCheck.full_states`
              # is the full declared set (default, every target, AND
              # every from) that `fuzzing/properties.rb`'s own replay
              # check already uses for this identical question — see its
              # comment on this same hole.
              allowed = Bluebook::ModelCheck.full_states(lifecycle)
              unless held.nil? || allowed.include?(held.to_s)
                violations << "#{aggregate.name}##{id}: #{lifecycle.field} is #{held.inspect}, " \
                              "a state this era's lifecycle never reaches"
              end
            rescue Runtime::InvariantViolation, Runtime::TypeMismatch => error
              violations << "#{aggregate.name}##{id}: #{error.message}"
            end
          end
        end
      end
    end
  end
end
