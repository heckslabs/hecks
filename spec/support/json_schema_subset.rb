require "json"

# Checks a value against the JSON Schema keywords the command schema projection emits: type, enum,
# anyOf, properties, required, additionalProperties, items and pattern. It is a spec aid and the
# reference for what a client's local check has to understand, not a general validator.
module JsonSchemaSubset
  TYPES = {
    "string"  => ->(value) { value.is_a?(String) },
    "integer" => ->(value) { value.is_a?(Integer) },
    "number"  => ->(value) { value.is_a?(Numeric) },
    "boolean" => ->(value) { [true, false].include?(value) },
    "object"  => ->(value) { value.is_a?(Hash) },
    "array"   => ->(value) { value.is_a?(Array) }
  }.freeze

  # Each keyword's check: its argument, the value, and the schema it sits in. A keyword about
  # objects or arrays holds for a value of any other kind.
  KEYWORDS = {
    "type"                 => ->(argument, value, _schema) { TYPES.fetch(argument).call(value) },
    "enum"                 => ->(argument, value, _schema) { argument.include?(value) },
    "pattern"              => ->(argument, value, _schema) { JsonSchemaSubset.pattern_ok?(argument, value) },
    "anyOf"                => ->(argument, value, _schema) { JsonSchemaSubset.branch_ok?(argument, value) },
    "required"             => ->(argument, value, _schema) { JsonSchemaSubset.required_ok?(argument, value) },
    "properties"           => ->(argument, value, _schema) { JsonSchemaSubset.properties_ok?(argument, value) },
    "additionalProperties" => ->(argument, value, schema) { JsonSchemaSubset.extras_ok?(argument, value, schema) },
    "items"                => ->(argument, value, _schema) { JsonSchemaSubset.items_ok?(argument, value) }
  }.freeze

  ANYTHING = ->(_argument, _value, _schema) { true }

  module_function

  # @param schema [Hash] a projected schema
  # @param value [Object] a payload; symbol keys are read as strings, as they would be over JSON
  # @return [Boolean] whether the payload satisfies every keyword the schema uses
  def valid?(schema, value) = satisfied?(schema, JSON.parse(JSON.generate(value)))

  def satisfied?(schema, value)
    schema.all? { |keyword, argument| KEYWORDS.fetch(keyword, ANYTHING).call(argument, value, schema) }
  end

  def pattern_ok?(pattern, value) = value.is_a?(String) && value.match?(Regexp.new(pattern))

  def branch_ok?(branches, value) = branches.any? { |branch| satisfied?(branch, value) }

  def required_ok?(names, value) = !value.is_a?(Hash) || names.all? { |name| value.key?(name) }

  def properties_ok?(properties, value)
    return true unless value.is_a?(Hash)

    value.all? { |name, inner| !properties.key?(name) || satisfied?(properties[name], inner) }
  end

  def extras_ok?(argument, value, schema)
    return true unless argument == false && value.is_a?(Hash)

    (value.keys - schema.fetch("properties", {}).keys).empty?
  end

  def items_ok?(item_schema, value)
    return true unless value.is_a?(Array)

    value.all? { |item| satisfied?(item_schema, item) }
  end
end
