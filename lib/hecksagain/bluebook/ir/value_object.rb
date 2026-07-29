module Hecksagain
  module Bluebook
    module IR
      Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      class ValueObject
        attr_reader :name, :attributes, :invariants, :members

        # A one_of DECLARED but left empty used to be indistinguishable from no
        # one_of at all — both are `members: []` — so the rule about it could
        # only live in the builder. Recording the declaration lets the language
        # judge it, the same way an empty attribute NAME survives into the IR
        # and is judged there.
        def closed_set? = @closed_set

        def initialize(name:, attributes: [], invariants: [], members: [], closed_set: !members.empty?)
          @name       = name.to_s
          @attributes = attributes
          @invariants = invariants
          @members    = members
          @closed_set = closed_set
        end

        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }

        def to_h
          {
            name:       @name,
            attributes: @attributes.map(&:to_h),
            invariants: @invariants.map { |i| { description: i.description, canonical: i.canonical } },
            closed_set: @closed_set,
            members:    @members.map { |m| m.map { |field, value| [field.to_s, value.to_s] } }
          }
        end
      end
    end
  end
end
