module Hecks
  module Bluebook
    module DSL
      class EntityBuilder
        # The rule words of a piece: `given` preconditions, shared across the chapter by
        # description, and per-instance `invariant`s.
        module Rules
          # Declares a rule this piece's own commands must satisfy, or references one a sibling
          # piece anywhere in the chapter already declared.
          #
          # Order doesn't matter: `command` only queues a descriptor here and builds for real at
          # `#drain_pending!` time, after every `given` in this block has already run.
          #
          # @param description [String] the rule's description
          # @param declared_by [String, nil] which piece declares a referenced rule
          # @yield the predicate body; omitted to reference a rule by description
          # @return [Object] the rule recorded or referenced
          # @raise [Bluebook::DSL::Malformed] if the rule's source cannot be extracted, or a
          #   reference is ambiguous
          def given_impl(description, declared_by: nil, &predicate)
            return reference_named_chapter_entity_given(description, declared_by: declared_by) unless predicate

            named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                                extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
            @named_givens[description] = named
            # First-declared-wins (`||=`): a second piece under the same aggregate declaring
            # the exact same description independently stays local, never silently overwritten.
            @owner_named_givens[description] ||= named
            # Chapter-wide analogue of the line above, keyed by "Aggregate.Entity" rather than
            # description alone, so two different pieces sharing a description stay distinct
            # candidates a later bare reference chooses between via `declared_by:`.
            @chapter_entity_named_givens[description] ||= {}
            @chapter_entity_named_givens[description]["#{@aggregate_name}.#{@name}"] ||= named
          end

          # Declares a rule every instance of this piece must satisfy — checked per instance,
          # not once against the aggregate's own flat state. No reference-by-name form (unlike
          # `given`); extend that pattern here if cross-piece sharing is ever needed.
          #
          # @param description [String] the rule's description
          # @yield the predicate body; evaluated for its extracted source, never called directly
          # @return [Array<Bluebook::Invariant>] every invariant declared so far
          # @raise [Bluebook::DSL::Malformed] if the block's source cannot be extracted
          def invariant_impl(description, &predicate)
            @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                       extraction_failure: "it would be a rule the IR cannot carry")
          end

          private

          # Resolves a bare `given` reference against the chapter-wide, entity-scoped pool.
          # Also writes through to `@owner_named_givens`, not just `@named_givens` — otherwise a
          # sibling piece's own same-aggregate bare reference would never see this resolution.
          def reference_named_chapter_entity_given(description, declared_by:)
            verify_resolves_via!("given", "Entity", "owner_keyed")
            candidates = resolve_owner_keyed(@chapter_entity_named_givens, description)

            named = pick_entity_given(candidates, description, declared_by)
            @named_givens[description] = named
            @owner_named_givens[description] ||= named
          end

          def pick_entity_given(candidates, description, declared_by)
            return declared_entity_given(candidates, description, declared_by) if declared_by
            return candidates.values.first if candidates.size == 1
            return pending_chapter_entity_given(description, declared_by: nil) if candidates.empty?

            raise Malformed, ambiguous_entity_given_message(candidates, description)
          end

          def declared_entity_given(candidates, description, declared_by)
            candidates[declared_by] || pending_chapter_entity_given(description, declared_by: declared_by)
          end

          def ambiguous_entity_given_message(candidates, description)
            "#{@aggregate_name}::#{@name}'s given #{description.inspect} is ambiguous " \
              "across the chapter's own pieces — #{candidates.keys.join(", ")} each declare " \
              "a DIFFERENT predicate under this same description; name which one with " \
              "declared_by: (e.g. given(#{description.inspect}, declared_by: " \
              "#{candidates.keys.first.inspect}))"
          end

          # A chapter may be split across files, so an unresolved bare reference defers rather
          # than raising immediately; `BluebookBuilder#resolve_pending_chapter_entity_givens!`
          # fills in the placeholder once every file in the chapter has loaded.
          def pending_chapter_entity_given(description, declared_by:)
            placeholder = Given.new(description: description, canonical: nil, predicate: nil)
            @chapter_entity_pending_givens << { entity: "#{@aggregate_name}.#{@name}", description: description,
                                                 declared_by: declared_by, placeholder: placeholder }
            placeholder
          end
        end
      end
    end
  end
end
