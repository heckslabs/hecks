module Hecks
  module Fuzzing
    # A value that is deliberately the wrong shape for the attribute it is handed
    # to — the sibling of ValueGenerator, which only ever builds values that satisfy
    # a declared type.
    #
    # That limit is why the fuzzer could not reach the space a hand-written
    # adversarial corpus covers. spec/corpus/banking.json got there one step at a
    # time, by hand : a value object where an Integer is declared, a Float where an
    # Integer is declared, a numeral wearing quotes, an attribute missing entirely,
    # an attribute the command never declared. One of those — a hash reaching a
    # refusal message — is the exact shape that exposed refusal wording drift
    # (a composite rendered with `inspect` at one site and JSON at another —
    # Rendering's whole story), and no generated value
    # could ever have produced it.
    #
    # These are expected to be refused, and that is the point : a refusal is an
    # answer, and its wording is pinned byte-for-byte. The bugs live in
    # the sentence, not in the happy path.
    module InvalidValueGenerator
      module_function

      # Each kind names a real confusion, not random noise. Ordered roughly by how
      # often this codebase has actually been bitten by it.
      KINDS = %i[
        object_for_scalar
        scalar_for_object
        float_for_integer
        numeral_string
        array_for_scalar
        boolean_for_string
        null
      ].freeze

      # Builds one value of the wrong shape for `attribute`, chosen from the
      # confusions that are actually meaningful for its declared type.
      #
      # @param attribute [Bluebook::Attribute] the attribute the corrupted value is
      #   handed to
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares
      #   `attribute` (and any value objects it references)
      # @param random [Random] the seeded RNG to draw the kind and value from
      # @return [Object] a value of the wrong shape for `attribute` — an Integer,
      #   Float, String, Array, Hash, or boolean, depending on the kind drawn
      def corrupt(attribute, aggregate, random:)
        kind = kinds_for(attribute, aggregate).sample(random: random)
        build(kind, attribute, aggregate, random: random)
      end

      # Only the confusions that mean anything for this attribute. Offering
      # `scalar_for_object` for a plain Integer would just be a second spelling of
      # `numeral_string`, and a kind that cannot be wrong for the attribute it is
      # handed teaches the corpus nothing.
      #
      # @param attribute [Bluebook::Attribute] the attribute to find applicable
      #   confusions for
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares
      #   `attribute` (and any value objects it references)
      # @return [Array<Symbol>] the subset of `KINDS` that are a real confusion for
      #   `attribute`'s declared type
      def kinds_for(attribute, aggregate)
        value_object = aggregate.value_object(attribute.type.to_s)
        return %i[scalar_for_object array_for_scalar null] if value_object
        return %i[object_for_scalar float_for_integer numeral_string array_for_scalar null] if attribute.type.to_s == "Integer"

        %i[object_for_scalar array_for_scalar boolean_for_string null]
      end

      # Builds the actual corrupted value for one already-chosen `kind`.
      #
      # @param kind [Symbol] one of `KINDS`
      # @param attribute [Bluebook::Attribute] the attribute the value will be
      #   handed to
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares
      #   `attribute` (and any value objects it references)
      # @param random [Random] the seeded RNG to draw the value from
      # @return [Object, nil] the corrupted value for `kind`; `nil` if `kind` is not
      #   one `KINDS` declares
      def build(kind, attribute, aggregate, random:)
        case kind
        when :object_for_scalar then { "cents" => random.rand(1..1000) }
        when :scalar_for_object then scalar_for(attribute, aggregate, random: random)
        when :float_for_integer then random.rand(1.0..100.0).round(2)
        when :numeral_string    then random.rand(1..1000).to_s
        when :array_for_scalar  then [random.rand(1..10), random.rand(1..10)]
        when :boolean_for_string then random.rand(2).zero?
        end
      end

      # A bare scalar where a value object is declared. A single-field value object
      # legitimately accepts one (that is the standing-in rule every domain relies
      # on), so the interesting case is a value object with several fields, where a
      # scalar cannot stand for anything and the refusal has to say so.
      # @param attribute [Bluebook::Attribute] the value-object-typed attribute to
      #   build a bare scalar for
      # @param aggregate [Bluebook::Aggregate] the aggregate that declares
      #   `attribute`'s value object
      # @param random [Random] accepted for a uniform call signature with `#build`;
      #   this method draws nothing from it
      # @return [String, Hash] `"a bare scalar"` when a scalar would legitimately be
      #   accepted (a single-field value object); otherwise a Hash corrupting the
      #   sole field's own type instead
      def scalar_for(attribute, aggregate, random:)
        value_object = aggregate.value_object(attribute.type.to_s)
        sole = value_object&.sole_attribute
        return "a bare scalar" unless sole

        # One field, so a scalar is legal — corrupt the field's own type instead,
        # which is still a shape the attribute cannot accept.
        { sole.name.to_s => ["nested", "array"] }
      end

      # An attribute the command never declared. `refuse_unknown_arguments` is a
      # real dispatch step (Vocabulary::AggregateDispatchOrder), and nothing
      # generated had ever exercised it.
      # @param random [Random] the seeded RNG to draw the name and value from
      # @return [Array(String, String)] a `[name, value]` pair naming an argument
      #   no command declares
      def undeclared_argument(random:)
        name = %w[colour flavour rank note].sample(random: random)
        [name, %w[red loud third scribbled].sample(random: random)]
      end
    end
  end
end
