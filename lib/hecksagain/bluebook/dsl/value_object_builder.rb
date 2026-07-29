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

        # NOT a language rule, and cannot become one : `one_of` without a block
        # produces no members, which is indistinguishable in the IR from having
        # no one_of at all. The artifact is well formed either way — this catches
        # a mistake in how the DSL was CALLED, which is lint, not law.
        def one_of(&block)
          unless block
            raise Malformed,
                  "#{@name} declared one_of with no block — the scalar form " \
                  "(`attribute :x, one_of(\"a\", \"b\")`) is not read on this " \
                  "side yet, and silently dropping it would be the same " \
                  "half-present construct one_of itself was"
          end

          instance_eval(&block)
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
          IR::ValueObject.new(
            name: @name, attributes: attributes,
            invariants: @invariants, members: @members
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
