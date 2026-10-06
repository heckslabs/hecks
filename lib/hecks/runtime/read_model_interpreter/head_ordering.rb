module Hecks
  module Runtime
    class ReadModelInterpreter
      # The order a read model's non-root heads are read in: by the references they hold toward
      # each other. Mixed into {ReadModelInterpreter}.
      module HeadOrdering
        private

        # Topologically sorts non-root heads by their declared reference fields
        # (Kahn's algorithm); a cycle falls back to declared order rather than looping.
        def order_other_heads(bluebook, root_heads, other_heads)
          resolved = root_heads.map { |head| head[:aggregate] }
          remaining = other_heads.dup
          ordered = []
          until remaining.empty?
            ready, remaining = remaining.partition { |head| ready_head?(bluebook, head, other_heads, resolved) }
            return ordered.concat(remaining) if ready.empty?

            ordered.concat(ready)
            resolved.concat(ready.map { |head| head[:aggregate] })
          end
          ordered
        end

        # Whether every head `head` depends on has already been read.
        def ready_head?(bluebook, head, other_heads, resolved)
          depends_on(bluebook, head, other_heads).all? { |target| resolved.include?(target) }
        end

        # Which other declared heads a head's own aggregate holds a reference field
        # toward; an entity-headed include resolves no aggregate and so depends on nothing.
        def depends_on(bluebook, head, other_heads)
          aggregate = bluebook.aggregate(head[:aggregate])
          return [] unless aggregate

          other_heads.reject { |other| other[:aggregate] == head[:aggregate] }
                     .select { |other| reference_fields(aggregate, other[:aggregate]).any? }
                     .map { |other| other[:aggregate] }
        end

        def reference_fields(aggregate, target)
          aggregate.attributes
                   .select { |attribute| attribute.reference? && attribute.type.target_name == target.to_s }
                   .map(&:name)
        end
      end
    end
  end
end
