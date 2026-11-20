require_relative "../../../../../../runtime/errors"
require_relative "../../../../../../runtime/value"
require_relative "../../../../../../runtime/value/invariant_violation"

module Hecks
  module Translation
    module Audit
      # Layer 1's value check: holds each value a translated record stores to what dispatch
      # holds an offered one to, as the Rust audit (`rust/host/core/src/reference_validate.rs`)
      # does. Hydration trusts stored state and skips these checks, so they run here first.
      module StoredValues
        REFUSALS = [Runtime::TypeMismatch, Runtime::UnknownArgument, Runtime::InvariantViolation].freeze

        # The first refusal dispatch would give one of the record's stored values, walking the
        # declared attributes in order and skipping a slot the record does not hold.
        #
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param state [Hash{Symbol => Object}] one translated record's state, symbol-keyed
        # @return [String, nil] the refusal's message, or nil when every stored value passes
        def stored_value_refusal(aggregate, state)
          aggregate.attributes.each do |attribute|
            next unless state.key?(attribute.name.to_sym)

            check_stored_value!(aggregate, attribute, state[attribute.name.to_sym])
          end
          nil
        rescue *REFUSALS => e
          e.message
        end

        private

        # A list stored as anything but a list is refused as dispatch's argument gate refuses
        # it; every other value is coerced as a command argument is.
        def check_stored_value!(aggregate, attribute, value)
          Runtime::Value.refuse_scalar_list(aggregate, attribute, value)
          Runtime::Value.for_attribute(aggregate, attribute, value, argument: true)
        end
      end
    end
  end
end
