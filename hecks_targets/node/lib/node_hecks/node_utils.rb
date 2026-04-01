# NodeHecks::NodeUtils
#
# Naming and type mapping utilities for TypeScript code generation.
# Converts Ruby DSL types to TypeScript types, PascalCase to camelCase, etc.
#
#   NodeHecks::NodeUtils.ts_type(attr)  # => "string" | "number" | "Topping[]"
#   NodeHecks::NodeUtils.camel_case("customer_name")  # => "customerName"
#
module NodeHecks
  module NodeUtils
    include HecksTemplating::NamingHelpers
    module_function

    # Maps {TrueClass => "Boolean"} so TypeContract can find it
    RUBY_TYPE_ALIASES = { "TrueClass" => "Boolean", "FalseClass" => "Boolean" }.freeze

    def ts_type(attr)
      if attr.list?
        "#{pascal_case(attr.type.to_s)}[]"
      else
        type_name = RUBY_TYPE_ALIASES[attr.type.to_s] || attr.type.to_s
        HecksTemplating::TypeContract.for(:node, type_name)
      end
    end

    def pascal_case(str)
      s = str.to_s
      return s if s =~ /\A[A-Z]/ && !s.include?("_")
      s.split("_").map(&:capitalize).join
    end

    def camel_case(str)
      s = snake_case(str.to_s)
      parts = s.split("_")
      parts.first.downcase + parts[1..].map(&:capitalize).join
    end

    def snake_case(str)
      HecksTemplating::Names.domain_snake_name(str.to_s)
    end

    def kebab_case(str)
      snake_case(str).tr("_", "-")
    end
  end
end
