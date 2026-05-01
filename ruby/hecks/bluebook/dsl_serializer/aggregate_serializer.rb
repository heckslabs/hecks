module Hecks
  class DslSerializer
    # Hecks::DslSerializer::AggregateSerializer
    #
    # Serializes aggregate roots, value objects, and entities into DSL lines.
    # Delegates to RuleSerializer and BehaviorSerializer for nested concerns.
    #
    #   AggregateSerializer.new(agg).call
    #   # => ["  aggregate \"Pizza\" do", ...]
    #
    module AggregateSerializer
      def serialize_aggregate(agg)
        desc_kwarg = agg.description ? ", definition: \"#{agg.description}\"" : ""
        lines = ["  aggregate \"#{agg.name}\"#{desc_kwarg} do"]
        lines.concat(serialize_attributes(agg.attributes, "    "))
        lines.concat(serialize_references(agg.references, "    "))
        lines.concat(serialize_value_objects(agg.value_objects))
        lines.concat(serialize_entities(agg.entities))
        lines.concat(serialize_validations(agg.validations))
        lines.concat(serialize_invariants(agg.invariants, "    "))
        lines.concat(serialize_scopes(agg.scopes))
        lines.concat(serialize_computed_attributes(agg.computed_attributes))
        lines.concat(serialize_queries(agg.queries))
        lines.concat(serialize_specifications(agg.specifications))
        lines.concat(serialize_commands(agg.commands))
        lines.concat(serialize_policies(agg.policies))
        lines.concat(serialize_subscribers(agg.subscribers))
        lines << "  end"
        lines
      end

      def serialize_value_objects(vos)
        vos.flat_map { |vo| serialize_nested_object(vo, "value_object") }
      end

      def serialize_entities(entities)
        entities.flat_map { |ent| serialize_nested_object(ent, "entity") }
      end

      private

      def serialize_nested_object(obj, keyword)
        indent = "    "
        child_indent = "      "
        lines = ["", "#{indent}#{keyword} \"#{obj.name}\" do"]
        lines << "#{child_indent}description \"#{obj.description}\"" if obj.description
        lines.concat(serialize_attributes(obj.attributes, child_indent))
        lines.concat(serialize_invariants(obj.invariants, child_indent))
        lines << "#{indent}end"
      end
    end
  end
end
