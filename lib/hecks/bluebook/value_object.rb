require_relative "behaviour/value_object"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    Invariant = Struct.new(:description, :canonical, :predicate, :ast, keyword_init: true)

    # A value object: a declaration holder, never instantiated.
    # `ValueObjectBuilder` returns a subclass carrying attributes, invariants and members;
    # reach one through `aggregate.value_object(name)`.
    # `to_h` spells the short declared name (`hecks_name`), a contract pinned by golden fixtures.
    class ValueObject
      extend Construct
      # Extended, not included: this construct is a class, so emission is a class method.
      extend Hecks::IR
      extend Behaviour::ValueObject

      emits_ir(
        name:       :hecks_name,
        attributes: many(:attributes),
        # `ast` sits beside `canonical` because rust/host's mint-time invariant check
        # has no kernel crate to parse `canonical` with (see `Expression::AstJson`).
        invariants: -> { invariants.map { |rule| Expression::AstJson.rule_row(rule) } },
        closed_set: :closed_set?,
        # Only the field name is stringified: a member value can be an Integer, and
        # stringifying it would make `84` and `"84"` indistinguishable in `to_h`.
        members:    -> { members.map { |member| member.map { |field, value| [field.to_s, value] } } }
      )

      class << self
        attr_reader :attributes, :invariants, :members

        # One declared shape — a subclass rather than an instance, so the thing
        # the bluebook declares and the thing Ruby holds are one object.
        #
        # @param name [String, Symbol] the value object's declared type name
        # @param attributes [Array<Bluebook::Attribute>] the value object's declared fields
        # @param invariants [Array<Bluebook::Invariant>] the rules checked against every instance
        # @param members [Array<Hash{Symbol => Object}>] the declared `one_of` members, one
        #   row of field values per member
        # @param closed_set [Boolean] whether a `one_of` was declared, even with no
        #   members; defaults to whether `members` is non-empty
        # @return [Class] the minted shape class (a `Bluebook::ValueObject` subclass)
        def declare(name:, attributes: [], invariants: [], members: [], closed_set: !members.empty?)
          shape = Class.new(self)
          shape.hecks_name = name.to_s
          shape.absorb(attributes: attributes, invariants: invariants,
                       members: members, closed_set: closed_set)
          shape
        end

        # Assigns what the language declares onto this shape class.
        #
        # @param attributes [Array<Bluebook::Attribute>] see `declare`
        # @param invariants [Array<Bluebook::Invariant>] see `declare`
        # @param members [Array<Hash{Symbol => Object}>] see `declare`
        # @param closed_set [Boolean] see `declare`
        # @return [void]
        def absorb(attributes:, invariants:, members:, closed_set:)
          @attributes = attributes
          @invariants = invariants
          @members    = members
          @closed_set = closed_set
        end
      end
    end
  end
end
