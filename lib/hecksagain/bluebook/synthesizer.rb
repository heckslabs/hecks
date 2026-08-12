module Hecksagain
  module Bluebook
    # ONE SYNTHESIZED ARGUMENT PER DECLARED ATTRIBUTE — never a random
    # guess. Reads only real `IR` (`Aggregate`, `Command`,
    # `Attribute`, `ValueObject`), so it works against ANY
    # loaded bluebook, not one particular domain: a String becomes a
    # fixed marker; an Integer becomes 0; a closed set uses ITS OWN
    # first admitted member (never a value a real `one_of` would
    # legitimately refuse); a reference uses whatever id the CALLER
    # already knows for that target (`created`), so a command whose
    # own shape depends on an earlier-created record — a `TripItem`
    # needing a real `PackingItem`, say — gets something real to work
    # with instead of a guess that would only ever fail.
    #
    # Extracted from `bin/interview`'s own smoke test, where this first
    # got built and proved — the logic never actually knew anything
    # about the Interview domain or any one app; it only ever read IR.
    module Synthesizer
      # THE ONLY TYPE NAMES THAT ARE EVER TRULY SCALAR — anything else
      # a value object's own field names is ANOTHER value object,
      # nested (`Pizza.price_cents: Price`, itself wrapping `cents:
      # Integer` — a real, ordinary shape, not an edge case). Missing
      # this the first time round meant a nested field silently
      # synthesized as the bare string `"smoke-test"` instead of the
      # real nested structure a command actually declares — caught
      # only by testing against Pizzas instead of re-testing against
      # the one simpler domain this was first built for, where every
      # value object happened to be single-field and primitive-typed.
      PRIMITIVES = %w[String Integer Float TrueClass FalseClass].freeze

      module_function

      # `chapter`/`aggregate` are the real `Bluebook`/`Aggregate`
      # the command belongs to — needed to resolve a value object type
      # name back to its own declared shape. `created` maps an
      # aggregate NAME to a real id already minted for it earlier in
      # the same run; a reference whose target isn't in there yet gets
      # a placeholder instead of failing outright, since the caller may
      # not care about that particular argument's real value.
      def args_for(chapter, aggregate, command, created = {})
        command.attributes.to_h do |attribute|
          if attribute.reference?
            [attribute.name, created.fetch(attribute.type.target_name, "smoke-test-id")]
          else
            [attribute.name, value_for(chapter, aggregate, attribute.type)]
          end
        end
      end

      # A value object's OWN synthesized value — its first admitted
      # member if it's a closed set (the one value guaranteed not to be
      # refused), otherwise one synthesized scalar per declared field.
      # Falls back to searching every aggregate in the chapter, the
      # same tolerance `bin/interview shape`'s own lookup already
      # needed: a value object referenced by name doesn't have to be
      # declared on the SAME aggregate using it.
      def value_for(chapter, aggregate, type_name)
        value_object = aggregate.value_object(type_name) ||
                       chapter.aggregates.filter_map { |a| a.value_object(type_name) }.first
        return "smoke-test" unless value_object

        if value_object.respond_to?(:closed_set?) && value_object.closed_set? && value_object.members.any?
          return value_object.members.first.to_h
        end

        value_object.attributes.to_h { |field| [field.name, field_value_for(chapter, aggregate, field.type)] }
      end

      # A single field's own synthesized value — a plain scalar if its
      # type is one of the true primitives, otherwise that type names
      # ANOTHER value object, resolved the identical way `value_for`
      # resolves any other one (its own closed set or its own nested
      # fields, however deep that nesting actually goes).
      def field_value_for(chapter, aggregate, type_name)
        PRIMITIVES.include?(type_name.to_s) ? scalar_for(type_name) : value_for(chapter, aggregate, type_name)
      end

      # A bare primitive's own synthesized value. Never used for a
      # closed set's OWN field (that's `value_for`'s job, reading the
      # set's real first member) — only for a plain scalar field with
      # no declared vocabulary to respect.
      def scalar_for(primitive)
        case primitive.to_s
        when "Integer" then 0
        when "Float" then 0.0
        when "TrueClass", "FalseClass" then false
        else "smoke-test"
        end
      end
    end
  end
end
