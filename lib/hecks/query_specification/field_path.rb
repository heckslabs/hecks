module Hecks
  module QuerySpecification
    # ONE reading of a dotted query-field path, shared by every place that
    # used to invent its own. The reference interpreter did a bare
    # `record[field]` lookup (a dotted path silently matched nothing), the
    # SQL side split dots but judged numericness from the FIRST nested
    # segment only (a two-level path quietly compared text), and the build
    # seal walked the declaration graph a third way. Three
    # implementations of "what does pizza.price_cents.cents mean" is two
    # more than a language gets to have.
    #
    # Two sides, deliberately in one file so they cannot drift:
    #
    #   dig(holder, field)        — VALUE side: walk a record's held state,
    #                               segment by segment, through Value
    #                               objects and plain hashes alike.
    #   leaf_attribute / numeric? — DECLARATION side: walk the declared
    #                               shape to the attribute a path lands on.
    #                               Callers supply value-object lookup as a
    #                               block, because an Aggregate and a
    #                               mid-build AggregateBuilder hold their
    #                               shapes differently but walk the same.
    module FieldPath
      module_function

      NUMERIC_PRIMITIVES = %w[Integer Float].freeze
      SCALAR_PRIMITIVES  = %w[String Integer Float TrueClass FalseClass].freeze

      # The held value a dotted field names, or nil — never a raise. The
      # first segment reads off the record (an Instance, a Value, or a
      # plain row hash); the rest read through whatever each step holds. A
      # stored nested value object is a plain hash by the time it is read
      # back, keyed by symbol in memory and by string off a wire decode,
      # so both spellings are tried — `key?` first, never `||`, because
      # `||` falls through a genuinely-stored `false` to the OTHER
      # spelling (usually absent) and returns `nil` instead. The seal
      # admits boolean leaves (`SCALAR_PRIMITIVES` below), so a `false`
      # here is a real, held answer, not a missing one.
      def dig(holder, field)
        return nil if field.nil?

        field.to_s.split(".").reduce(holder) { |current, segment| read(current, segment) }
      end

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
        # INTO a list_of attribute (`where "tags.name" == "x"` against a
        # bare list, rather than each element) has no single member a
        # bare index would name anyway — nil is the honest answer, the
        # same one a dangling reference or a missing key already gets.
        return nil if current.is_a?(Array)

        current[segment]
      end

      # The declared attribute a path lands on, or nil. `segments` is the
      # dotted tail — for a bare field it is empty and the root attribute
      # is its own leaf. The walk stops dead at a reference (an id is a
      # scalar; nothing nests under it) and at any member the declared
      # value object does not carry.
      def leaf_attribute(attribute, segments)
        current = attribute
        segments.each do |segment|
          return nil if current.nil? || current.reference?

          shape = yield(current.type.to_s)
          current = shape&.attributes&.find { |member| member.name.to_s == segment }
        end
        current
      end

      # May an ordered comparator (lt/lte/gt/gte) land here, and may an
      # ORDER BY cast here numerically? A bare field keeps the one-level
      # convention every adapter already implements: a numeric primitive,
      # or a value object carrying at least one numeric member. A dotted
      # path must land on a numeric primitive itself — the convention does
      # not reach through a named path, it IS the absence of one.
      def numeric?(attribute, segments, &)
        leaf = leaf_attribute(attribute, segments, &)
        return false if leaf.nil? || leaf.list? || leaf.reference?
        return true if NUMERIC_PRIMITIVES.include?(leaf.type.to_s)
        return false unless segments.empty?

        shape = yield(leaf.type.to_s)
        !shape.nil? && shape.attributes.any? { |member| NUMERIC_PRIMITIVES.include?(member.type.to_s) }
      end

      # A dotted path must end on a SCALAR member — landing on a value
      # object would hand SQL a JSON object where the reference
      # interpreter unwraps a hash, and the two would answer differently.
      def scalar_leaf?(attribute, segments, &)
        leaf = leaf_attribute(attribute, segments, &)
        !leaf.nil? && !leaf.list? && !leaf.reference? && SCALAR_PRIMITIVES.include?(leaf.type.to_s)
      end
    end
  end
end
