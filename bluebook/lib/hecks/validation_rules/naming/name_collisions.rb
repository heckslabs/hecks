module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::NameCollisions
    #
    # Validates that aggregate root names do not collide with their own value
    # object or entity names. Such collisions create ambiguity in the generated
    # code since both would map to the same Ruby constant within the aggregate
    # module.
    #
    # Part of the ValidationRules::Naming group -- run by +Hecks.validate+.
    #
    # Aggregate root name must not collide with its value object or entity names.
    class NameCollisions < BaseRule
      # Checks all aggregates for name collisions between the aggregate root
      # and its value objects or entities.
      #
      # @return [Array<String>] error messages for each collision found
      def errors
        result = []
        @domain.aggregates.each do |agg|
          agg.value_objects.each do |vo|
            if vo.name == agg.name
              result << error("#{agg.name} has a value object with the same name as the aggregate root",
                hint: "Rename the value object to avoid ambiguity, e.g. #{agg.name}Details")
            end
          end
          agg.entities.each do |ent|
            if ent.name == agg.name
              result << error("#{agg.name} has an entity with the same name as the aggregate root",
                hint: "Rename the entity to avoid ambiguity, e.g. #{agg.name}Item")
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(NameCollisions)
    end
  end
end
