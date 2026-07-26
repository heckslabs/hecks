# ValueObjectBuilder — evaluates a `value_object "Topping" do ... end` block.
#
# Invariants are captured as blocks and evaluated later against the constructed
# value, so the bluebook reads as a rule rather than as a validation call:
#
#   value_object "Topping" do
#     attribute :name,   String
#     attribute :amount, Integer
#     invariant("amount must be positive") { amount > 0 }
#   end
module Hecksagain
  module Bluebook
    module DSL
      class ValueObjectBuilder
        include AttributeCollector

        def initialize(name)
          @name       = name
          @invariants = []
        end

        def invariant(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # The rule that closed Hecks's parity hole. Its dump excluded
          # invariant EXPRESSIONS because the predicate was a Proc and its
          # source was "unrecoverable" — so an invariant could be inverted
          # while keeping its name and nothing downstream would notice.
          # Carrying `canonical` is what fixed it ; refusing an invariant that
          # has none is what keeps it fixed.
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
          IR::ValueObject.new(name: @name, attributes: attributes, invariants: @invariants)
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
