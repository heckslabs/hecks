module Hecks
  module Forms
    # Shared value-object shape classification, so callers such as
    # field_shape.rb and sql_query_builder.rb agree on it. There is no Ruby ui_schema; the Rust
    # host builds the UI schema (rust/host/src/ui_schema.rs) from the same field-shape rules.
    module ValueObjectShape
      module_function

      # True if the VO's attributes are exactly `cents` and `currency`, the
      # convention every money-shaped VO in the corpus follows.
      def money?(value_object)
        value_object.attributes.map { |a| a.name.to_s }.sort == %w[cents currency]
      end

      # A VO with exactly one attribute names a scalar, not a genuine group.
      # Returns that attribute, or nil for anything else.
      def sole_attribute(value_object)
        return nil unless value_object.attributes.size == 1

        value_object.attributes.first
      end

      # The first Integer/Float member, or nil — what a numeric comparison or
      # ORDER BY compiles against when the VO isn't money-shaped.
      def numeric_member(value_object)
        value_object.attributes.find { |a| %w[Integer Float].include?(a.type.to_s) }
      end
    end
  end
end
