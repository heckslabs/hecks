require_relative "generic_dispatch"
module Hecks
  module Bluebook
    module DSL
      # Checks undefined DSL words against the self-hosted grammar table, dispatching admitted ones
      # through `GenericDispatch` and refusing the rest with the table's own message.
      #
      # Each including class names its grammar row in `GRAMMAR_CONTEXT`. While the meta-domain
      # boots there is no table, so only `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` applies.
      module WordGate
        # Returned by `word_gate_dispatch` for a word no grammar row admits, so a caller with
        # its own `method_missing` can fall back to open-ended handling.
        NOT_ADMITTED = Object.new.freeze

        # Private like Object's own; public ones would appear as extra "answered words" in
        # spec/syntax_conformance_spec.rb, which walks `public_instance_methods`.

        private

        def method_missing(word, *args, **kwargs, &block)
          if MetaValidator.bootstrapping?
            key = word_gate_bootstrap_key(word)
            return send(GenericDispatch::BOOTSTRAP_CALLS_FALLBACK[key], *args, **kwargs, &block) if key

            return super
          end

          result = word_gate_dispatch(word, args, kwargs, block)
          return super if result.equal?(NOT_ADMITTED)

          result
        end

        # Own context first, then "Type", as in `word_gate_dispatch`.
        def word_gate_bootstrap_key(word)
          fallback = GenericDispatch::BOOTSTRAP_CALLS_FALLBACK
          [[self.class::GRAMMAR_CONTEXT, word.to_s], ["Type", word.to_s]].find { |key| fallback.key?(key) }
        end

        # `one_of`/`list_of` in an attribute's type position run on whichever builder is
        # evaluating, whose context is never "Type". Try "Type" only when its own context has
        # no row, so a same-named row of its own (ValueObject's `one_of`) still wins.
        #
        # Returns the context the word was admitted under and the rows admitting it.
        def word_gate_admitted(keywords, context, word)
          admitted = keywords.select { |row| word_gate_row?(row, context, word.to_s) }
          return [context, admitted] unless admitted.empty?

          type_admitted = keywords.select { |row| row[:context] == "Type" && row[:word] == word.to_s }
          type_admitted.empty? ? [context, admitted] : ["Type", type_admitted]
        end

        def word_gate_row?(row, context, name)
          row[:context] == context && (row[:word] == name || row[:was] == name)
        end

        def refuse_unadmitted_word!(keywords, context, word)
          legal = keywords.select { |row| row[:context] == context }.map { |row| row[:word] }.uniq.sort
          raise Malformed,
                "'#{word}' is not a word #{context} admits — legal words here: #{legal.join(", ")}"
        end

        # Admission then dispatch: own context, "Type" fallback, admitted-elsewhere check,
        # `GenericDispatch`. Returns `NOT_ADMITTED` for an unknown word rather than raising.
        def word_gate_dispatch(word, args, kwargs, block)
          rows = MetaValidator::SyntaxBoot.call
          keywords = rows[:keywords]
          context, admitted = word_gate_admitted(keywords, self.class::GRAMMAR_CONTEXT, word)

          return NOT_ADMITTED if admitted.empty? && !admitted_anywhere?(keywords, word)

          refuse_unadmitted_word!(keywords, context, word) if admitted.empty?

          dispatched = GenericDispatch.try(self, context, word.to_s, args, kwargs, block, rows)
          return dispatched unless dispatched.equal?(GenericDispatch::NOT_HANDLED)

          raise Malformed,
                "'#{word}' is admitted by #{context}'s own grammar, but #{self.class} has no " \
                "builder method for it yet — not yet implemented"
        end

        def respond_to_missing?(word, include_private = false)
          return super if MetaValidator.bootstrapping?

          context = self.class::GRAMMAR_CONTEXT
          keywords = MetaValidator::SyntaxBoot.call[:keywords]
          keywords.any? { |row| word_gate_row?(row, context, word.to_s) } ||
            keywords.any? { |row| row[:context] == "Type" && row[:word] == word.to_s } ||
            super
        end

        # `method_missing` fires for every typo in a builder, so only words the grammar knows
        # anywhere get the rich refusal; other typos keep Ruby's ordinary `NoMethodError`.
        def admitted_anywhere?(rows, word)
          rows.any? { |row| row[:word] == word.to_s || row[:was] == word.to_s }
        end
      end
    end
  end
end
