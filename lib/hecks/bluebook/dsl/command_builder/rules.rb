module Hecks
  module Bluebook
    module DSL
      # The rule words of a command: `given` preconditions and `ensures` postconditions.
      class CommandBuilder
        # Declares a precondition this command requires, or references one the owning aggregate
        # (or a sibling piece) already declared.
        #
        # No block given means "use the one already declared" rather than a fresh rule (ADR 0025).
        #
        # @param description [String] the rule's description; also the name the owning
        #   aggregate's rule is referenced by when no block is given
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if given a block whose source cannot be extracted, or
        #   given no block and the description names no precondition the owner (or a sibling
        #   piece under the same aggregate) declares
        def given_impl(description, &predicate)
          return reference_named_given(description) unless predicate

          @givens << build_rule(Given, description, predicate, owner_name: @name, word: "given",
                                 extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
        end

        # Declares a postcondition, checked against the settled record after the command's own
        # mutations apply; `old` names the pre-mutation state.
        #
        # @param description [String] the rule's description
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted
        def ensures(description, &predicate)
          @ensures << build_rule(Given, description, predicate, owner_name: @name, word: "ensures",
                                  extraction_failure: "a postcondition is carried as text, and this one has none")
        end

        private

        # Checks the command's own owner first, then — for a piece-owned command only —
        # a sibling piece's entity-level givens, since two pieces under the same
        # aggregate can share a precondition declared on just one of them.
        def reference_named_given(description)
          verify_resolves_via!("given", "Command", "hash_chain")
          named = resolve_hash_chain([@named_givens, @entity_shared_givens], description) ||
                  raise(Malformed,
                        "#{@name}'s given #{description.inspect} names no precondition " \
                        "#{@owner} declares, and no sibling piece under the same " \
                        "aggregate declares it either — declare it once with a block " \
                        "(#{@owner}'s own given(#{description.inspect}) { ... }), before " \
                        "the commands that reference it")

          @givens << named
        end
      end
    end
  end
end
