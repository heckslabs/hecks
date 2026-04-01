module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::ComputedNameCollisions
    #
    # Validates that computed attribute names do not collide with regular
    # attribute names on the same aggregate. Such collisions would generate
    # a method that shadows the stored attribute accessor.
    #
    # Part of the ValidationRules::Naming group -- run by +Hecks.validate+.
    #
    #   rule = ComputedNameCollisions.new(domain)
    #   rule.errors  # => ["Parcel: computed attribute 'area' collides with a regular attribute"]
    #
    class ComputedNameCollisions < BaseRule
      # Checks all aggregates for name collisions between computed and regular attributes.
      #
      # @return [Array<String>] error messages for each collision found
      def errors
        result = []
        @domain.aggregates.each do |agg|
          attr_names = agg.attributes.map(&:name).map(&:to_sym)
          (agg.computed_attributes || []).each do |ca|
            if attr_names.include?(ca.name.to_sym)
              result << "#{agg.name}: computed attribute '#{ca.name}' collides with a regular attribute"
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(ComputedNameCollisions)
    end
  end
end
