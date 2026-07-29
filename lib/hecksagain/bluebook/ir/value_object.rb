module Hecksagain
  module Bluebook
    module IR
      Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      # A value object, as a RUBY CLASS.
      #
      # `ValueObjectBuilder` used to return an instance of this — a parallel data
      # model describing a shape Ruby is perfectly capable of BEING. It returns a
      # subclass now, so `Pizzas::Pizza::Price` is a real constant nested where
      # the bluebook nests it, and the declaration lives on its singleton.
      #
      # What that buys is one lookup fewer. `Value.for_attribute` asked
      # `aggregate.value_object(attribute.type)` — a search by name string
      # through the aggregate's declared shapes. Once an attribute's type IS the
      # class, there is nothing to search : Ruby's constant tree is the index.
      #
      # `to_h` does not move. It is a byte-for-byte contract with the Rust parser
      # through `bin/parity`, so it keeps spelling the short declared name, which
      # is what `hecks_name` carries. CLASSES IN THE GRAPH, STRINGS IN THE EXPORT.
      class ValueObject
        extend Construct

        class << self
          attr_reader :attributes, :invariants, :members

          # One declared shape — a subclass rather than an instance, so the thing
          # the bluebook declares and the thing Ruby holds are one object.
          def declare(name:, attributes: [], invariants: [], members: [], closed_set: !members.empty?)
            shape = Class.new(self)
            shape.hecks_name = name.to_s
            shape.absorb(attributes: attributes, invariants: invariants,
                         members: members, closed_set: closed_set)
            shape
          end

          def absorb(attributes:, invariants:, members:, closed_set:)
            @attributes = attributes
            @invariants = invariants
            @members    = members
            @closed_set = closed_set
          end

          # A one_of DECLARED but left empty used to be indistinguishable from no
          # one_of at all — both are `members: []` — so the rule about it could
          # only live in the builder. Recording the declaration lets the language
          # judge it, the same way an empty attribute NAME survives into the IR
          # and is judged there.
          def closed_set? = @closed_set

          def attribute(named) = attributes.find { |held| held.name == named.to_sym }

          def to_h
            {
              name:       hecks_name,
              attributes: attributes.map(&:to_h),
              invariants: invariants.map { |rule| { description: rule.description, canonical: rule.canonical } },
              closed_set: closed_set?,
              members:    members.map { |member| member.map { |field, value| [field.to_s, value.to_s] } }
            }
          end
        end
      end
    end
  end
end
