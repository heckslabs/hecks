module Hecks
  module Fuzzing
    # Values deliberately the wrong shape for an attribute; the sibling of ValueGenerator.
    #
    # Refusals are answers whose wording is pinned byte-for-byte, so these probe the refusal
    # sentence rather than the happy path.
    module InvalidValueGenerator
      module_function

      # Each kind names a real confusion, not random noise.
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

      # Only the confusions that mean something for this attribute's declared type.
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
        end
      end

      # A bare scalar where a value object is declared.
      # A single-field value object accepts one, so only a multi-field one makes it a refusal.
      def scalar_for(attribute, aggregate, random:)
        value_object = aggregate.value_object(attribute.type.to_s)
        sole = value_object&.sole_attribute
        return "a bare scalar" unless sole

        # One field, so a scalar is legal; corrupt the field's own type instead.
        { sole.name.to_s => ["nested", "array"] }
      end

      # An argument the command never declares, which exercises `refuse_unknown_arguments`.
      def undeclared_argument(random:)
        name = %w[colour flavour rank note].sample(random: random)
        [name, %w[red loud third scribbled].sample(random: random)]
      end
    end
  end
end
