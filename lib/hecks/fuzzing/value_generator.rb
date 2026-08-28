require_relative "../runtime/value"

module Hecks
  module Fuzzing
    # One attribute, one value — in the exact JSON shape the hand-written
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

      EDGE_CASE_PROBABILITY = 0.2
      INVALID_MEMBER_PROBABILITY = 0.1
      INVALID_REFERENCE_PROBABILITY = 0.2
      # `Value.for_attribute` → `fields_for`'s own bare-scalar branch
      # (lib/hecks/runtime/value/coercion.rb) has accepted a bare
      # `"large"` in place of `{"value" => "large"}` for any single-field
      # value object since 86727afd — but until this generator actually
      # PRODUCES that shape, nothing exercises it: neither the adapter-
      # agreement gate nor the Rust/WASM `from_json` codegen (rust/project/
      # json_codec.rb) can ever be caught drifting on a shape they're
      # never handed.
      BARE_SCALAR_PROBABILITY = 0.2

      STRING_EDGE_CASES = [
        "", "x", "with \"quotes\"", "with, a comma", "with a \\backslash",
        "unicode héllo wörld 🎉", "x" * 200, "  leading and trailing  "
      ].freeze
      # PRD 05 (numeric-boundary-coverage) — Bignum (`2**100`, past i64's
      # own ceiling, which Ruby's own `Integer` has no such ceiling for —
      # `rust/src/kernel/json.rs`'s own `integral_i64` doc comment names
      # exactly this: a Rust kernel value CANNOT represent it, so this
      # exercises a real cross-runtime capability gap, not a Ruby-only
      # edge) and its negative twin. Both round-trip through Ruby's own
      # arithmetic/JSON cleanly (confirmed directly: `(2**100).clamp(...)`
      # and `JSON.generate(2**100)` both just work — Integer has no
      # ceiling here), so nothing in THIS runtime needed a fix for these;
      # they're included so a real generated sequence occasionally
      # produces the value at all, since nothing had, repo-wide, before.
      INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648, 2**100, -(2**100)].freeze
      # NaN and +/-Infinity — the real find (see `spec/runtime/
      # numeric_boundary_spec.rb`): `Value::Coercion#check_numeric_fields`
      # used to let all three sail through untyped-checked (each really
      # is a Float), reaching either `CommandRules::Arithmetic#clamp`
      # (raw `ArgumentError`, not a domain refusal) or `JSON.generate`
      # (`JSON::GeneratorError`, also not a domain refusal) — both fixed
      # at the source now, so these are safe to generate. -0.0 is
      # deliberately included too even though it was ALREADY safe
      # (finite, round-trips through JSON as `-0.0` cleanly) — a signed
      # zero is exactly the kind of boundary a hand-written corpus never
      # happens to type, and the fuzzer existing to cover it is the
      # point.
      FLOAT_EDGE_CASES = [0.0, -0.0, -0.5, -100.25, Float::NAN, Float::INFINITY, -Float::INFINITY].freeze
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

        # Local first, falling back to a same-chapter identity value object
        # declared on a sibling aggregate — the exact resolution
        # `Value.value_object_for` already does for a real dispatch
        # (runtime/value/coercion.rb). `safe_deposit_boxes.bluebook`'s own
        # `attribute :customer, CustomerNumber` is declared on SafeDepositBox
        # but CustomerNumber itself lives on Customer; without this fallback
        # the generator raised "does not know primitive type" for any such
        # cross-aggregate identity attribute rather than reusing the same
        # lookup the runtime relies on.
        value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
        return object_for(value_object, aggregate, random: random, known_ids: known_ids) if value_object

        primitive(attribute.type.to_s, random: random, name: "#{context} #{attribute.name}")
      end

      def object_for(value_object, aggregate, random:, known_ids:)
        fields =
          if value_object.closed_set? && !value_object.members.empty?
            return invalid_member(value_object, random: random) if random.rand < INVALID_MEMBER_PROBABILITY

            member = value_object.members.sample(random: random)
            member.to_h { |field, value| [field.to_s, value] }
          else
            value_object.attributes.to_h do |field|
              [field.name.to_s,
               value_for(field, aggregate, random: random, known_ids: known_ids, context: value_object.hecks_name)]
            end
          end

        # `fields.size == 1` — the SAME test `Behaviour::ValueObject#
        # sole_attribute` names: a genuinely single-field value object,
        # not merely "this particular closed-set member happened to pick
        # one field." Unwrapping ONLY here, not in `invalid_member`
        # above — a deliberately-wrong combination stays a Hash so its
        # own wrongness is what gets exercised, not a second, unrelated
        # shape question.
        return fields.values.first if fields.size == 1 && random.rand < BARE_SCALAR_PROBABILITY

        fields
      end

      # A combination that (almost certainly) isn't one of the closed set's
      # admitted rows — deliberately, to exercise the refusal a `one_of`
      # exists to enforce, not just its happy path.
      def invalid_member(value_object, random:)
        value_object.attributes.to_h { |field|
          [field.name.to_s, primitive(field.type.to_s, random: random, name: field.name.to_s)]
        }
      end

      # THE ID ITSELF. This minted `{"value" => id}` back when a reference was
      # stored wrapped ; the payload gate refuses that shape now, so a fuzzer
      # still emitting it would have every generated reference refused and
      # the SILENT guard would report the fuzzer broken rather than
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
