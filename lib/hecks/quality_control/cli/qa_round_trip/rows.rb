# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # How the protocol prints a record: plain values, value objects unwrapped to their single
      # field, and a list of entities sorted by the entities' identity.
      module Rows
        module_function

        # Unwraps a record or value into the protocol's plain JSON shape.
        #
        # @param value [Object] a record's state, a value object, or a scalar
        # @return [Object] Hashes with String keys, Arrays, Strings, numbers, booleans or nil
        def plain(value)
          case value
          when Hash then single_value?(value) ? plain(value.values.first) : value.to_h { |k, v| [k.to_s, plain(v)] }
          when Array then value.map { |element| plain(element) }
          else scalar(value)
          end
        end

        # A value that is not a Hash or an Array: itself when JSON can hold it, otherwise its Hash
        # form.
        #
        # @param value [Object] a scalar, or a value object that answers `to_h`
        # @return [Object] the value, or its `to_h` made plain
        def scalar(value)
          return value if [String, Numeric, TrueClass, FalseClass, NilClass].any? { |kind| value.is_a?(kind) }

          value.respond_to?(:to_h) ? plain(value.to_h) : value
        end

        # Sorts each list of entities in a plain record by the entities' identity field.
        #
        # @param record [Hash{String => Object}] a record, as `plain` answers it
        # @param bluebook_ir [Hash] the domain's IR, whose entities name their identity fields
        # @return [Hash{String => Object}] the record, its entity lists sorted
        def sorted_entities(record, bluebook_ir)
          heads = entity_heads(bluebook_ir)
          record.to_h { |field, value| [field, entity_list?(value) ? sorted_list(value, heads) : value] }
        end

        # Whether a field holds a list of entities.
        #
        # @param value [Object] a field's plain value
        # @return [Boolean] true for an Array of Hashes
        def entity_list?(value) = value.is_a?(Array) && value.all?(Hash)

        # Sorts a list of entities by the first identity field every one of them carries: numbers
        # by value, before any other identity, which sorts as text.
        #
        # @param list [Array<Hash>] the entities
        # @param heads [Array<String>] the domain's entity identity fields
        # @return [Array<Hash>] the list, sorted when an identity field fits it
        def sorted_list(list, heads)
          head = heads.find { |name| list.all? { |entity| entity.key?(name) } }
          head ? list.sort_by { |entity| identity_order(entity[head]) } : list
        end

        # How one identity sorts: a number by its value, anything else after numbers, as text.
        #
        # @param identity [Object] an entity's identity value
        # @return [Array(Integer, Object)] the sort key
        def identity_order(identity) = identity.is_a?(Numeric) ? [0, identity] : [1, identity.to_s]

        # The identity fields of every entity the domain declares.
        #
        # @param bluebook_ir [Hash] the domain's IR
        # @return [Array<String>] each entity's first identity field, such as `"sequence"`
        def entity_heads(bluebook_ir)
          bluebook_ir[:aggregates].flat_map { |aggregate| aggregate[:entities] }
                                  .map { |entity| entity[:identified_by].first.split(".").first }
        end

        # Whether a Hash is a single-field value object, `{ value: ... }`.
        #
        # @param value [Hash] a Hash from a record's state
        # @return [Boolean] true for a one-key Hash whose key is `value`
        def single_value?(value) = value.size == 1 && value.keys.first.to_s == "value"
      end
    end
  end
end
