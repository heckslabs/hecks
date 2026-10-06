module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # One hopped `where`: the aggregate and query that ask, the clause, and the aggregate
          # the hop lands on.
          HopSite = Struct.new(:aggregate, :query, :clause, :target) do
            # @return [String] how a refusal names the asking query: `Aggregate.Query`
            def label = "#{aggregate.hecks_name}.#{query.hecks_name}"
          end
          private_constant :HopSite

          # Checks where a hop lands: the field the clause asks about on the aggregate it hops to,
          # and the comparator it is compared with.
          module HopTails
            private

            # Same three-way answer as `seal_query_field` (scalar, value object, or
            # nothing), asked of the hop's target.
            def validate_hop_tail!(site, tail)
              name, *nested = tail.to_s.split(".")
              attribute = site.target.attributes.find { |candidate| candidate.name.to_s == name }
              return validate_hop_comparator!(site, attribute, nested) if hop_tail_scalar?(site.target, attribute, name, nested)

              refuse_hop_tail!(site, attribute, tail, nested)
            end

            def hop_tail_scalar?(target, attribute, name, nested)
              return attribute || target.lifecycle&.field.to_s == name if nested.empty?

              attribute && QuerySpecification::FieldPath.scalar_leaf?(attribute, nested) { |type| target.value_object(type) }
            end

            def refuse_hop_tail!(site, attribute, tail, nested)
              target = site.target
              asks = "#{site.label} asks about #{site.clause.field}, which hops to #{target.hecks_name} " \
                     "and then asks about #{tail}, which"
              raise Malformed, "#{asks} #{hop_tail_fault(target, attribute, nested)}"
            end

            def hop_tail_fault(target, attribute, nested)
              if nested.any? && attribute && hop_leaf_resolves?(target, attribute, nested)
                "lands on a value object, not a scalar — a dotted query path ends on a " \
                  "scalar member, or the engines answer it differently"
              else
                "#{target.hecks_name} never declares — a query over a field that does " \
                  "not exist matches nothing and refuses nothing"
              end
            end

            def hop_leaf_resolves?(target, attribute, nested)
              !QuerySpecification::FieldPath.leaf_attribute(attribute, nested) { |type| target.value_object(type) }.nil?
            end

            # An ordered comparator over a hopped field must land on a number; the check
            # `AggregateBuilder#seal_ordered_comparator` deferred.
            def validate_hop_comparator!(site, attribute, nested)
              clause = site.clause
              return unless AggregateBuilder::ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)
              return if attribute && numeric_hop_leaf?(site.target, attribute, nested)

              held = attribute ? "holds no number" : "is the lifecycle field, which holds text"
              raise Malformed,
                    "#{site.label} compares #{clause.field} with " \
                    "#{clause.op} after hopping to #{site.target.hecks_name}, but the field it lands " \
                    "on #{held} — an ordered comparison needs a numeric field, and over " \
                    "anything else the adapters answer differently or not at all"
            end

            def numeric_hop_leaf?(target, attribute, nested)
              QuerySpecification::FieldPath.numeric?(attribute, nested) { |type| target.value_object(type) }
            end
          end
        end
      end
    end
  end
end
