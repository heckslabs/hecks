# Hecks::DSL::TypeName
#
# @domain Layout
#
# Predicate for detecting type names in the ubiquitous language.
# A type name starts with an uppercase letter (PascalCase).
#
#   TypeName.match?("Pizza")      # => true
#   TypeName.match?("name")       # => false
#   TypeName.match?(Pizza)        # => true (Module)
#   TypeName.match?(String)       # => true (Class)
#
module Hecks
  module DSL
    module TypeName
      PATTERN = /\A[A-Z]/

      def self.match?(value)
        value.to_s.match?(PATTERN)
      end
    end
  end
end
