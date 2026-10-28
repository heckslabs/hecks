module Hecks
  module Bluebook
    module ModelCheck
      # The check that a declared relationship says something its context's wiring does not already
      # (ADR 0155). An `attaches` makes the attaching context a conformist of the attached one, so a
      # bare conformist line that only an attach explains is dropped from the map.
      module RedundantRelationships
        # An `attaches` already says the attaching context conforms to the attached one (ADR 0155),
        # so a plain conformist relationship that only the attach explains states nothing new.
        #
        # @return [Array<Finding>] one warning per such relationship
        def redundant_relationship_findings(map, edges)
          map.relationships.filter_map do |relationship|
            next unless restates_attach?(relationship, edges)
            next if relationship.acknowledges?(:redundant_relationship)

            Finding.new(kind: :redundant_relationship, severity: :warning,
                        subject: "#{relationship.downstream} <- #{relationship.upstream}",
                        message: "the attach already makes #{relationship.downstream} a conformist of " \
                                 "#{relationship.upstream}; drop this line")
          end
        end

        # @return [Boolean] whether the relationship is a bare conformist that attaches alone explain
        def restates_attach?(relationship, edges)
          return false unless relationship.kind == :conformist && relationship.published.to_a.empty?

          between = edges.select { |edge| [edge[:from], edge[:to]].sort == relationship.pair }
          between.any? && between.all? { |edge| attach_from?(edge, relationship) }
        end

        def attach_from?(edge, relationship)
          edge[:kind] == ContextMap::ATTACH && edge[:from] == relationship.downstream
        end
      end
    end
  end
end
