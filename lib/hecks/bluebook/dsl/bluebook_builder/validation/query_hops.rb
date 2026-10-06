require_relative "hop_tails"

module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Resolves and checks the `where` hops that `AggregateBuilder` could only recognise at
          # seal time: a hop needs the other aggregates, which exist once the chapter is assembled.
          module QueryHops
            include HopTails

            private

            # Resolves and checks every `where` hop deferred at aggregate-seal time.
            # An entity query that hops through a reference is refused outright: nothing follows
            # the hop at runtime (`QueryInterpreter#entity_rows` reads fields by literal key),
            # so it would match nothing.
            def validate_query_hops!(bluebook)
              bluebook.aggregates.each do |aggregate|
                aggregate.queries.each do |query|
                  query.wheres.each do |clause|
                    validate_hop_clause!(aggregate, query, clause) if hop_clause?(aggregate, clause)
                  end
                end

                aggregate.entities.each { |entity| refuse_entity_query_hops!(aggregate, entity) }
              end
            end

            def hop_clause?(aggregate, clause)
              QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)
            end

            # Mints an implicit query attribute for each symbolic hop comparison, typed from
            # the scalar it compares against.
            def infer_hop_query_arguments!(bluebook)
              bluebook.aggregates.each do |aggregate|
                aggregate.queries.each do |query|
                  query.wheres.each do |clause|
                    leaf = inferred_hop_argument(aggregate, query, clause)
                    query.attributes << leaf if leaf
                  end
                end
              end
            end

            def inferred_hop_argument(aggregate, query, clause)
              name = clause.value
              return unless name.is_a?(Symbol) && !query.attribute(name) && hop_clause?(aggregate, clause)

              plan = QuerySpecification::HopPath.plan(clause.field, aggregate.attributes)
              return if plan.refusal || plan.hops.empty?

              inferred_hop_leaf(name, plan)
            end

            def inferred_hop_leaf(name, plan)
              target = plan.hops.last.target
              head, *nested = plan.tail.to_s.split(".")
              return Attribute.new(name: name, type: String) if nested.empty? && target.lifecycle&.field.to_s == head

              found = hop_leaf(target, head, nested)
              found && Attribute.new(name: name, type: found.type, list: found.list?)
            end

            def hop_leaf(target, head, nested)
              root = target.attributes.find { |candidate| candidate.name.to_s == head }
              root && QuerySpecification::FieldPath.leaf_attribute(root, nested) { |type| target.value_object(type) }
            end

            def refuse_entity_query_hops!(aggregate, entity)
              entity.queries.each do |query|
                query.wheres.each do |clause|
                  next unless QuerySpecification::HopPath.hop_head?(clause.field, entity.attributes)

                  raise Malformed,
                        "#{aggregate.hecks_name}::#{entity.hecks_name}.#{query.hecks_name} asks about " \
                        "#{clause.field}, which hops through #{entity.hecks_name}'s own reference — " \
                        "an entity query does not follow a hop the way an aggregate's own does; ask " \
                        "through the aggregate's own query instead, or open the target directly"
                end
              end
            end

            def validate_hop_clause!(aggregate, query, clause)
              plan = QuerySpecification::HopPath.plan(clause.field, aggregate.attributes)
              refuse_hop_plan!(HopSite.new(aggregate, query, clause, nil), plan)

              site = HopSite.new(aggregate, query, clause, plan.hops.last.target)
              validate_hop_tail!(site, plan.tail)
            end

            def refuse_hop_plan!(site, plan)
              asks = "#{site.label} asks about #{site.clause.field}"
              case plan.refusal
              when :unresolvable then refuse_unresolvable_hop!(asks, plan)
              when :too_deep     then refuse_too_deep_hop!(asks)
              end
            end

            # HopPath.plan pushes even an unresolved hop onto `hops`, so `target_name`
            # is always there.
            def refuse_unresolvable_hop!(asks, plan)
              raise Malformed,
                    "#{asks}, which hops to #{plan.hops.last.target_name}, which this chapter never " \
                    "declares — a hop into an aggregate this chapter cannot see resolves to " \
                    "nothing, and a where that resolves to nothing matches nothing and " \
                    "refuses nothing"
            end

            def refuse_too_deep_hop!(asks)
              raise Malformed,
                    "#{asks}, whose hop chain reaches #{QuerySpecification::HopPath::MAX_HOPS} " \
                    "references deep without landing — a chain this long is refused as a " \
                    "likely mistake, not a structural limit"
            end
          end
        end
      end
    end
  end
end
