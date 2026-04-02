# Hecks::GovernanceGuard::Result
#
# Immutable result object from a governance check. Holds violations
# (blocking issues) and suggestions (actionable improvements). A result
# passes when there are no violations.
#
#   result = Hecks::GovernanceGuard::Result.new(
#     violations:  [{ concern: :privacy, message: "PII exposed" }],
#     suggestions: ["Add visible: false to PII attributes"]
#   )
#   result.passed?      # => false
#   result.violations   # => [{ concern: :privacy, message: "PII exposed" }]
#
module Hecks
  class GovernanceGuard
    class Result
      # @return [Array<Hash>] violations with :concern and :message keys
      attr_reader :violations

      # @return [Array<String>] actionable suggestions for improvement
      attr_reader :suggestions

      # @param violations [Array<Hash>] each with :concern (Symbol) and :message (String)
      # @param suggestions [Array<String>] improvement recommendations
      def initialize(violations: [], suggestions: [])
        @violations = violations.freeze
        @suggestions = suggestions.freeze
      end

      # True when no violations were found.
      #
      # @return [Boolean]
      def passed?
        @violations.empty?
      end

      # Structured hash for JSON serialization.
      #
      # @return [Hash]
      def to_h
        { passed: passed?, violations: violations, suggestions: suggestions }
      end
    end
  end
end
