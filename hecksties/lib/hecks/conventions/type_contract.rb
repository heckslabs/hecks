# = Hecks::Conventions::TypeContract
#
# Registry-based type mapping. Targets register their own type maps.
# Generators query by target name instead of hardcoded methods.
#
#   Hecks::Conventions::TypeContract.for(:go, "Integer")  # => "int64"
#   Hecks::Conventions::TypeContract.for(:sql, "Integer") # => "INTEGER"
#
#   # New targets register themselves:
#   Hecks::Conventions::TypeContract.register_target(:java, {
#     "String" => "String", "Integer" => "long", ...
#   })
#
module Hecks::Conventions
  module TypeContract
    @targets = {}
    @defaults = {}

    # Built-in type definitions
    TYPES = {
      "String"   => { go: "string",          sql: "VARCHAR(255)", json: "string",  openapi: "string",  node: "string",  typescript: "string"                  },
      "Integer"  => { go: "int64",           sql: "INTEGER",      json: "integer", openapi: "integer", node: "number",  typescript: "number"                  },
      "Float"    => { go: "float64",         sql: "REAL",         json: "number",  openapi: "number",  node: "number",  typescript: "number"                  },
      "Boolean"  => { go: "bool",            sql: "BOOLEAN",      json: "boolean", openapi: "boolean", node: "boolean", typescript: "boolean"                 },
      "Date"     => { go: "time.Time",       sql: "DATE",         json: "string",  openapi: "string",  node: "string",  typescript: "string"                  },
      "DateTime" => { go: "time.Time",       sql: "VARCHAR(255)", json: "string",  openapi: "string",  node: "string",  typescript: "string"                  },
      "JSON"     => { go: "json.RawMessage", sql: "TEXT",         json: "object",  openapi: "object",  node: "Record<string, unknown>", typescript: "Record<string, unknown>" },
    }.freeze

    # Register a target with its type mappings and default.
    #
    #   TypeContract.register_target(:java, { "String" => "String", "Integer" => "long" }, default: "Object")
    #
    def self.register_target(name, mappings, default: "string")
      @targets[name.to_sym] = mappings
      @defaults[name.to_sym] = default
    end

    # Look up a type for a target. Falls back to registered targets,
    # then built-in TYPES, then the target's default.
    #
    #   TypeContract.for(:go, "Integer")  # => "int64"
    #   TypeContract.for(:java, "String") # => "String" (if registered)
    #
    def self.for(target, type)
      target = target.to_sym
      # Check registered targets first
      if @targets[target]
        return @targets[target][type.to_s] || @defaults[target]
      end
      # Fall back to built-in TYPES
      TYPES.dig(type.to_s, target) || @defaults[target] || "string"
    end

    # List all registered target names (including built-in)
    def self.targets
      (TYPES.values.first&.keys || []) | @targets.keys
    end

    # Convenience methods for built-in targets
    def self.go(type)         = self.for(:go, type)
    def self.sql(type)        = self.for(:sql, type)
    def self.json(type)       = self.for(:json, type)
    def self.openapi(type)    = self.for(:openapi, type)
    def self.node(type)       = self.for(:node, type)
    def self.typescript(type) = self.for(:typescript, type)

    # Register built-in defaults
    @defaults[:go] = "string"
    @defaults[:sql] = "TEXT"
    @defaults[:json] = "string"
    @defaults[:openapi] = "string"
    @defaults[:node] = "string"
    @defaults[:typescript] = "string"

    # Go-specific helpers

    def self.go_zero_value(go_type)
      case go_type
      when "string"          then '""'
      when "int64"           then "0"
      when "float64"         then "0.0"
      when "bool"            then "false"
      when "time.Time"       then "time.Time{}"
      when "json.RawMessage" then "nil"
      else "nil"
      end
    end

    def self.go_needs_time?(attrs)
      attrs.any? { |a| %w[Date DateTime].include?(a.type.to_s) }
    end

    def self.go_needs_json?(attrs)
      attrs.any? { |a| a.type.to_s == "JSON" }
    end

    def self.format_go_literal(value, go_type)
      case go_type
      when "int64", "float64"
        value.to_s
      when "bool"
        value.to_s
      when "string"
        "\"#{value}\""
      else
        "\"#{value}\""
      end
    end
  end
end
