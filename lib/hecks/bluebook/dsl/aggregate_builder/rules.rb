module Hecks
  module Bluebook
    module DSL
      # The rule words of an aggregate: `given` preconditions, shared across the bluebook by
      # description, and whole-aggregate `invariant`s.
      class AggregateBuilder
        # Declares a rule this aggregate's own commands must satisfy, or references a sibling's.
        # `declared_by:` disambiguates a bare reference when two aggregates share a description.
        #
        # @param description [String] the rule's description; also its name for a sibling reference
        # @param declared_by [Module, Symbol, String, nil] which aggregate's rule; only meaningful
        #   with no block
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the source can't be extracted, or a bare reference
        #   resolves to none or more than one candidate once the bluebook has loaded
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_bluebook_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # Keyed by [description, this aggregate's name] so two aggregates sharing a
          # description are distinct candidates, never merged into one slot.
          @bluebook_named_givens[description] ||= {}
          @bluebook_named_givens[description][@name] ||= named
        end

        # Declares a rule the whole aggregate must satisfy, checked after every command, before
        # save.
        #
        # @param description [String] the rule's description
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        private

        # Unresolved (no candidate yet) doesn't raise here — a bluebook split across files
        # may still declare this precondition in a later file (see `#pending_bluebook_given`).
        def reference_named_bluebook_given(description, declared_by:)
          verify_resolves_via!("given", "Aggregate", "owner_keyed")
          candidates = resolve_owner_keyed(@bluebook_named_givens, description)

          @named_givens[description] = pick_bluebook_given(candidates, description, declared_by)
        end

        def pick_bluebook_given(candidates, description, declared_by)
          return declared_bluebook_given(candidates, description, declared_by) if declared_by
          return candidates.values.first if candidates.size == 1
          return pending_bluebook_given(description, declared_by: nil) if candidates.empty?

          raise Malformed, ambiguous_bluebook_given_message(candidates, description)
        end

        def declared_bluebook_given(candidates, description, declared_by)
          owner = Naming.demodulise(declared_by)
          candidates[owner] || pending_bluebook_given(description, declared_by: owner)
        end

        def ambiguous_bluebook_given_message(candidates, description)
          "#{@name}'s given #{description.inspect} is ambiguous in this bluebook — " \
            "#{candidates.keys.join(", ")} each declare a DIFFERENT predicate under " \
            "this same description; name which one with declared_by: (e.g. " \
            "given(#{description.inspect}, declared_by: #{candidates.keys.first}))"
        end

        # Returns a placeholder `Given`, embedded by reference in this aggregate's IR;
        # `BluebookBuilder#resolve_pending_bluebook_givens!` mutates it in place once the
        # whole bluebook loads, so every existing reference sees the resolved fields together.
        def pending_bluebook_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @bluebook_pending_givens << { aggregate: @name, description: description,
                                        declared_by: declared_by, placeholder: placeholder }
          placeholder
        end
      end
    end
  end
end
