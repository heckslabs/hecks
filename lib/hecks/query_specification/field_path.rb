module Hecks
  module QuerySpecification
    # One reading of a dotted query-field path, shared by every caller that walks one.
    #
    # `dig` walks a record's held state; `leaf_attribute`/`numeric?` walk the declared shape.
    module FieldPath
      module_function

      NUMERIC_PRIMITIVES = %w[Integer Float].freeze
      INTEGER_PRIMITIVES = %w[Integer].freeze
      BOOLEAN_PRIMITIVES = %w[TrueClass FalseClass].freeze
      SCALAR_PRIMITIVES  = %w[String Integer Float TrueClass FalseClass].freeze

      # Reads the value a dotted field path names out of a record's held state.
      #
      # Nested value objects come back as hashes keyed by symbol (memory) or string (wire),
      # so both are tried, `key?` first: `||` would turn a stored `false` into `nil`.
      #
      # @param holder [Runtime::Instance, Runtime::Value, Hash, nil] the record, value
      #   object or row Hash the first segment is read from
      # @param field [String, Symbol, nil] the path, segments separated by `.`, such as
      #   `"price.cents"`; a bare field name is a one-segment path
      # @return [Object, nil] the value held at the end of the path; `nil` when `field` is
      #   `nil`, a segment is absent, or a step lands on `nil` or an Array
      def dig(holder, field)
        return nil if field.nil?

        field.to_s.split(".").reduce(holder) { |current, segment| read(current, segment) }
      end

      # Reads one path segment off whatever the previous step held.
      #
      # @param current [Runtime::Instance, Runtime::Value, Hash, Array, nil] the value the
      #   walk has reached; a Hash is tried by Symbol key, then by String key
      # @param segment [String] one segment of the dotted path
      # @return [Object, nil] the member named `segment`; `nil` when `current` is `nil` or
      #   an Array, or holds no such member
      def read(current, segment)
        return nil if current.nil?

        if current.is_a?(Hash)
          sym = segment.to_sym
          return current.key?(sym) ? current[sym] : current[segment]
        end

        # A list has no single member a String index could name; `Array#[]` would raise
        # TypeError, breaking dig's "nil, never raise" contract.
        return nil if current.is_a?(Array)

        current[segment]
      end

      # Walks the declared shape to the attribute a dotted path lands on.
      #
      # `segments` is the dotted tail, empty for a bare field. The walk stops at a reference
      # and at any member the declared value object does not carry.
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute; `nil` answers `nil`
      # @param segments [Array<String>] the path's remaining segments, `[]` for a bare field
      # @yield looks a value object up by name in the caller's own declarations
      # @yieldparam type [String] the type name being stepped into
      # @yieldreturn [Class<Bluebook::ValueObject>, nil] the declared shape, or `nil`
      # @return [Bluebook::Attribute, nil] the leaf; `nil` when a step crosses a reference or
      #   lands on an undeclared type or missing member
      def leaf_attribute(attribute, segments)
        current = attribute
        segments.each do |segment|
          return nil if current.nil? || current.reference?

          shape = yield(current.type.to_s)
          current = shape&.attributes&.find { |member| member.name.to_s == segment }
        end
        current
      end

      # Decides from the declared shape whether a field path lands on one of `primitives`.
      #
      # A bare field matches if it is itself one of `primitives`, or a value object with
      # exactly one member typed as one; a dotted path must land on a matching primitive
      # directly (no reaching further into a value object it lands on).
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute; `nil` answers `false`
      # @param segments [Array<String>] the path's remaining segments, `[]` for a bare field
      # @param primitives [Array<String>] the primitive type names that count as a match
      # @yield looks a value object up by name, as for `leaf_attribute`
      # @yieldparam type [String] the type name to look up
      # @yieldreturn [Class<Bluebook::ValueObject>, nil] the declared shape, or `nil`
      # @return [Boolean] `false` for a list, a reference, or a path that lands nowhere
      def matches_primitive?(attribute, segments, primitives, &)
        leaf = leaf_attribute(attribute, segments, &)
        return false if leaf.nil? || leaf.list? || leaf.reference?
        return true if primitives.include?(leaf.type.to_s)
        return false unless segments.empty?

        shape = yield(leaf.type.to_s)
        !shape.nil? && shape.attributes.any? { |member| primitives.include?(member.type.to_s) }
      end

      # @return [Boolean] whether a field path holds a number (`Integer` or `Float`)
      def numeric?(attribute, segments, &) = matches_primitive?(attribute, segments, NUMERIC_PRIMITIVES, &)

      # @return [Boolean] whether a field path holds specifically an `Integer` (not `Float`)
      def integer?(attribute, segments, &) = matches_primitive?(attribute, segments, INTEGER_PRIMITIVES, &)

      # @return [Boolean] whether a field path holds a `TrueClass`/`FalseClass`
      def boolean?(attribute, segments, &) = matches_primitive?(attribute, segments, BOOLEAN_PRIMITIVES, &)

      # Decides whether a path ends on a scalar primitive every engine compares alike.
      #
      # A dotted path landing on a value object would give SQL a JSON object where the
      # reference interpreter unwraps a hash, so the two would disagree.
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute; `nil` answers `false`
      # @param segments [Array<String>] the path's remaining segments, `[]` for a bare field
      # @yield looks a value object up by name, as for `leaf_attribute`
      # @yieldparam type [String] the type name to look up
      # @yieldreturn [Class<Bluebook::ValueObject>, nil] the declared shape, or `nil`
      # @return [Boolean] `true` when the leaf is a non-list, non-reference attribute typed
      #   `String`, `Integer`, `Float`, `TrueClass` or `FalseClass`
      def scalar_leaf?(attribute, segments, &)
        leaf = leaf_attribute(attribute, segments, &)
        !leaf.nil? && !leaf.list? && !leaf.reference? && SCALAR_PRIMITIVES.include?(leaf.type.to_s)
      end
    end
  end
end
