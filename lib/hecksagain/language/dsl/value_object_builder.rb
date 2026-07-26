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
  module Language
    module DSL
      class ValueObjectBuilder
        include AttributeCollector

        def initialize(name)
          @name       = name
          @invariants = []
        end

        def invariant(description, &predicate)
          @invariants << IR::Invariant.new(
            description: description,
            canonical:   Expression::Extractor.canonical(predicate),
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
