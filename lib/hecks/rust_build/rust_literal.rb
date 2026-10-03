# frozen_string_literal: true

module Hecks
  module RustBuild
    # Rust string literals. Ruby's `String#inspect` escapes for Ruby's own read-back (a
    # brace-less `\uXXXX`, for one), which is not valid Rust syntax.
    module RustLiteral
      # Escapes only what Rust's string-literal grammar needs: backslash, double quote and
      # control characters.
      #
      # @param text [#to_s] the text to embed
      # @return [String] the quoted literal
      def self.string(text)
        escaped = text.to_s.each_char.map { |char| escape(char) }.join
        "\"#{escaped}\""
      end

      def self.escape(char)
        case char
        when "\\" then "\\\\"
        when "\"" then "\\\""
        when "\n" then "\\n"
        when "\r" then "\\r"
        when "\t" then "\\t"
        else
          code = char.ord
          code < 0x20 || code == 0x7F ? format("\\u{%x}", code) : char
        end
      end
      private_class_method :escape
    end
  end
end
