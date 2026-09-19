module Hecks
  module Bluebook
    class Assembly
      # **The first specializer** — a projection of `contracts.rb`'s `fields:` table,
      # derived from the language's own description of a category instead of
      # hand-written beside it.
      #
      # `Plan` already reads `grammar_registry` to build the judge's walk ; this
      # reads the same chapter to build the other table this arc's own header
      # names as duplication — "spelled as the IR spells them," field for field,
      # for every category simple enough to say so.
      #
      # **One case, proven, not the whole table**. A field this can speak for is
      # scalar and not a reference — every other field (a list, a reference, a
      # fold like Lifecycle) is exactly what `contracts.rb`'s `reads:`/`derived:`
      # exist to say, and stays hand-written until a later projection learns to
      # derive readers and folds too. Restricting the claim to what can be
      # proven correct — checked in spec/specializer_spec.rb against two
      # independent categories — is the same discipline `derived:` itself
      # enforces : a claim needs a kind, and this one's kind is "plain, checked."
      module Specializer
        module_function

        # S17, ADR 0026 — `Handler` is a genuine entity now, nested under
        # `ProcessManager`, so `.aggregate` alone no longer finds it —
        # it hangs off some aggregate's own `.entities` instead
        # (searched recursively, the same reason `Value::Coercion#find_
        # entity` does: a nested entity, like `Dispatch` inside
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

        # `position` is the first fold this runs into : a category declares
        # `attribute :position, Position` — for the judge's own walk,
        # `order_by :position` on its `DeclaredIn` ask — but no `*`
        # constructor takes it as an argument. `contracts.rb` already says so,
        # in the language every other derived field speaks :
        # `derived: { position: :walk }`. The language says a category has a
        # position ; it does not say a category's own constructor is handed
        # one, and that second fact is exactly what `fields:` needs to answer.
        # So the skip reads the category's own walk claims (`Contract#walked`)
        # rather than restating `position` here — Handler, which has no
        # walk-minted position, skips nothing.
        def fields_for(category)
          language = construct_for(MetaValidator.grammar_registry.bluebook("Bluebook"), category.to_s)
          walked   = Assembly.contract(category).walked
          language.attributes.each_with_object({}) do |attribute, fields|
            next if attribute.list? || attribute.reference?
            next if walked.include?(attribute.name)

            fields[attribute.name] = [attribute.name, :plain]
          end
        end
      end
    end
  end
end
