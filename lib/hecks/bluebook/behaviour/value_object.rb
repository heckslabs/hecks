module Hecks
  module Bluebook
    module Behaviour
      # What a value object does. Extended, not included — a value object
      # is a class (`Class.new(self)`, one per declared shape), so its
      # behaviour is singleton behaviour, and the holding half's `absorb`
      # is what a generated constructor would be.
      module ValueObject
        # A one_of declared but left empty used to be indistinguishable from no
        # one_of at all — both are `members: []` — so the rule about it could
        # only live in the builder. Recording the declaration lets the language
        # judge it, the same way an empty attribute name survives into the IR
        # and is judged there.
        def closed_set? = @closed_set

        def attribute(named) = attributes.find { |held| held.name == named.to_sym }

        # A single-attribute value object (EmailAddress{address},
        # CustomerNumber{value}) is a name for a scalar, not a genuine
        # group — [[feedback_name_the_scalar_field]]. `adapters/driven/
        # sql_query_builder.rb` and `fuzzing/invalid_value_generator.rb`
        # now read through this rather than inlining the check.
        #
        # `forms/field_shape.rb`'s own two `attributes.first.name` sites
        # (`closed_set_options`/`closed_set_field`) look identical but are
        # not the same question — they pick a closed set's discriminant
        # column, and a closed set can be genuinely multi-attribute
        # (`Runtime::Value::Admission#member_matches?`'s own comment
        # names a real one: `StatementFrequency`'s `cadence`/
        # `retention_months`/`paper_fee_cents`). `sole_attribute` would
        # return `nil` for that shape and break the discriminant lookup —
        # left as `.first` on purpose, not a missed migration.
        def sole_attribute
          attributes.first if attributes.size == 1
        end
      end
    end
  end
end
