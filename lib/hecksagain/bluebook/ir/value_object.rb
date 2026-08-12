module Hecksagain
  module Bluebook
    module IR
      Invariant = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      # A value object — a DECLARATION HOLDER, never instantiated.
      #
      # `ValueObjectBuilder` returns an anonymous subclass whose singleton
      # carries the declaration : attributes, invariants, members. Nothing ever
      # calls `.new` on one — coercion builds `Runtime::Value` wrappers, and
      # invariants run as canonical text through the Evaluator. The runtime
      # reaches a shape through `aggregate.value_object(name)`, the IR's own
      # finder ; there is no constant nesting and no second index.
      #
      # `to_h` does not move. It is a byte-for-byte contract pinned by the
      # golden fixtures, so it keeps spelling the short declared name, which
      # is what `hecks_name` carries. DECLARATIONS IN THE GRAPH, STRINGS IN THE
      # EXPORT.
      class ValueObject
        extend Construct
        # EXTENDED, not included — this construct is a class, so its
        # emission is a class method. See Hecksagain::IR's own note on
        # the two shapes.
        extend Hecksagain::IR

        emits_ir(
          name:       :hecks_name,
          attributes: many(:attributes),
          invariants: -> { invariants.map { |rule| { description: rule.description, canonical: rule.canonical } } },
          closed_set: :closed_set?,
          members:    -> { members.map { |member| member.map { |field, value| [field.to_s, value.to_s] } } }
        )

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

          # A single-attribute value object (EmailAddress{address},
          # CustomerNumber{value}) is a NAME for a scalar, not a genuine
          # group — [[feedback_name_the_scalar_field]]. Four call sites
          # already inline this exact check (`attributes.size == 1` /
          # `attributes.first`) — `presentation/field_shape.rb` (twice),
          # `adapters/driven/sql_query_builder.rb`,
          # `fuzzing/invalid_value_generator.rb` — kept as-is for now
          # (not migrated to this reader), but any NEW caller should
          # reach for this rather than add a fifth inline copy.
          def sole_attribute
            attributes.first if attributes.size == 1
          end

        end
      end
    end
  end
end
