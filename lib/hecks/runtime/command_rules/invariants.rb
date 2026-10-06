require_relative "../../bluebook/expression/evaluator"
require_relative "../errors"
require_relative "../instance"
require_relative "guard_state"

module Hecks
  module Runtime
    class CommandRules
      module Admissibility
        # Holds a settled record to its aggregate's declared invariants, and to each of its
        # entities' own.
        module Invariants
          # Checks `aggregate`'s declared invariants against the settled
          # `subject`, then each of its entities' own invariants.
          #
          # No `dereference` here (ADR 0025) — an invariant may only read
          # `subject`'s own boundary, same rule enforce_givens/ensures hold to.
          #
          # @param subject [Runtime::Instance] the settled aggregate record checked
          # @param aggregate [Bluebook::Aggregate] the aggregate whose invariants are checked
          # @param domain [String, Symbol] domain `aggregate` belongs to
          # @return [void]
          # @raise [Runtime::InvariantViolation] a declared invariant does not hold, on
          #   `aggregate` itself or any of its entities
          def enforce_invariants(subject, aggregate, domain:)
            refuse_unmet_invariants(aggregate, GuardState.new(subject), {})

            check_entity_invariants(aggregate, subject, domain: domain)
          end

          # Checks each of `owner_construct`'s entity types' own invariants
          # against every instance it holds, recursing into nested entities.
          #
          # An entity with no matching list attribute on its owner is skipped,
          # not raised — a static-analysis gap, not a runtime concern here.
          #
          # @param owner_construct [Bluebook::Aggregate, Bluebook::Entity] whose entities are
          #   checked
          # @param owner_instance [Runtime::Instance] settled record holding the entity lists
          # @param domain [String, Symbol] the domain `owner_construct` belongs to
          # @return [void]
          # @raise [Runtime::InvariantViolation] an entity invariant does not hold
          def check_entity_invariants(owner_construct, owner_instance, domain:)
            owner_construct.entities.each do |entity|
              next if entity.invariants.empty?

              list_attr = entity_list_attribute(owner_construct, entity)
              next unless list_attr

              Array(owner_instance[list_attr.name]).each do |element|
                check_element_invariants(entity, element, owner_instance, domain)
              end
            end
          end

          private

          def entity_list_attribute(owner_construct, entity)
            owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
          end

          # An aggregate's or entity's own invariants, read against `state` and `attrs`.
          def refuse_unmet_invariants(construct, state, attrs)
            construct.invariants.each do |invariant|
              next if Bluebook::Expression::Evaluator.call_rule(invariant, state, attrs)

              raise InvariantViolation, "#{construct.hecks_name} refused — #{invariant.description}"
            end
          end

          def check_element_invariants(entity, element, owner_instance, domain)
            wrapped = Instance.new(aggregate: entity, id: nil, state: element)
            # No `dereference` (ADR 0025) — same boundary rule as
            # enforce_invariants above; `parent` (the owner's own
            # state, projected fields included) stays readable.
            refuse_unmet_invariants(entity, GuardState.new(wrapped), { parent: owner_instance.state })

            check_entity_invariants(entity, wrapped, domain: domain)
          end
        end
      end
    end
  end
end
