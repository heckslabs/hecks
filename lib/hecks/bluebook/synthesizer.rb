module Hecks
  module Bluebook
    # **One synthesized argument per declared attribute** — never a random
    # guess. Reads only real `IR` (`Aggregate`, `Command`,
    # `Attribute`, `ValueObject`), so it works against any
    # loaded bluebook, not one particular domain: a String becomes a
    # fixed marker; an Integer becomes 0; a closed set uses its own
    # first admitted member (never a value a real `one_of` would
    # legitimately refuse); a reference uses whatever id the caller
    # already knows for that target (`created`), so a command whose
    # own shape depends on an earlier-created record — a `TripItem`
    # needing a real `PackingItem`, say — gets something real to work
    # with instead of a guess that would only ever fail.
    #
    # Extracted from `bin/interview`'s own smoke test, where this first
    # got built and proved — the logic never actually knew anything
    # about the Interview domain or any one app; it only ever read IR.
    module Synthesizer
      # The only type names that are ever truly scalar — anything else
      # a value object's own field names is another value object,
      # nested (`Pizza.price_cents: Price`, itself wrapping `cents:
      # Integer` — a real, ordinary shape, not an edge case). Missing
      # this the first time round meant a nested field silently
      # synthesized as the bare string `"smoke-test"` instead of the
      # real nested structure a command actually declares — caught
      # only by testing against Pizzas instead of re-testing against
      # the one simpler domain this was first built for, where every
      # value object happened to be single-field and primitive-typed.
      # The same list `Attribute::PRIMITIVES` holds, referenced rather
      # than repeated. It was a second, byte-identical copy — and only
      # the Attribute one is held to `vocabulary.bluebook` by
      # spec/vocabulary_conformance_spec, so this copy could drift from
      # the language and nothing would say so.
      PRIMITIVES = Attribute::PRIMITIVES

      module_function

      # `chapter`/`aggregate` are the real `Bluebook`/`Aggregate`
      # the command belongs to — needed to resolve a value object type
      # name back to its own declared shape. `created` maps an
      # aggregate name to a real id already minted for it earlier in
      # the same run; a reference whose target isn't in there yet gets
      # a placeholder instead of failing outright, since the caller may
      # not care about that particular argument's real value.
      #
      # @param chapter [Bluebook::Chapter] the chapter the command's aggregate
      #   belongs to, needed to resolve a value object type name back to its
      #   own declared shape
      # @param aggregate [Bluebook::Aggregate] the aggregate `command` belongs to
      # @param command [Class] the command class (a `Bluebook::Command`
      #   subclass) to synthesize arguments for
      # @param created [Hash{String => Object}] aggregate name mapped to a real
      #   id already minted for it earlier in this same run
      # @return [Hash{Symbol => Object}] one synthesized value per declared
      #   attribute, keyed by attribute name
      def args_for(chapter, aggregate, command, created = {})
        command.attributes.to_h do |attribute|
          if attribute.reference?
            [attribute.name, created.fetch(attribute.type.target_name, "smoke-test-id")]
          else
            [attribute.name, value_for(chapter, aggregate, attribute.type)]
          end
        end
      end

      # A value object's own synthesized value — its first admitted
      # member if it's a closed set (the one value guaranteed not to be
      # refused), otherwise one synthesized scalar per declared field.
      # Falls back to searching every aggregate in the chapter, the
      # same tolerance `bin/interview shape`'s own lookup already
      # needed: a value object referenced by name doesn't have to be
      # declared on the same aggregate using it.
      #
      # @param chapter [Bluebook::Chapter] the chapter to search when
      #   `type_name` is not declared on `aggregate` itself
      # @param aggregate [Bluebook::Aggregate] the aggregate `type_name` is
      #   looked up on first
      # @param type_name [String] the value object's declared type name
      # @return [String, Hash{Symbol => Object}] the string `"smoke-test"` when
      #   no such value object is declared; otherwise a Hash of one value per
      #   field — the closed set's own first admitted member's fields, or one
      #   freshly synthesized scalar per declared field
      def value_for(chapter, aggregate, type_name)
        value_object = aggregate.value_object(type_name) ||
                       chapter.aggregates.filter_map { |a| a.value_object(type_name) }.first
        return "smoke-test" unless value_object

        closed_set = value_object.respond_to?(:closed_set?) && value_object.closed_set? && value_object.members.any?
        return value_object.members.first.to_h if closed_set

        value_object.attributes.to_h { |field| [field.name, field_value_for(chapter, aggregate, field.type)] }
      end

      # A single field's own synthesized value — a plain scalar if its
      # type is one of the true primitives, otherwise that type names
      # another value object, resolved the identical way `value_for`
      # resolves any other one (its own closed set or its own nested
      # fields, however deep that nesting actually goes).
      #
      # @param chapter [Bluebook::Chapter] see `value_for`
      # @param aggregate [Bluebook::Aggregate] see `value_for`
      # @param type_name [String] the field's declared type name
      # @return [Integer, Float, true, false, String, Hash{Symbol => Object}] a
      #   bare scalar when `type_name` is a true primitive (see `scalar_for`),
      #   otherwise `value_for`'s own result for the nested value object it names
      def field_value_for(chapter, aggregate, type_name)
        PRIMITIVES.include?(type_name.to_s) ? scalar_for(type_name) : value_for(chapter, aggregate, type_name)
      end

      # A bare primitive's own synthesized value. Never used for a
      # closed set's own field (that's `value_for`'s job, reading the
      # set's real first member) — only for a plain scalar field with
      # no declared vocabulary to respect.
      #
      # @param primitive [String, Symbol] the primitive type name, such as
      #   `"Integer"` or `"String"`
      # @return [Integer, Float, false, String] `0` for `"Integer"`, `0.0` for
      #   `"Float"`, `false` for `"TrueClass"`/`"FalseClass"`, or the string
      #   `"smoke-test"` for anything else
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
