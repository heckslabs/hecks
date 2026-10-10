require_relative "../runtime/value"

module Hecks
  module Fuzzing
    # Generates one JSON-safe value per attribute, in the shape the hand-written corpus uses.
    # Edge cases are frequent but not dominant; name-aware shapes reach deep state.
    module ValueGenerator
      module_function

      EDGE_CASE_PROBABILITY = 0.2
      INVALID_MEMBER_PROBABILITY = 0.1
      INVALID_REFERENCE_PROBABILITY = 0.2
      # Exercises the bare-scalar form a single-field value object accepts.
      BARE_SCALAR_PROBABILITY = 0.2

      STRING_EDGE_CASES = [
        "", "x", "with \"quotes\"", "with, a comma", "with a \\backslash",
        "unicode héllo wörld 🎉", "x" * 200, "  leading and trailing  "
      ].freeze
      # Includes Bignums past i64, which a Rust kernel value cannot represent (`kernel/json.rs`).
      INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648, 2**100, -(2**100)].freeze
      # Clock- and count-shaped fields stay under f64's exact-integer ceiling: `Json::Num` is an
      # f64, so a Bignum there only re-hits the known precision-loss class.
      SAFE_INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648].freeze
      # Tested against the value object's name plus the attribute's name; deliberately narrow, so
      # "amount"/"cents"/"sequence" keep the full Bignum pool.
      CLOCK_OR_COUNT_NAME_PATTERN = /clock|instant|expir|ttl|\bnow\b|timestamp|epoch|count/i
      # Signed zero and finite magnitudes. A sequence reaches the Rust kernel as JSON, which cannot
      # write NaN or infinity, so a non-finite draw made the encoder raise before either runtime
      # ran it; `Value`'s refusal of one is pinned by spec/runtime/numeric_boundary_spec.rb.
      FLOAT_EDGE_CASES = [0.0, -0.0, -0.5, -100.25, 1.0e100, -1.0e100, 1.0e-100].freeze
      WORDS = %w[alpha bravo charlie delta echo foxtrot golf hotel india juliet].freeze
      CURRENCY_CODES = %w[USD EUR GBP JPY].freeze

      # The value for one command/query/value-object attribute.
      #
      # `context` carries the enclosing value object's name, since `EmailAddress`'s `address` field
      # only looks email-shaped through the name of the object around it.
      #
      # @param attribute [Bluebook::Attribute] the attribute to generate a value for
      # @param aggregate [Bluebook::Aggregate] the aggregate `attribute` belongs to
      # @param random [Random] the RNG driving every draw this call makes
      # @param known_ids [Hash{String => Array<String>}] real ids by aggregate or entity name
      # @param context [String, nil] the enclosing value object's name; nil at the top level
      # @return [String, Integer, Float, Boolean, Hash] a JSON-safe value: a nested Hash for a
      #   value-object type, a bare id String for a reference, a primitive otherwise
      def value_for(attribute, aggregate, random:, known_ids: {}, context: nil)
        return reference_value(attribute, random: random, known_ids: known_ids) if attribute.reference?

        # Same lookup the runtime uses: an identity value object may live on a sibling aggregate.
        value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
        return object_for(value_object, aggregate, random: random, known_ids: known_ids) if value_object

        primitive(attribute.type.to_s, random: random, name: "#{context} #{attribute.name}")
      end

      # Generates a nested value for a whole value object: a random admitted
      # row for a closed set, or a value per declared attribute otherwise —
      # occasionally unwrapped to a bare scalar for a genuinely single-field
      # value object.
      #
      # @param value_object [Bluebook::ValueObject] the value object to generate a value for
      # @param aggregate [Bluebook::Aggregate] the aggregate `value_object` is reached from
      # @param random [Random] the RNG driving every draw this call makes
      # @param known_ids [Hash{String => Array<String>}] real ids by aggregate or entity name
      # @return [Hash, Object] `{field name => value, ...}`, or the lone value when the
      #   value object has one field and the bare-scalar draw hits
      def object_for(value_object, aggregate, random:, known_ids:)
        if value_object.closed_set? && !value_object.members.empty?
          return invalid_member(value_object, random: random) if random.rand < INVALID_MEMBER_PROBABILITY

          return bare_or_hash(admitted_member(value_object, random), random)
        end

        bare_or_hash(attribute_fields(value_object, aggregate, random: random, known_ids: known_ids), random)
      end

      # One admitted row of a closed set, keyed by field name.
      def admitted_member(value_object, random)
        value_object.members.sample(random: random).to_h { |field, value| [field.to_s, value] }
      end

      # A value per declared attribute, keyed by attribute name; a list attribute is an array of
      # up to three members, which is the shape its declaration asks for.
      def attribute_fields(value_object, aggregate, random:, known_ids:)
        value_object.attributes.to_h do |field|
          draw = -> { value_for(field, aggregate, random: random, known_ids: known_ids, context: value_object.hecks_name) }
          [field.name.to_s, field.list? ? list_members(field, aggregate, random, &draw) : draw.call]
        end
      end

      # Up to three members of a list held by a value object, each kept an object: a single-field
      # member sent as its bare scalar is the one-field shorthand the list's own arguments draw.
      def list_members(field, aggregate, random)
        nested = Runtime::Value.value_object_for(aggregate, field.type.to_s)
        sole = nested.attributes.first.name.to_s if nested && nested.attributes.size == 1
        Array.new(random.rand(0..3)) do
          member = yield
          sole && !member.is_a?(Hash) ? { sole => member } : member
        end
      end

      # Unwrap only a genuinely single-field value object, never `invalid_member`: a wrong
      # combination stays a Hash so its wrongness is what gets exercised.
      def bare_or_hash(fields, random)
        return fields.values.first if fields.size == 1 && random.rand < BARE_SCALAR_PROBABILITY

        fields
      end

      # A combination that (almost certainly) isn't one of the closed set's admitted rows,
      # to exercise the refusal a `one_of` exists to enforce.
      #
      # @param value_object [Bluebook::ValueObject] the closed-set value object to
      #   generate a non-admitted combination for
      # @param random [Random] the RNG driving every draw this call makes
      # @return [Hash] `{field name => value, ...}` for every declared attribute, each
      #   drawn independently rather than sampled from an admitted row
      def invalid_member(value_object, random:)
        value_object.attributes.to_h do |field|
          [field.name.to_s, primitive(field.type.to_s, random: random, name: field.name.to_s)]
        end
      end

      # The ID itself, unwrapped: the payload gate refuses `{"value" => id}` for a reference.
      #
      # @param attribute [Bluebook::Attribute] the reference-typed attribute to
      #   generate a value for
      # @param random [Random] the RNG driving every draw this call makes
      # @param known_ids [Hash{String => Array<String>}] known real ids, keyed by
      #   aggregate or entity name; looked up under `attribute.type.target_name`
      # @return [String] a real id drawn from the matching pool most of the time; a
      #   fabricated `"missing-..."` id when the pool is empty or the invalid-reference
      #   draw hits
      def reference_value(attribute, random:, known_ids:)
        pool = known_ids[attribute.type.target_name.to_s] || []
        return "missing-#{random.bytes(4).unpack1("H*")}" if pool.empty? || random.rand < INVALID_REFERENCE_PROBABILITY

        pool.sample(random: random)
      end

      # Generates a value for one Ruby-primitive-typed attribute.
      #
      # @param type_name [String] the primitive type name: `"String"`, `"Integer"`,
      #   `"Float"`, `"Boolean"`, `"TrueClass"`, or `"FalseClass"`
      # @param random [Random] the RNG driving every draw this call makes
      # @param name [String, nil] a name hint (attribute name, optionally
      #   context-prefixed) that draws an email-/currency-shaped string or a
      #   clock/count-shaped integer
      # @return [String, Integer, Float, Boolean] a value of the type `type_name` names
      # @raise [ArgumentError] if `type_name` names anything else
      def primitive(type_name, random:, name: nil)
        case type_name
        when "String"  then string_value(random, name: name)
        when "Integer" then integer_value(random, name: name)
        when "Float"   then float_value(random)
        when "TrueClass", "FalseClass", "Boolean" then random.rand(2).zero?
        else raise ArgumentError, "ValueGenerator does not know primitive type #{type_name.inspect}"
        end
      end

      # Generates a String value, name-aware for shapes an invariant needs (email, currency).
      #
      # @param random [Random] the RNG driving every draw this call makes
      # @param name [String, nil] a name hint; an `"email"` or `"currency"` match
      #   draws a shaped value instead of random words
      # @return [String] an edge-case string, an email address, a currency code, or
      #   1-3 random words joined by spaces
      def string_value(random, name: nil)
        return STRING_EDGE_CASES.sample(random: random) if random.rand < EDGE_CASE_PROBABILITY
        return email_value(random) if name&.match?(/email/i)
        return CURRENCY_CODES.sample(random: random) if name&.match?(/currency/i)

        Array.new(random.rand(1..3)) { WORDS.sample(random: random) }.join(" ")
      end

      # Generates a fabricated, syntactically valid email address.
      #
      # @param random [Random] the RNG driving every draw this call makes
      # @return [String] a `"word@word.example"` address
      def email_value(random)
        "#{WORDS.sample(random: random)}@#{WORDS.sample(random: random)}.example"
      end

      # Generates an Integer value, skewed positive so `positive?`-style invariants are reachable.
      # Zero and negatives still come through the edge-case pool.
      #
      # @param random [Random] the RNG driving every draw this call makes
      # @param name [String, nil] a name hint; a clock/count-shaped match narrows
      #   the edge-case pool to `SAFE_INTEGER_EDGE_CASES`
      # @return [Integer] an edge-case integer sometimes, else a random count in 1..1000
      def integer_value(random, name: nil)
        if random.rand < EDGE_CASE_PROBABILITY
          pool = clock_or_count_shaped?(name) ? SAFE_INTEGER_EDGE_CASES : INTEGER_EDGE_CASES
          return pool.sample(random: random)
        end

        random.rand(1..1000)
      end

      # Reports whether a field name reads as a clock reading or a policy-capped count.
      #
      # @param name [String, nil] the name to test
      # @return [Boolean] true if `name` matches the clock/count name pattern
      def clock_or_count_shaped?(name)
        name.to_s.match?(CLOCK_OR_COUNT_NAME_PATTERN)
      end

      # Generates a Float value.
      #
      # @param random [Random] the RNG driving every draw this call makes
      # @return [Float] an edge-case float sometimes, else a random value in
      #   0.01..1000.0, rounded to 2 decimal places
      def float_value(random)
        return FLOAT_EDGE_CASES.sample(random: random) if random.rand < EDGE_CASE_PROBABILITY

        random.rand(0.01..1000.0).round(2)
      end

      # The bare scalar a generated identity value stands for, for recording into `known_ids`.
      # A reference to this record is already that scalar; the two are not interchangeable.
      #
      # @param identity_value [Hash, Object] a generated identity value, as `value_for`
      #   produced it — a Hash for a multi-field value object, or the bare scalar already
      #   for a single-field one
      # @return [String] the identity's bare scalar, stringified
      def scalar_of(identity_value)
        identity_value.is_a?(Hash) ? identity_value.values.first.to_s : identity_value.to_s
      end

      # Generates a fabricated id unrelated to anything `known_ids` tracks.
      #
      # @param random [Random] the RNG driving every draw this call makes
      # @return [String] a `"gen-"`-prefixed id with 8 random hex characters
      def random_id(random)
        "gen-#{random.bytes(4).unpack1("H*")}"
      end
    end
  end
end
