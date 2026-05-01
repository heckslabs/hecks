# Hecks::ValidationRules::ValidationMessage
#
# Structured validation error that carries both a human-readable message
# and an optional hint describing how to fix the issue. Behaves like a
# String via +to_s+ and +to_str+ so existing code that treats errors as
# plain strings continues to work without changes.
#
# == Usage
#
#   msg = ValidationMessage.new("Name is blank", hint: "Add: attribute :name, String")
#   msg.to_s    # => "Name is blank"
#   msg.hint    # => "Add: attribute :name, String"
#   msg.to_h    # => { message: "Name is blank", hint: "Add: attribute :name, String" }
#
module Hecks
  module ValidationRules
    class ValidationMessage
      # @return [String] the error description
      attr_reader :message

      # @return [String, nil] a suggestion for how to fix the issue
      attr_reader :hint

      # @param message [String] the error description
      # @param hint [String, nil] remediation suggestion
      def initialize(message, hint: nil)
        @message = message
        @hint = hint
      end

      # Delegate string behavior so existing code treating errors as strings works.
      #
      # @return [String] the error message
      def to_s
        message
      end

      # Implicit string coercion for interpolation and comparison.
      # Includes hint for full-text searching.
      #
      # @return [String] the error message with hint appended
      def to_str
        hint ? "#{message} #{hint}" : message
      end

      # Structured representation for JSON serialization.
      #
      # @return [Hash] with :message and optionally :hint keys
      def to_h
        h = { message: message }
        h[:hint] = hint if hint
        h
      end

      # Equality based on message content (matches String comparison).
      def ==(other)
        to_s == other.to_s
      end

      # Pattern matching support — checks message and hint.
      def include?(str)
        to_str.include?(str)
      end

      # Support start_with? for world goals detection in Validator.
      def start_with?(*args)
        message.start_with?(*args)
      end

      # Delegate downcase for case-insensitive matching.
      def downcase
        to_str.downcase
      end

      # Regex matching — checks message and hint.
      def =~(pattern)
        to_str =~ pattern
      end

      # Regex match delegation — checks message and hint.
      def match(pattern)
        to_str.match(pattern)
      end

      # Regex match? delegation — checks message and hint.
      def match?(pattern)
        to_str.match?(pattern)
      end
    end
  end
end
