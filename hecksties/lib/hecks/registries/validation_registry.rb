# Hecks::ValidationRegistryMethods
#
# Registry for domain validation rules. Each rule class registers itself
# so the Validator can discover rules without a hardcoded constant list.
#
#   Hecks.register_validation_rule(ValidationRules::Naming::UniqueAggregateNames)
#   Hecks.validation_rules  # => [UniqueAggregateNames, ...]
#
module Hecks
  # Hecks::ValidationRegistryMethods
  #
  # Registry for domain validation rules discovered without a hardcoded constant list.
  #
  module ValidationRegistryMethods
    def validation_rules
      validation_rule_registry.all
    end

    def register_validation_rule(rule_class)
      validation_rule_registry.register(rule_class)
    end

    private

    def validation_rule_registry
      @validation_rule_registry ||= SetRegistry.new
    end
  end
end
