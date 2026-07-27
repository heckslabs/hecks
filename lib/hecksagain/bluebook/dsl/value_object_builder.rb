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
          @members    = []
        end

        # The CLOSED SET this value may take, declared as data in the
        # bluebook rather than dispatched into it later.
        #
        #   one_of do
        #     member code: "USD", symbol: "$", minor_units: 2
        #     member code: "JPY", symbol: "Y", minor_units: 0
        #   end
        #
        # A bluebook could already declare a SHAPE and not a FACT, which is
        # why the Expression chapter's own admitted operators had to live in
        # a parity script — test data standing in for language truth. The
        # Rust parser has read this block since it was lifted from Hecks ;
        # this side raised NoMethodError on it, so the construct was
        # readable by one runtime and fatal to the other. Nothing caught it
        # because no domain used it.
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

        # One member of the closed set. Keyword order is DECLARATION order,
        # and both parsers carry it that way, so the two IRs stay diffable.
        def member(**fields)
          raise Malformed, "#{@name} declared an empty member" if fields.empty?

          @members << fields
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
