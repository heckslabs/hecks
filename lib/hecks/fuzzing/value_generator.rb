require_relative "../runtime/value"

module Hecks
  module Fuzzing
    # One attribute, one value — in the exact JSON shape the hand-written
    # corpus already uses (a value-object-typed attribute is a nested hash keyed
    # by its own field names ; a reference is the bare ID of the head it points
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
    # past its own invariant (`address.include?("@")`, `currency.size == 3`) —
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
      # produces that shape, nothing exercises it: neither the adapter-
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
      # exactly this: a Rust kernel value cannot represent it, so this
      # exercises a real cross-runtime capability gap, not a Ruby-only
      # edge) and its negative twin. Both round-trip through Ruby's own
      # arithmetic/JSON cleanly (confirmed directly: `(2**100).clamp(...)`
      # and `JSON.generate(2**100)` both just work — Integer has no
      # ceiling here), so nothing in this runtime needed a fix for these;
      # they're included so a real generated sequence occasionally
      # produces the value at all, since nothing had, repo-wide, before.
      INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648, 2**100, -(2**100)].freeze
      # BUG#35 (QualityControl QA ledger, `lease-clock-json-precision`) —
      # a Bignum edge case (`2**100`, above) landing on an Integer-typed
      # clock or count reading fires the already-catalogued `Json::Num`/
      # f64 precision-loss class (`rust/src/kernel/json.rs`'s
      # `parse_number` parses every number through `s.parse::<f64>()`
      # before any target-type conversion runs, and `Json::Num` is a
      # plain `f64` end to end — see that file's own header) on a new
      # site every time a new clock/count-shaped field is authored,
      # without adding any new coverage: both engines already refuse
      # (`TypeMismatch`, out of `i64` range either way) for this shape,
      # `tenant_ledger`'s own NOTES.md already logged the identical class
      # on a stored money attribute, and `spec/support/
      # rust_conformance_helpers.rb`'s own `reduce_to_wire_precision`
      # already documents and normalizes past the wire format's own loss
      # for a query's echoed args. An exact-integer Rust JSON
      # deserialization path was considered and rejected as this
      # generator's own fix instead: `Json::Num(f64)` is pattern-matched
      # throughout `rust/src/kernel` (query_comparators.rs,
      # query_ordering.rs, read_model.rs, named_query.rs, this kernel's
      # own `Fielded` impl, arithmetic overflow checks) and emitted by
      # codegen (`rust/project/reactions.rb`, `rust/codegen/src/
      # reactions.rs`) — adding a second, exact-integer numeric variant
      # would mean auditing and updating every one of those sites, a
      # refactor of the JSON layer itself, not a one-domain fix (exactly
      # the ledger's own stated concern: "risks affecting every other
      # domain's large-integer handling"). So instead, per the ledger's
      # own sanctioned fallback: an Integer-typed field whose name reads
      # as a clock or a count is capped to a narrower, still-real
      # edge-case pool below (still exercises the ordinary i32
      # boundaries, just never a value past f64's own 2**53 exact-
      # integer ceiling) — every other Integer-typed field (a money
      # amount, an identity sequence, anything not clock/count-shaped)
      # still draws from the full `INTEGER_EDGE_CASES` pool above,
      # unchanged.
      SAFE_INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648].freeze
      # Matched against the value object's own declared name plus the
      # attribute's own name (`value_for`'s `"#{context} #{attribute.
      # name}"`, e.g. "LeaseInstant value", "RetryCount value") — a
      # clock reading ("instant"/"clock"/"expir(es/y)"/"ttl"/"now"/
      # "timestamp"/"epoch") or a quantity capped by a policy ("count").
      # Deliberately narrow: matches the ledger's own "clock/count"
      # wording exactly, not every plausibly-large-looking name (an
      # "amount"/"cents"/"sequence" field is not clock/count-shaped and
      # keeps the full Bignum edge-case pool).
      CLOCK_OR_COUNT_NAME_PATTERN = /clock|instant|expir|ttl|\bnow\b|timestamp|epoch|count/i
      # NaN and +/-Infinity — the real find (see `spec/runtime/
      # numeric_boundary_spec.rb`): `Value::Coercion#check_numeric_fields`
      # type-checks all three (each really is a Float) before they can
      # reach either `CommandRules::Arithmetic#clamp` (raw
      # `ArgumentError`, not a domain refusal) or `JSON.generate`
      # (`JSON::GeneratorError`, also not a domain refusal) — both fixed
      # at the source, so these are safe to generate. -0.0 is
      # deliberately included too even though it was already safe
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
      #
      # @param attribute [Bluebook::Attribute] the attribute to generate a value for
      # @param aggregate [Bluebook::Aggregate] the aggregate `attribute` belongs to;
      #   resolves a same-chapter identity value object
      # @param random [Random] the RNG driving every draw this call makes
      # @param known_ids [Hash{String => Array<String>}] known real ids, keyed by
      #   aggregate or entity name; a reference draws from this pool
      # @param context [String, nil] the enclosing value object's own declared name,
      #   for name-aware primitive generation; nil at the top level
      # @return [String, Integer, Float, Boolean, Hash] a JSON-safe value in the corpus's
      #   own shape: a nested Hash for a value-object-typed attribute, a bare id String
      #   for a reference, or a plain primitive otherwise
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

      # Generates a nested value for a whole value object: a random admitted
      # row for a closed set, or a value per declared attribute otherwise —
      # occasionally unwrapped to a bare scalar for a genuinely single-field
      # value object.
      #
      # @param value_object [Bluebook::ValueObject] the value object to generate a value for
      # @param aggregate [Bluebook::Aggregate] the aggregate `value_object` is reached
      #   from, forwarded to nested `value_for` calls
      # @param random [Random] the RNG driving every draw this call makes
      # @param known_ids [Hash{String => Array<String>}] known real ids, keyed by
      #   aggregate or entity name, forwarded to nested `value_for` calls
      # @return [Hash, Object] `{field name => value, ...}` for each declared attribute
      #   or closed-set member; unwrapped to that lone value directly when the value
      #   object has exactly one field and the bare-scalar draw hits
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

        # `fields.size == 1` — the same test `Behaviour::ValueObject#
        # sole_attribute` names: a genuinely single-field value object,
        # not merely "this particular closed-set member happened to pick
        # one field." Unwrapping only here, not in `invalid_member`
        # above — a deliberately-wrong combination stays a Hash so its
        # own wrongness is what gets exercised, not a second, unrelated
        # shape question.
        return fields.values.first if fields.size == 1 && random.rand < BARE_SCALAR_PROBABILITY

        fields
      end

      # A combination that (almost certainly) isn't one of the closed set's
      # admitted rows — deliberately, to exercise the refusal a `one_of`
      # exists to enforce, not just its happy path.
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

      # The ID itself, unwrapped: the payload gate refuses a reference stored
      # wrapped as `{"value" => id}`, so a fuzzer emitting that shape would
      # have every generated reference refused and the silent guard would
      # report the fuzzer broken rather than the runtime.
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
        return "missing-#{random.bytes(4).unpack1('H*')}" if pool.empty? || random.rand < INVALID_REFERENCE_PROBABILITY

        pool.sample(random: random)
      end

      # Generates a value for one Ruby-primitive-typed attribute.
      #
      # @param type_name [String] the primitive type name: `"String"`, `"Integer"`,
      #   `"Float"`, `"TrueClass"`, or `"FalseClass"`
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
        when "TrueClass", "FalseClass" then random.rand(2).zero?
        else raise ArgumentError, "ValueGenerator does not know primitive type #{type_name.inspect}"
        end
      end

      # Generates a String value, name-aware for the couple of shapes that
      # need to look a specific way to get past their own invariant.
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

      # Generates an Integer value, skewed positive.
      #
      # Skewed positive : `cents.positive?`/`!cents.negative?`-style
      # invariants are common across this codebase's example domains, and a
      # sequence that can never get past one never reaches the state a deeper
      # bug would need. Zero and negative are still real, reachable outcomes —
      # via the edge-case pool, deliberately, not by starving them entirely.
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

      # Reports whether a field name reads as a clock reading or a
      # policy-capped count, per `CLOCK_OR_COUNT_NAME_PATTERN`'s own comment.
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

      # The bare scalar a generated identity value stands for, for recording into
      # `known_ids`. An identity is declared as a value object, so this opens one ;
      # a reference pointing at this record is already that scalar and needs no
      # opening at all — the two are different readings, not interchangeable.
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
        "gen-#{random.bytes(4).unpack1('H*')}"
      end
    end
  end
end
