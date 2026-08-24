module Hecks
  module Bluebook
    class Assembly
      # THE FIRST SPECIALIZER — a projection of `contracts.rb`'s `fields:` table,
      # derived from the language's own description of a category instead of
      # hand-written beside it.
      #
      # `Plan` already reads `grammar_registry` to build the judge's walk ; this
      # reads the same chapter to build the OTHER table this arc's own header
      # names as duplication — "SPELLED AS THE IR SPELLS THEM," field for field,
      # for every category simple enough to say so.
      #
      # ONE CASE, PROVEN, NOT THE WHOLE TABLE. A field this can speak for is
      # scalar and not a reference — every other field (a list, a reference, a
      # fold like Lifecycle) is exactly what `contracts.rb`'s `reads:`/`derived:`
      # exist to say, and stays hand-written until a later projection learns to
      # derive readers and folds too. Restricting the claim to what can be
      # PROVEN CORRECT — checked in spec/specializer_spec.rb against two
      # independent categories — is the same discipline `derived:` itself
      # enforces : a claim needs a kind, and this one's kind is "plain, checked."
      module Specializer
        module_function

        # `position` IS THE FIRST FOLD THIS RUNS INTO, and it is a universal
        # one : every category declares `attribute :position, Position` — for
        # the JUDGE's own walk, `order_by :position` on its `DeclaredIn` ask —
        # but no `*` constructor takes it as an argument. `contracts.rb`
        # already says so, in the language every other derived field speaks :
        # `derived: { position: :walk }`. The language says a category HAS a
        # position ; it does not say a category's OWN constructor is handed
        # one, and that second fact is exactly what `fields:` needs to answer.
        # So this is not silently special-cased — it is the one fold named
        # here because it is the one fold that is not a lucky accident of
        # Policy or Handler, but a fact true of every category this arc will
        # ever reach.
        DERIVED_EVERYWHERE = %i[position].freeze

        # S17, ADR 0026 — `Handler` is a genuine entity now, nested under
        # `ProcessManager`, so `.aggregate` alone no longer finds it —
        # it hangs off some aggregate's own `.entities` instead
        # (searched recursively, the same reason `Value::Coercion#find_
        # entity` does: a NESTED entity, like `Dispatch` inside
        # `Handler`, is not a direct child of any aggregate either).
        def construct_for(chapter, name)
          chapter.aggregate(name) || chapter.aggregates.filter_map { |a| find_entity(a, name) }.first
        end

        def find_entity(construct, name)
          construct.entities.each do |candidate|
            return candidate if candidate.hecks_name == name

            found = find_entity(candidate, name)
            return found if found
          end
          nil
        end

        def fields_for(category)
          language = construct_for(MetaValidator.grammar_registry.bluebook("Bluebook"), category.to_s)
          language.attributes.each_with_object({}) do |attribute, fields|
            next if attribute.list? || attribute.reference?
            next if DERIVED_EVERYWHERE.include?(attribute.name)

            fields[attribute.name] = [attribute.name, :plain]
          end
        end
      end
    end
  end
end
