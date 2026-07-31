module Hecksagain
  module Fuzzing
    # One attribute, one value — in the exact JSON shape the hand-written parity
    # corpus already uses (a value-object-typed attribute is a nested hash keyed
    # by its own field names ; a reference is the BARE ID of the head it points
    # at, because that is what a reference is). Everything
    # returned is a plain, JSON-safe Ruby value : String keys throughout, never
    # symbols, so a generated step can be dumped straight to JSON.
    #
    # Biased toward the edge cases a hand-written corpus tends to under-sample —
    # empty strings, quotes, commas, unicode, zero, negative numbers — because
    # `marks.rb` names literal-encoding loss "the largest family of bug in this
    # codebase," and a fixed corpus of a few dozen examples rarely happens to
    # exercise the boundary that actually breaks. But mostly not : an attribute
    # named `email`/`currency` almost always needs a specific shape just to get
    # PAST its own invariant (`address.include?("@")`, `currency.size == 3`) —
    # banking's very first fuzz run never got past Customer.Register, because
    # no plain random word ever contains "@". Reaching deep state matters more
    # than edge-casing every single field every single time, so the "normal"
    # path is now name-aware for the couple of shapes that are genuinely
    # common across domains, and edge cases stay real but less frequent.
    module ValueGenerator
      module_function

      EDGE_CASE_PROBABILITY    = 0.2
      INVALID_MEMBER_PROBABILITY = 0.1
      INVALID_REFERENCE_PROBABILITY = 0.2

      STRING_EDGE_CASES = [
        "", "x", "with \"quotes\"", "with, a comma", "with a \\backslash",
        "unicode héllo wörld 🎉", "x" * 200, "  leading and trailing  "
      ].freeze
      INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648].freeze
      FLOAT_EDGE_CASES   = [0.0, -0.5, -100.25].freeze
      WORDS = %w[alpha bravo charlie delta echo foxtrot golf hotel india juliet].freeze
      CURRENCY_CODES = %w[USD EUR GBP JPY].freeze

      # The value for one command/query/value-object attribute. `known_ids` is
      # `{aggregate_or_entity_name => [scalar id, ...]}`, supplied by the
      # sequence generator — a reference draws a real id from it most of the
      # time and a fabricated one sometimes, to exercise NotFound as often as
      # the happy path.
      # `context` carries the enclosing value object's own declared name down
      # into a nested primitive field — `EmailAddress`'s `address` field is
      # what actually needs to look email-shaped, but the field itself is
      # just named "address"; the VO's own name is where "email" lives. A
      # combined hint catches both spellings without needing to guess which
      # level a domain happened to name the thing on.
      def value_for(attribute, aggregate, random:, known_ids: {}, context: nil)
        return reference_value(attribute, random: random, known_ids: known_ids) if attribute.reference?

        value_object = aggregate.value_object(attribute.type.to_s)
        return object_for(value_object, aggregate, random: random, known_ids: known_ids) if value_object

        primitive(attribute.type.to_s, random: random, name: "#{context} #{attribute.name}")
      end

      def object_for(value_object, aggregate, random:, known_ids:)
        if value_object.closed_set? && !value_object.members.empty?
          return invalid_member(value_object, random: random) if random.rand < INVALID_MEMBER_PROBABILITY

          member = value_object.members.sample(random: random)
          return member.to_h { |field, value| [field.to_s, value] }
        end

        value_object.attributes.to_h do |field|
          [field.name.to_s, value_for(field, aggregate, random: random, known_ids: known_ids, context: value_object.hecks_name)]
        end
      end

      # A combination that (almost certainly) isn't one of the closed set's
      # admitted rows — deliberately, to exercise the refusal a `one_of`
      # exists to enforce, not just its happy path.
      def invalid_member(value_object, random:)
        value_object.attributes.to_h { |field| [field.name.to_s, primitive(field.type.to_s, random: random, name: field.name.to_s)] }
      end

      # THE ID ITSELF. This minted `{"value" => id}` back when a reference was
      # stored wrapped ; the payload gate refuses that shape now, so a fuzzer
      # still emitting it would have every generated reference refused and
      # `bin/parity`'s SILENT guard would report the fuzzer broken rather than
      # the runtime.
      def reference_value(attribute, random:, known_ids:)
        pool = known_ids[attribute.type.target_name.to_s] || []
        return "missing-#{random.bytes(4).unpack1('H*')}" if pool.empty? || random.rand < INVALID_REFERENCE_PROBABILITY

        pool.sample(random: random)
      end

      def primitive(type_name, random:, name: nil)
        case type_name
        when "String"  then string_value(random, name: name)
        when "Integer" then integer_value(random)
        when "Float"   then float_value(random)
        when "TrueClass", "FalseClass" then random.rand(2).zero?
        else raise ArgumentError, "ValueGenerator does not know primitive type #{type_name.inspect}"
        end
      end

      def string_value(random, name: nil)
        return STRING_EDGE_CASES.sample(random: random) if random.rand < EDGE_CASE_PROBABILITY
        return email_value(random) if name&.match?(/email/i)
        return CURRENCY_CODES.sample(random: random) if name&.match?(/currency/i)

        Array.new(random.rand(1..3)) { WORDS.sample(random: random) }.join(" ")
      end

      def email_value(random)
        "#{WORDS.sample(random: random)}@#{WORDS.sample(random: random)}.example"
      end

      # Skewed positive : `cents.positive?`/`!cents.negative?`-style
      # invariants are common across this codebase's example domains, and a
      # sequence that can never get past one never reaches the state a deeper
      # bug would need. Zero and negative are still real, reachable outcomes —
      # via the edge-case pool, deliberately, not by starving them entirely.
      def integer_value(random)
        return INTEGER_EDGE_CASES.sample(random: random) if random.rand < EDGE_CASE_PROBABILITY

        random.rand(1..1000)
      end

      def float_value(random)
        return FLOAT_EDGE_CASES.sample(random: random) if random.rand < EDGE_CASE_PROBABILITY

        random.rand(0.01..1000.0).round(2)
      end

      # The bare scalar a generated IDENTITY value stands for, for recording into
      # `known_ids`. An identity is declared as a value object, so this opens one ;
      # a reference pointing at this record is already that scalar and needs no
      # opening at all. The two used to be the same reading and are not any more.
      def scalar_of(identity_value)
        identity_value.is_a?(Hash) ? identity_value.values.first.to_s : identity_value.to_s
      end

      def random_id(random)
        "gen-#{random.bytes(4).unpack1('H*')}"
      end
    end
  end
end
