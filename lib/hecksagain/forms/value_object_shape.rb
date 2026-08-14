module Hecksagain
  module Forms
    # THE VALUE-OBJECT CLASSIFICATION every consumer of a resolved VO
    # shape needs, spelled once — `field_shape.rb` (a command's own
    # form), `ui_schema.rb` (embryonaut_console's table/detail-panel
    # renderer, a separate app, not this repo), and
    # `adapters/driven/sql_query_builder.rb` (a query's own ORDER BY/
    # WHERE compiler) each grew their own copy of "is this VO money-
    # shaped," "does it have exactly one attribute, worth unwrapping,"
    # and "which member of it is numeric" — the same three questions,
    # answered identically by definition (a VO's shape doesn't change
    # depending on who's asking), so a fix to one copy was never
    # guaranteed to reach the others.
    module ValueObjectShape
      module_function

      # `Price{cents:, currency:}`/`ContractValue{cents:, currency:}` —
      # every money-shaped VO in the corpus spells it exactly this way,
      # the two-attribute convention the language itself never enforces
      # but every real chapter follows.
      def money?(value_object)
        value_object.attributes.map { |a| a.name.to_s }.sort == %w[cents currency]
      end

      # A VO with exactly one attribute is a NAME for a scalar, not a
      # genuine group (EmailAddress{address}, CustomerNumber{value}) —
      # [[feedback_name_the_scalar_field]]'s own reasoning, shared here
      # rather than re-decided per caller. Returns the sole attribute,
      # or nil for anything else.
      def sole_attribute(value_object)
        return nil unless value_object.attributes.size == 1

        value_object.attributes.first
      end

      # The first Integer/Float member, or nil — what a numeric
      # comparison or an ORDER BY compiles against when the VO isn't
      # money-shaped (money's own two members are handled by `money?`
      # instead, since which one governs ordering is a money-specific
      # decision, not a general "pick the first number" one).
      def numeric_member(value_object)
        value_object.attributes.find { |a| %w[Integer Float].include?(a.type.to_s) }
      end
    end
  end
end
