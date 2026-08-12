module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A VALUE OBJECT DOES. EXTENDED, not included — a value object
      # is a CLASS (`Class.new(self)`, one per declared shape), so its
      # behaviour is singleton behaviour, and the holding half's `absorb`
      # is what a generated constructor would be.
      module ValueObject
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
