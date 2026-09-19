module Hecks
  module QuerySpecification
    # One reading of a dotted query-field path, shared by every place that
    # would otherwise invent its own. Left to themselves they disagree: a
    # reference interpreter doing a bare `record[field]` lookup silently
    # matches nothing for a dotted path, an SQL side that splits dots but
    # judges numericness from the first nested segment only quietly
    # compares a two-level path as text, and a build seal walks the
    # declaration graph a third way. Three implementations of "what does
    # pizza.price_cents.cents mean" is two more than a language gets to
    # have.
    #
    # Two sides, deliberately in one file so they cannot drift:
    #
    #   dig(holder, field)        — value side: walk a record's held state,
    #                               segment by segment, through Value
    #                               objects and plain hashes alike.
    #   leaf_attribute / numeric? — declaration side: walk the declared
    #                               shape to the attribute a path lands on.
    #                               Callers supply value-object lookup as a
    #                               block, because an Aggregate and a
    #                               mid-build AggregateBuilder hold their
    #                               shapes differently but walk the same.
    module FieldPath
      module_function

      NUMERIC_PRIMITIVES = %w[Integer Float].freeze
      SCALAR_PRIMITIVES  = %w[String Integer Float TrueClass FalseClass].freeze

      # Reads the value a dotted field path names out of a record's held state.
      #
      # The held value a dotted field names, or nil — never a raise. The
      # first segment reads off the record (an Instance, a Value, or a
      # plain row hash); the rest read through whatever each step holds. A
      # stored nested value object is a plain hash by the time it is read
      # back, keyed by symbol in memory and by string off a wire decode,
      # so both spellings are tried — `key?` first, never `||`, because
      # `||` falls through a genuinely-stored `false` to the other
      # spelling (usually absent) and returns `nil` instead. The seal
      # admits boolean leaves (`SCALAR_PRIMITIVES` below), so a `false`
      # here is a real, held answer, not a missing one.
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

      # Reads one path segment off whatever the previous step held — a single
      # step of `dig`.
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

        # M5 — "or nil, never raise" is this method's whole contract, and
        # an Array broke it: `Array#[]` demands an Integer index, so
        # `current[segment]` (a String) raised `TypeError` straight
        # through `dig` instead of answering nil. A dotted path stepping
        # into a list_of attribute (`where "tags.name" == "x"` against a
        # bare list, rather than each element) has no single member a
        # bare index would name anyway — nil is the honest answer, the
        # same one a dangling reference or a missing key already gets.
        return nil if current.is_a?(Array)

        current[segment]
      end

      # Walks the declared shape to the attribute a dotted path lands on.
      #
      # The declared attribute a path lands on, or nil. `segments` is the
      # dotted tail — for a bare field it is empty and the root attribute
      # is its own leaf. The walk stops dead at a reference (an id is a
      # scalar; nothing nests under it) and at any member the declared
      # value object does not carry.
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute the path's first
      #   segment names; `nil` (no such attribute) answers `nil`
      # @param segments [Array<String>] the path's remaining segments, `[]` for a bare field
      # @yield looks a value object up by name in the caller's own declarations
      # @yieldparam type [String] the type name of the attribute being stepped into
      # @yieldreturn [Class<Bluebook::ValueObject>, nil] the declared shape, or `nil` when
      #   the type is not a value object the caller knows
      # @return [Bluebook::Attribute, nil] the attribute at the end of the path; `nil` when
      #   a step crosses a reference, an undeclared type or a member that does not exist
      def leaf_attribute(attribute, segments)
        current = attribute
        segments.each do |segment|
          return nil if current.nil? || current.reference?

          shape = yield(current.type.to_s)
          current = shape&.attributes&.find { |member| member.name.to_s == segment }
        end
        current
      end

      # Decides from the declared shape whether a field path holds a number.
      #
      # May an ordered comparator (lt/lte/gt/gte) land here, and may an
      # `ORDER BY` cast here numerically? A bare field keeps the one-level
      # convention every adapter already implements: a numeric primitive,
      # or a value object carrying at least one numeric member. A dotted
      # path must land on a numeric primitive itself — the convention does
      # not reach through a named path, it is the absence of one.
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute the path starts at;
      #   `nil` answers `false`
      # @param segments [Array<String>] the path's remaining segments, `[]` for a bare field
      # @yield looks a value object up by name, as for `leaf_attribute`
      # @yieldparam type [String] the type name to look up
      # @yieldreturn [Class<Bluebook::ValueObject>, nil] the declared shape, or `nil`
      # @return [Boolean] `true` when the leaf is an `Integer` or `Float`, or a bare field
      #   naming a value object with at least one such member; `false` for a list, a
      #   reference, or a path that lands nowhere
      def numeric?(attribute, segments, &)
        leaf = leaf_attribute(attribute, segments, &)
        return false if leaf.nil? || leaf.list? || leaf.reference?
        return true if NUMERIC_PRIMITIVES.include?(leaf.type.to_s)
        return false unless segments.empty?

        shape = yield(leaf.type.to_s)
        !shape.nil? && shape.attributes.any? { |member| NUMERIC_PRIMITIVES.include?(member.type.to_s) }
      end

      # Decides whether a path ends on a scalar primitive that every engine
      # compares the same way.
      #
      # A dotted path must end on a scalar member — landing on a value
      # object would hand SQL a JSON object where the reference
      # interpreter unwraps a hash, and the two would answer differently.
      #
      # @param attribute [Bluebook::Attribute, nil] the root attribute the path starts at;
      #   `nil` answers `false`
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
