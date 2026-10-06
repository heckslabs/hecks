module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # The query being sealed, with the shape it asks about: its owner's label, the owner's
        # attributes and its lifecycle.
        QueryScope = Struct.new(:owner, :query, :fields, :lifecycle) do
          # @return [String] how a refusal names this query: `Owner.QueryName`
          def label = "#{owner}.#{query.hecks_name}"
        end
        private_constant :QueryScope

        # Build-time checks that a query's fields resolve: where a field can land (a hop, a local
        # scalar, the lifecycle field, a value object), and which member a bare value-object field
        # means. Included into AggregateBuilder through `QuerySealing`.
        module QueryFieldSealing
          private

          # `/` crosses into another record and `.` walks fields inside this one, so a hop is
          # routed to `seal_query_hop` before any `.`-splitting.
          #
          # A closed decision tree over where a field can resolve: hop, local scalar, lifecycle
          # field, value object (refused), or nothing (refused).
          def seal_query_field(scope, field, ordering: false)
            return seal_query_hop(scope, field, ordering: ordering) if field.to_s.include?("/")

            name, *nested = field.to_s.split(".")
            attribute = scope.fields.find { |candidate| candidate.name.to_s == name }
            return refuse_ambiguous_comparison!(scope, field, attribute) if nested.empty? && attribute
            return if resolvable_query_field?(scope, name, nested, attribute)

            refuse_unresolvable_query_field!(scope, field, attribute, nested)
          end

          def resolvable_query_field?(scope, name, nested, attribute)
            return scope.lifecycle&.field.to_s == name if nested.empty?

            attribute && scalar_path?(attribute, nested)
          end

          def refuse_unresolvable_query_field!(scope, field, attribute, nested)
            if nested.any? && attribute && resolves?(attribute, nested)
              raise Malformed,
                    "#{scope.label} asks about #{field}, which lands on a " \
                    "value object, not a scalar — a dotted query path ends on a scalar " \
                    "member, or the engines answer it differently"
            end

            refuse_undeclared_query_field!(scope, field)
          end

          def refuse_undeclared_query_field!(scope, field)
            raise Malformed,
                  "#{scope.label} asks about #{field}, which #{scope.owner} " \
                  "never declares — a query over a field that does not exist " \
                  "matches nothing and refuses nothing"
          end

          # ORDER BY refuses a hop outright: a hop answers with a candidate set, not a sort key.
          #
          # A where hop is only recognised here. Its head must be one of this aggregate's own
          # references, but the target cannot resolve before the chapter exists, so
          # BluebookBuilder#validate_query_hops! checks the tail and the target later.
          def seal_query_hop(scope, field, ordering:)
            refuse_undeclared_query_field!(scope, field) unless QuerySpecification::HopPath.hop_head?(field, scope.fields)
            return unless ordering

            raise Malformed,
                  "#{scope.label} orders by #{field}, which hops through " \
                  "a reference — an ask is ordered by what its own answering rows " \
                  "hold, and a hop answers with a candidate set, not a sort key"
          end

          # A bare field naming a value object must say which member it means when several could
          # answer; otherwise engines disagree (first numeric member vs. no unwrap at all).
          #
          # Unambiguous is exactly one member, or exactly one numeric member among several.
          # A list is exempt: `contains` reads element membership, not a scalar comparison.
          def refuse_ambiguous_comparison!(scope, field, attribute)
            return if attribute.list?

            value_object = declared_value_object(attribute.type.to_s)
            return unless value_object

            members = QuerySpecification::Common::Comparison.ambiguous_members(value_object)
            return if members.empty?

            raise Malformed,
                  "#{scope.label} asks about #{field}, which names #{attribute.type} — " \
                  "it has #{members.size} members (#{members.join(", ")}) and no single one a " \
                  "comparison can mean; name the member (#{field}.#{members.first})"
          end

          def scalar_path?(attribute, nested)
            QuerySpecification::FieldPath.scalar_leaf?(attribute, nested) { |type| declared_value_object(type) }
          end

          def resolves?(attribute, nested)
            !QuerySpecification::FieldPath.leaf_attribute(attribute, nested) { |type| declared_value_object(type) }.nil?
          end
        end
      end
    end
  end
end
