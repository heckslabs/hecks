# ValueObject — an immutable, identity-less domain type declared inside an
# aggregate. Its invariants are predicates evaluated against the VO's own
# fields at construction time ; a violated invariant raises before the value
# ever reaches the aggregate.
#
# VOs live INSIDE the aggregate that uses them (Hecks convention). Duplication
# across aggregates is fine ; file-top-level VOs are not a thing here.
#
#   ValueObject.new(name: "Topping", attributes: [...], invariants: [...])
module Hecksagain
  module IR
    # description — the human sentence from the bluebook ("amount must be positive")
    # predicate   — the block, instance_eval'd against the constructed value
    Invariant = Struct.new(:description, :predicate, keyword_init: true)

    class ValueObject
      attr_reader :name, :attributes, :invariants

      def initialize(name:, attributes: [], invariants: [])
        @name       = name.to_s
        @attributes = attributes
        @invariants = invariants
      end

      def attribute(named) = @attributes.find { |a| a.name == named.to_sym }

      def to_h
        {
          name:       @name,
          attributes: @attributes.map(&:to_h),
          invariants: @invariants.map(&:description)
        }
      end
    end
  end
end
