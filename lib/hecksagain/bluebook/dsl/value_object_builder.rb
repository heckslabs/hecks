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

          raise Malformed, "#{@name} has an invariant with no description" if description.to_s.empty?

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
