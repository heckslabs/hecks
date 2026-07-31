module Hecksagain
  module Bluebook
    module DSL
      module AttributeCollector
        ListOf = Struct.new(:type)
        OneOf  = Struct.new(:values)

        def attributes = @attributes ||= []

        # Value objects synthesised from inline closed sets, collected here and
        # installed by whoever owns value objects (the aggregate).
        def closed_sets = @closed_sets ||= []

        def attribute(name, type = String, default: nil, optional: false, pattern: nil)
          # moved to the language: FieldName invariant, on Root.Attribute

          refuse_unshared_pattern(name, pattern) if pattern

          type = synthesise_closed_set(name, type) if type.is_a?(OneOf)
          list = type.is_a?(ListOf)
          attributes << IR::Attribute.new(
            name:     name,
            type:     list ? type.type : type,
            list:     list,
            default:  default,
            optional: optional,
            pattern:  pattern
          )
        end

        def list_of(type) = ListOf.new(type)

        # A closed set declared INLINE on the attribute:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Desugars to a value object named for the attribute, so it goes through
        # exactly the machinery a hand-written one_of does — and so the
        # attribute's type is still a DECLARED value object, which is now a
        # structural rule rather than a predicate.
        #
        # Rust parsed this spelling already and threw the values away: the
        # attribute became a plain String and the closed set meant nothing, in a
        # construct that looked supported. Both runtimes desugar identically now,
        # or the same bluebook yields two different IRs.
        def one_of(*values) = OneOf.new(values)

        private

        # A pattern is refused AT DECLARATION, not when a value first meets it :
        # a regex the two engines read differently is a defect in the bluebook,
        # and a bluebook that loads is one whose patterns both runtimes agree
        # about. PatternSubset says which those are, and why each is refused.
        def refuse_unshared_pattern(name, pattern)
          rejection = PatternSubset.validate(pattern)
          return unless rejection

          raise Malformed,
                "#{name}'s pattern #{pattern.inspect} uses a #{rejection.construct} — " \
                "#{rejection.reason}"
        end

        def synthesise_closed_set(name, one_of)
          type = Naming.pascal(name)
          closed_sets << IR::ValueObject.declare(
            name:       type,
            attributes: [IR::Attribute.new(name: :value, type: "String")],
            members:    one_of.values.map { |value| { value: value.to_s } },
            closed_set: true
          )
          type
        end
      end
    end
  end
end
