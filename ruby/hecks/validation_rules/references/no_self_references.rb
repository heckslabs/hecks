module Hecks
  module ValidationRules
    module References

    # Hecks::ValidationRules::References::NoSelfReferences
    #
    # Validates that aggregates do not reference themselves. Self-references
    # indicate a modeling issue -- the referenced concept should be a value
    # object or entity within the aggregate boundary instead.
    #
    # Part of the ValidationRules::References group -- run by +Hecks.validate+.
    #
    # An aggregate should not reference itself.
    class NoSelfReferences < BaseRule
      # Checks each aggregate's reference attributes for any that target
      # the same aggregate.
      #
      # @return [Array<String>] error messages for each self-referencing attribute found
      def errors
        result = []
        @domain.aggregates.each do |agg|
          (agg.references || []).each do |ref|
            if ref.type.to_s == agg.name
              result << error("#{agg.name} references itself",
                hint: "Use a value object or entity inside the aggregate instead of a self-reference")
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(NoSelfReferences)
    end
  end
end
