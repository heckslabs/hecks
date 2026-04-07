# GoHecks::GoUtils
#
# Naming and type mapping utilities for Go code generation.
# Converts Ruby DSL types to Go types, snake_case to camelCase, etc.
#
module GoHecks
  module GoUtils
    include HecksTemplating::NamingHelpers
    module_function

    def go_type(attr)
      if attr.list?
        "[]#{pascal_case(attr.type.to_s)}"
      else
        HecksTemplating::TypeContract.go(attr.type)
      end
    end

    def pascal_case(str)
      s = str.to_s
      return s if s =~ /\A[A-Z]/ && !s.include?("_") # Already PascalCase
      s.split("_").map(&:capitalize).join
    end

    GO_KEYWORDS = %w[type func var const if else for range switch case break continue return go defer select chan map struct interface package import].freeze

    def camel_case(str)
      s = str.to_s
      parts = s.split("_")
      result = parts.first + parts[1..].map(&:capitalize).join
      GO_KEYWORDS.include?(result) ? result + "Val" : result
    end

    def snake_case(str)
      HecksTemplating::Names.domain_snake_name(str.to_s)
    end

    def go_package(name)
      snake_case(name).downcase
    end

    def json_tag(name)
      snake_case(name)
    end

    def go_zero_value(type_str)
      HecksTemplating::TypeContract.go_zero_value(type_str)
    end

    def needs_time_import?(attrs)
      HecksTemplating::TypeContract.go_needs_time?(attrs)
    end

    def needs_json_import?(attrs)
      HecksTemplating::TypeContract.go_needs_json?(attrs)
    end
  end
end
