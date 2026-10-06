require_relative "query_field_sealing"

module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # Build-time checks that what a query asks about exists on the aggregate or the piece that
        # declares it. Included into AggregateBuilder; `#build` runs them once every declaration is
        # in place.
        module QuerySealing
          include QueryFieldSealing

          ORDERED_COMPARATORS = %i[lt lte gt gte].freeze

          private

          # A query must ask about a field the aggregate has. A dotted path must land on a scalar
          # member, an ordered comparator (lt/gt/gte/lte) on a numeric leaf, and a :symbol value
          # must name one of the query's own arguments; else engines disagree or match nothing.
          def seal_query_targets
            query_surfaces.each do |owner, fields, lifecycle, queries|
              queries.each { |query| seal_query(QueryScope.new(owner, query, fields, lifecycle)) }
            end
          end

          def seal_query(scope)
            query = scope.query
            query.wheres.each { |clause| seal_where_clause(scope, clause) }
            seal_query_field(scope, query.order_by.field, ordering: true) if query.order_by
            seal_query_argument(scope, query.limit&.value)
            seal_query_argument(scope, query.offset&.value)
          end

          def seal_where_clause(scope, clause)
            seal_query_field(scope, clause.field)
            seal_ordered_comparator(scope, clause)
            infer_local_query_argument(scope, clause)
            seal_query_argument(scope, clause.value) unless clause.field.to_s.include?("/")
          end

          def query_surfaces
            [[@name, attributes, @lifecycle, @queries]] +
              @entities.map { |entity| ["#{@name}::#{entity.hecks_name}", entity.attributes, entity.lifecycle, entity.queries] }
          end

          def seal_ordered_comparator(scope, clause)
            return unless ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)

            # A where hop with an ordered comparator is legitimate; whether its tail is numeric
            # is BluebookBuilder#validate_query_hops!'s question, so it is deferred.
            return if deferred_hop?(scope, clause)

            name, *nested = clause.field.to_s.split(".")
            attribute = field_named(scope, name)
            return if attribute && numeric_path?(attribute, nested)

            refuse_unordered_comparison!(scope, clause, attribute)
          end

          def deferred_hop?(scope, clause)
            clause.field.to_s.include?("/") && QuerySpecification::HopPath.hop_head?(clause.field, scope.fields)
          end

          def field_named(scope, name) = scope.fields.find { |candidate| candidate.name.to_s == name }

          def leaf_of(root, nested)
            QuerySpecification::FieldPath.leaf_attribute(root, nested) { |type| declared_value_object(type) }
          end

          def numeric_path?(attribute, nested)
            QuerySpecification::FieldPath.numeric?(attribute, nested) { |type| declared_value_object(type) }
          end

          def refuse_unordered_comparison!(scope, clause, attribute)
            held = attribute ? "holds no number" : "is the lifecycle field, which holds text"
            raise Malformed,
                  "#{scope.label} compares #{clause.field} with #{clause.op}, " \
                  "but #{clause.field} #{held} — an ordered comparison needs a numeric " \
                  "field, and over anything else the adapters answer differently or not at all"
          end

          def seal_query_argument(scope, value)
            return unless value.is_a?(Symbol)
            return if scope.query.attribute(value)

            raise Malformed,
                  "#{scope.label} resolves :#{value} from its arguments, " \
                  "but declares no #{value} attribute — an argument that does not exist " \
                  "resolves to nil and matches nothing"
          end

          # A symbolic right-hand side is a query input; when the compared path lands on this
          # owner's shape its type is known, so no `attribute` line is needed. Reference hops
          # are inferred later by BluebookBuilder, once the chapter is owner-stamped.
          def infer_local_query_argument(scope, clause)
            name = clause.value
            return unless name.is_a?(Symbol)
            return if scope.query.attribute(name)
            return if clause.field.to_s.include?("/")

            leaf = inferred_argument(scope, name, clause.field)
            scope.query.attributes << leaf if leaf
          end

          def inferred_argument(scope, name, field)
            head, *nested = field.to_s.split(".")
            return Attribute.new(name: name, type: String) if nested.empty? && scope.lifecycle&.field.to_s == head

            root = field_named(scope, head)
            found = root && leaf_of(root, nested)
            found && Attribute.new(name: name, type: found.type, list: found.list?)
          end

          def declared_value_object(type_name)
            (@value_objects + closed_sets).find { |shape| shape.hecks_name.to_s == type_name }
          end
        end
      end
    end
  end
end
