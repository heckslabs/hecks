module Hecks
  module Fuzzing
    module Properties
      # Re-checks the invariants of stored records and of the entity elements nested in them,
      # independently of the call site that was supposed to refuse a violation live.
      module PieceInvariants
        # The message for one stored record that violates an invariant, or nil.
        def stored_record_offense(bluebooks, key, state)
          domain_name    = key.split("::").first
          aggregate_name = key.split("::").last.split("#").first
          aggregate      = bluebooks[domain_name]&.aggregate(aggregate_name)
          return unless aggregate

          violated = violated_invariant(aggregate, state)
          return "#{key} violates #{aggregate_name}'s own declared invariant #{violated.description.inspect}" if violated

          check_piece_invariants(aggregate, state, key)
        end

        # The first invariant of `construct` that `state` does not satisfy, or nil.
        def violated_invariant(construct, state)
          construct.invariants.find { |invariant| !Bluebook::Expression::Evaluator.call(invariant.canonical, state) }
        end

        # A piece's own invariant, checked against every element its owner's
        # `list_of` field holds — reapplies Admissibility#check_entity_invariants'
        # own lookup against a plain Hash state rather than a live Instance.
        def check_piece_invariants(owner_construct, owner_state, key)
          owner_construct.entities.each do |entity|
            next if entity.invariants.empty?

            list_attr = list_attribute_for(owner_construct, entity)
            next unless list_attr

            Array(owner_state[list_attr.name]).each do |element|
              problem = piece_problem(entity, element, key)
              return problem if problem
            end
          end
          nil
        end

        # The owner's `list_of` attribute holding `entity`'s elements.
        def list_attribute_for(owner_construct, entity)
          owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
        end

        # The message for one piece element that violates, or whose own nested pieces violate.
        def piece_problem(entity, element, key)
          violated = violated_invariant(entity, element)
          if violated
            return "#{key}'s own #{entity.hecks_name} violates its declared invariant " \
                   "#{violated.description.inspect}"
          end

          check_piece_invariants(entity, element, key)
        end
      end
    end
  end
end
