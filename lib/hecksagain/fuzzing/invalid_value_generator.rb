module Hecksagain
  module Fuzzing
    # A value that is DELIBERATELY THE WRONG SHAPE for the attribute it is handed
    # to — the sibling of ValueGenerator, which only ever builds values that satisfy
    # a declared type.
    #
    # That limit is why the fuzzer could not reach the space a hand-written
    # adversarial corpus covers. spec/parity/banking.json got there one step at a
    # time, by hand : a value object where an Integer is declared, a Float where an
    # Integer is declared, a numeral wearing quotes, an attribute missing entirely,
    # an attribute the command never declared. One of those — a hash reaching a
    # refusal message — is the exact shape that split the two runtimes, because
    # Ruby rendered it with `inspect` and Rust with JSON, and no generated value
    # could ever have produced it.
    #
    # These are expected to be REFUSED, and that is the point : a refusal is an
    # answer, and the two runtimes have to word it identically. The bugs live in
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

      def corrupt(attribute, aggregate, random:)
        kind = kinds_for(attribute, aggregate).sample(random: random)
        build(kind, attribute, aggregate, random: random)
      end

      # Only the confusions that MEAN anything for this attribute. Offering
      # `scalar_for_object` for a plain Integer would just be a second spelling of
      # `numeral_string`, and a kind that cannot be wrong for the attribute it is
      # handed teaches the corpus nothing.
      def kinds_for(attribute, aggregate)
        value_object = aggregate.value_object(attribute.type.to_s)
        return %i[scalar_for_object array_for_scalar null] if value_object
        return %i[object_for_scalar float_for_integer numeral_string array_for_scalar null] if attribute.type.to_s == "Integer"

        %i[object_for_scalar array_for_scalar boolean_for_string null]
      end

      def build(kind, attribute, aggregate, random:)
        case kind
        when :object_for_scalar then { "cents" => random.rand(1..1000) }
        when :scalar_for_object then scalar_for(attribute, aggregate, random: random)
        when :float_for_integer then random.rand(1.0..100.0).round(2)
        when :numeral_string    then random.rand(1..1000).to_s
        when :array_for_scalar  then [random.rand(1..10), random.rand(1..10)]
        when :boolean_for_string then random.rand(2).zero?
        else nil
        end
      end

      # A bare scalar where a value object is declared. A SINGLE-FIELD value object
      # legitimately accepts one (that is the standing-in rule every domain relies
      # on), so the interesting case is a value object with SEVERAL fields, where a
      # scalar cannot stand for anything and the refusal has to say so.
      def scalar_for(attribute, aggregate, random:)
        value_object = aggregate.value_object(attribute.type.to_s)
        return "a bare scalar" unless value_object && value_object.attributes.size == 1

        # One field, so a scalar is legal — corrupt the FIELD's own type instead,
        # which is still a shape the attribute cannot accept.
        { value_object.attributes.first.name.to_s => ["nested", "array"] }
      end

      # An attribute the command never declared. `refuse_unknown_arguments` is a
      # real dispatch step (Vocabulary::AggregateDispatchOrder), and nothing
      # generated had ever exercised it.
      def undeclared_argument(random:)
        name = %w[colour flavour rank note].sample(random: random)
        [name, %w[red loud third scribbled].sample(random: random)]
      end
    end
  end
end
