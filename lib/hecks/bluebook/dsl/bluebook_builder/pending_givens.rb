module Hecks
  module Bluebook
    module DSL
      # The chapter-wide half of a bare `given` reference: resolves every reference the
      # aggregates and entities deferred, once the chapter's files are loaded.
      class BluebookBuilder
        # The other half of a chapter-wide `given` reference — resolves every reference
        # `AggregateBuilder#pending_chapter_given` deferred, once the chapter's files are loaded.
        #
        # Mutates each placeholder `Given` in place, since it's already embedded by Ruby
        # object reference in the referencing preconditions and commands.
        #
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if a pending reference's own `description` names no
        #   precondition any aggregate in this chapter declares, is ambiguous across several
        #   aggregates with no `declared_by:` to disambiguate, or `declared_by:` names an
        #   aggregate that does not declare it
        def resolve_pending_chapter_givens!
          fill_pending(@chapter_pending_givens) { |entry| resolve_pending_chapter_given(entry) }
        end

        # The entity-scoped analogue of `#resolve_pending_chapter_givens!`, resolved
        # against `@chapter_entity_named_givens` instead.
        #
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if a pending reference's own `description` names no
        #   precondition any piece in this chapter declares, is ambiguous across several pieces
        #   with no `declared_by:` to disambiguate, or `declared_by:` names a piece that does
        #   not declare it
        def resolve_pending_chapter_entity_givens!
          fill_pending(@chapter_entity_pending_givens) { |entry| resolve_pending_chapter_entity_given(entry) }
        end

        private

        # Copies each resolved rule onto its placeholder, then empties the queue.
        def fill_pending(entries)
          entries.each do |entry|
            resolved = yield(entry)
            entry[:placeholder].description = resolved.description
            entry[:placeholder].canonical   = resolved.canonical
            entry[:placeholder].predicate   = resolved.predicate
            entry[:placeholder].ast         = resolved.ast
          end
          entries.clear
        end

        def resolve_pending_chapter_given(entry)
          candidates = RuleReference.resolve_owner_keyed(@chapter_named_givens, entry[:description])
          declarer   = entry[:declared_by]
          return candidates[declarer] || raise(Malformed, undeclared_given_message(entry)) if declarer
          return candidates.values.first if candidates.size == 1

          raise Malformed, candidates.empty? ? unknown_given_message(entry) : ambiguous_given_message(entry, candidates)
        end

        def undeclared_given_message(entry)
          "#{entry[:aggregate]}'s given #{entry[:description].inspect} names no precondition " \
            "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
            "either hasn't declared #{entry[:description].inspect}, or declared_by: named the " \
            "wrong aggregate"
        end

        def unknown_given_message(entry)
          "#{entry[:aggregate]}'s given #{entry[:description].inspect} names no precondition " \
            "any aggregate in this chapter ever declares — declare it once with a block " \
            "(some aggregate's own given(#{entry[:description].inspect}) { ... })"
        end

        def ambiguous_given_message(entry, candidates)
          "#{entry[:aggregate]}'s given #{entry[:description].inspect} is ambiguous in this " \
            "chapter — #{candidates.keys.join(", ")} each declare a DIFFERENT predicate " \
            "under this same description; name which one with declared_by: (e.g. " \
            "given(#{entry[:description].inspect}, declared_by: #{candidates.keys.first}))"
        end

        def resolve_pending_chapter_entity_given(entry)
          candidates = RuleReference.resolve_owner_keyed(@chapter_entity_named_givens, entry[:description])
          declarer   = entry[:declared_by]
          return candidates[declarer] || raise(Malformed, undeclared_entity_given_message(entry)) if declarer
          return candidates.values.first if candidates.size == 1

          raise Malformed,
                candidates.empty? ? unknown_entity_given_message(entry) : ambiguous_entity_given_message(entry, candidates)
        end

        def undeclared_entity_given_message(entry)
          "#{entry[:entity]}'s given #{entry[:description].inspect} names no precondition " \
            "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
            "either hasn't declared #{entry[:description].inspect}, or declared_by: named the " \
            "wrong piece"
        end

        def unknown_entity_given_message(entry)
          "#{entry[:entity]}'s given #{entry[:description].inspect} names no precondition " \
            "any piece in this chapter ever declares — declare it once with a block " \
            "(some piece's own given(#{entry[:description].inspect}) { ... })"
        end

        def ambiguous_entity_given_message(entry, candidates)
          "#{entry[:entity]}'s given #{entry[:description].inspect} is ambiguous across the " \
            "chapter's own pieces — #{candidates.keys.join(", ")} each declare a DIFFERENT " \
            "predicate under this same description; name which one with declared_by: (e.g. " \
            "given(#{entry[:description].inspect}, declared_by: #{candidates.keys.first.inspect}))"
        end
      end
    end
  end
end
