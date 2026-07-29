module Hecksagain
  module Bluebook
    module DSL
      class ValueObjectBuilder
        include AttributeCollector

        def initialize(name)
          @name       = name
          @invariants = []
          @members    = []
        end

        # moved to the language: a closed set admits a member, on Shape.Close.
        #
        # This was called unportable because an empty one_of and no one_of are
        # both `members: []` in the IR. That was a MODELLING choice, not a law —
        # an empty attribute NAME survives into the IR and is judged there. So
        # the IR now records that a closed set was declared, and the language
        # judges it like everything else.
        def one_of(&block)
          @closed_set = true
          instance_eval(&block) if block
        end

        def member(**fields)
          raise Malformed, "#{@name} declared an empty member" if fields.empty?

          @members << fields
        end

        def invariant(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # moved to the language: given "a rule says what it means", on Shape.Assert

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s invariant #{description.inspect} did not survive " \
                  "extraction — it would be a rule no other runtime could read"
          end

          @invariants << IR::Invariant.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        def build
          IR::ValueObject.declare(
            name: @name, attributes: attributes,
            invariants: @invariants, members: @members,
            closed_set: @closed_set || !@members.empty?
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
