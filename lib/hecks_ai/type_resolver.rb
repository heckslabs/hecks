# Hecks::AI::TypeResolver
#
# Shared module for converting type strings to Ruby types or descriptor hashes.
# Extracted from McpServer so it can be reused by DomainBuilder and other
# components that need to interpret typed attribute declarations.
#
# Supported formats:
#   "String"               -> String
#   "Integer"              -> Integer
#   "Float"                -> Float
#   "list_of(Topping)"     -> { list: "Topping" }
#   "reference_to(Order)"  -> treated as reference (see reference_type?)
#   anything else          -> String (default)
#
#   Hecks::AI::TypeResolver.resolve("Float")          # => Float
#   Hecks::AI::TypeResolver.resolve("list_of(Item)")  # => { list: "Item" }
#
module Hecks
  module AI
    module TypeResolver
      # Converts a type string into a Ruby type or descriptor hash.
      #
      # @param type_str [String, nil] the type string to resolve
      # @return [Class, Hash] the resolved type
      def self.resolve(type_str)
        case type_str.to_s
        when "String"  then String
        when "Integer" then Integer
        when "Float"   then Float
        when /^list_of\((.+)\)$/ then { list: $1.delete('"') }
        else String
        end
      end

      # Returns true when the type string is a reference_to declaration.
      #
      # @param type_str [String, nil] the type string to check
      # @return [Boolean]
      def self.reference_type?(type_str)
        type_str.to_s =~ /^reference_to\(/
      end

      # Extracts the target aggregate name from a reference_to string.
      #
      # @param type_str [String] e.g. "reference_to(Order)" or "reference_to('Order')"
      # @return [String, nil] the target name, or nil if not a reference
      def self.reference_target(type_str)
        type_str.to_s[/^reference_to\(["']?(.+?)["']?\)$/, 1]
      end
    end
  end
end
