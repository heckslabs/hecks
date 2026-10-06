require_relative "../../forms/value_object_shape"
require_relative "../../runtime/errors"
require_relative "../../runtime/value"

module Hecks
  module Adapters
    # Which member of a value object a SQL comparison reads: its numeric member, else its sole
    # attribute, else `value`. `SqlQueryBuilder` uses it so both sides of a comparison agree on
    # which field they mean.
    module SqlValueMembers
      private

      # The value's own numeric member when it has one, else the attribute's value-object member.
      def expression_member(attribute, value)
        member = (numeric_member_name(value) if value)
        member ||= object_member_name(attribute) if attribute && value_object?(attribute)
        member
      end

      def numeric_member_name(value)
        hash = value.is_a?(Runtime::Value) ? value.to_h : value
        pair = hash.find { |_key, item| item.is_a?(Numeric) } if hash.is_a?(Hash)
        pair&.first
      end

      # A single-attribute value object is its one field, whatever it is named.
      def object_member_name(attribute)
        object = Runtime::Value.value_object_for(@aggregate, attribute.type)
        (Forms::ValueObjectShape.numeric_member(object) || object.sole_attribute)&.name
      end

      # Picks the same member `query_expression` does, so both sides of a comparison
      # agree on which field they mean.
      def query_value(value, args)
        value = args[value] if value.is_a?(Symbol)
        picked = picked_member(value.is_a?(Runtime::Value) ? value.to_h : value)
        return picked.first if picked

        Runtime::Value.scalar(value)
      rescue Runtime::TypeMismatch
        value.is_a?(Hash) && value.size == 1 ? value.values.first : value
      end

      # The member of a Hash value a comparison reads, as a one-element Array so a nil member
      # still counts as picked; nil when the value is no Hash or has no such member.
      def picked_member(hash)
        return nil unless hash.is_a?(Hash)

        numeric = hash.find { |_key, item| item.is_a?(Numeric) }
        return [numeric.last] if numeric
        return [hash[:value]] if hash.key?(:value)

        [hash.values.first] if hash.size == 1
      end
    end
  end
end
