# Hecks::ValidationRules::Naming::StringReferences
#
# @domain AcceptanceTest
#
# Enforces that reference_to and list_of use bare constants, not strings.
# Strings are ambiguous — constants are objects in the ubiquitous language.
#
#   reference_to Pizza          # good
#   reference_to "Pizza"        # error
#   list_of(Topping)            # good
#   list_of("Topping")          # error
#
module Hecks
  module ValidationRules
    module Naming

    class StringReferences < BaseRule
      def errors
        # String references are caught at parse time by the DSL,
        # not at validation time. This rule is advisory.
        []
      end

      def warnings
        result = []
        @domain.aggregates.each do |agg|
          agg.attributes.each do |attr|
            type_s = attr.type.to_s
            if attr.type.class == String && type_s =~ /\A[A-Z]/
              result << "#{agg.name}.#{attr.name} uses string type \"#{type_s}\" — use bare constant #{type_s} instead"
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(StringReferences)
    end
  end
end
