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
  module Bluebook
    module IR
      # description — the human sentence from the bluebook ("amount must be positive")
      # canonical   — the expression as text ("amount > 0"), extracted from the
      #               real Ruby. The evaluated form, in every runtime.
      # predicate   — the original block, kept for reference, never evaluated.
      Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      class ValueObject
        attr_reader :name, :attributes, :invariants, :members

        # members — the CLOSED SET this value may take, when one is declared
        #           (`one_of do member ... end`). Each is an ordered list of
        #           [field, value] pairs, declaration order preserved,
        #           because that is the order the Rust parser carries and a
        #           reordered member would diff as a change that is not one.
        #           Empty means open : any value the invariants admit.
        def initialize(name:, attributes: [], invariants: [], members: [])
          @name       = name.to_s
          @attributes = attributes
          @invariants = invariants
          @members    = members
        end

        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }

        def to_h
          {
            name:       @name,
            attributes: @attributes.map(&:to_h),
            invariants: @invariants.map { |i| { description: i.description, canonical: i.canonical } },
            members:    @members.map { |m| m.map { |field, value| [field.to_s, value.to_s] } }
          }
        end
      end
    end
  end
end
