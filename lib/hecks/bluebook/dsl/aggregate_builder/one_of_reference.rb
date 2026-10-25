module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # `reference_to one_of(A, B), as: :subject`: a tagged reference to one of a closed union of
        # aggregates (ADR 0127), minted from words the language already has. The aggregate gains a
        # closed set of the variants' names and a value object holding the chosen `type` and `id`.
        module OneOfReference
          private

          # Mints the closed set, the tagged value object and the attribute for one union.
          #
          # @param union [AttributeCollector::OneOf] the variants, written as bare constants
          # @param as [Symbol, nil] the attribute's name; required, since a union has no one name
          # @param optional [Boolean] whether the reference may be absent
          # @return [void]
          # @raise [Bluebook::DSL::Malformed] without `as:`, or with under two distinct variants
          def one_of_reference(union, as:, optional:)
            variants = union.values.map { |variant| Naming.demodulise(variant).to_s }
            refuse_unfit_union!(variants, as)
            install_union_shapes(Naming.pascal(as), variants)
            refuse_duplicate_attribute!(as.to_sym)
            attributes << Attribute.new(name: as, type: Naming.pascal(as), optional: optional, relationship: OneOfUnion::RELATIONSHIP)
          end

          def install_union_shapes(tagged, variants)
            closed_sets << union_type_set("#{tagged}Type", variants) << tagged_reference(tagged, "#{tagged}Type")
            @reference_targets.concat(variants)
          end

          def refuse_unfit_union!(variants, as)
            listed = variants.join(", ")
            raise Malformed, "#{@name}'s reference_to one_of(#{listed}) needs as: — a union has no one name" unless as
            return if variants.uniq.size == variants.size && variants.size >= 2

            raise Malformed, "#{@name}.#{as}'s one_of names #{listed} — a union names two or more distinct aggregates"
          end

          # The closed set of the variants' names, which the tagged value object's `type` admits.
          def union_type_set(name, variants)
            ValueObject.declare(name: name, attributes: [Attribute.new(name: :value, type: "String")],
                                members: variants.map { |variant| { value: variant } }, closed_set: true)
          end

          # The stored shape: which aggregate (`type`) and which of its records (`id`).
          def tagged_reference(name, type_set)
            type = Attribute.new(name: :type, type: "String", admits: "#{@name}::#{type_set}")
            ValueObject.declare(name: name, attributes: [type, Attribute.new(name: :id, type: "String")])
          end
        end
      end
    end
  end
end
