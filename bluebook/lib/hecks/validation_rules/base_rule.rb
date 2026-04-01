module Hecks
  module ValidationRules

    # Hecks::ValidationRules::BaseRule
    #
    # Abstract base class for all domain validation rules. Each rule inspects a
    # domain model and returns an array of error messages (strings or
    # +ValidationMessage+ structs) describing any violations found.
    #
    # Subclasses must implement +#errors+ to return an array. An empty array
    # means the rule passes. Some rules also implement +#warnings+ for
    # non-blocking advisory messages.
    #
    # Rules are collected and executed by +Hecks.validate+ during domain compilation
    # and build. They are grouped into categories: Naming, References, and Structure.
    #
    # == Usage
    #
    #   class MyRule < BaseRule
    #     def errors
    #       [error("Name is blank", hint: "Add a name attribute")]
    #     end
    #   end
    #
    #   rule = MyRule.new(domain)
    #   rule.errors  # => [#<ValidationMessage message="..." hint="...">]
    #
    class BaseRule
      # Initializes the rule with the domain model to validate.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain model containing
      #   aggregates, commands, events, policies, and their attributes/references
      def initialize(domain)
        @domain = domain
      end

      # Returns an array of error messages for validation failures found in the domain.
      # Subclasses must override this method.
      #
      # @return [Array<String, ValidationMessage>] error messages; empty array if the rule passes
      # @raise [NotImplementedError] if the subclass has not implemented this method
      def errors
        raise NotImplementedError
      end

      private

      # Build a structured validation message with an optional fix hint.
      #
      # @param message [String] the error description
      # @param hint [String, nil] a suggestion for how to fix the issue
      # @return [ValidationMessage] structured error with hint
      def error(message, hint: nil)
        ValidationMessage.new(message, hint: hint)
      end
    end
  end
end
