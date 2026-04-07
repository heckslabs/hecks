# Hecks::DSL::AggregateBuilder::ConstraintMethods
#
# Validation and invariant DSL methods extracted from AggregateBuilder.
#
module Hecks
  module DSL
    class AggregateBuilder
      module ConstraintMethods
        # Add a field-level validation rule.
        #
        # @param field [Symbol] the attribute name to validate
        # @param rules [Hash] validation rules (e.g. +{ presence: true }+)
        # @return [void]
        def validation(field, rules)
          @validations << DomainModel::Structure::Validation.new(field: field, rules: rules)
        end

        # Define an aggregate-level invariant.
        #
        # @param message [String] human-readable invariant description
        # @yield block that returns true when the invariant holds
        # @return [void]
        def invariant(message, &block)
          @invariants << DomainModel::Structure::Invariant.new(message: message, block: block)
        end

        # Deprecated: ports moved to Hecksagon as gates. Kept as no-op for compatibility.
        def port(_name, _methods = nil, &_block); end
      end
    end
  end
end
