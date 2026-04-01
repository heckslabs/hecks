module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::SingleAttributeAggregate
    #
    # Advisory warning for aggregates that have exactly one attribute and no
    # value objects or entities. A single-attribute aggregate with no composition
    # is often better modeled as a value object inside another aggregate.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    # Example trigger:
    #   aggregate "Color" do
    #     attribute :hex, String
    #     command "CreateColor" do attribute :hex, String end
    #   end
    #
    # Would warn: "Color has only 1 attribute and no value objects or entities --
    #   consider modeling as a value object"
    class SingleAttributeAggregate < BaseRule
      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array<String>] always empty
      def errors
        []
      end

      # Returns a warning for each aggregate that has exactly one attribute and
      # no value objects or entities.
      #
      # @return [Array<String>] warning messages
      def warnings
        result = []
        @domain.aggregates.each do |agg|
          vos = agg.respond_to?(:value_objects) ? agg.value_objects : []
          entities = agg.respond_to?(:entities) ? agg.entities : []
          if agg.attributes.size == 1 && vos.empty? && entities.empty?
            result << "#{agg.name} has only 1 attribute and no value objects or entities -- consider modeling as a value object"
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(SingleAttributeAggregate)
    end
  end
end
