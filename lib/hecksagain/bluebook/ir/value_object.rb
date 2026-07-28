module Hecksagain
  module Bluebook
    module IR
      Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      class ValueObject
        attr_reader :name, :attributes, :invariants, :members

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
