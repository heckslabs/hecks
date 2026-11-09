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
        # What the index answers for a word no row admits under a context.
        EMPTY_ROWS = [].freeze

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
          index = WordGate.index_for(keywords)
          name = word.to_s
          admitted = index.fetch([context, name], EMPTY_ROWS)
          return [context, admitted] unless admitted.empty?

          type_admitted = index.fetch(["Type", name], EMPTY_ROWS).select { |row| row[:word] == name }
          type_admitted.empty? ? [context, admitted] : ["Type", type_admitted]
        end

        def word_gate_row?(row, context, name)
          row[:context] == context && (row[:word] == name || row[:was] == name)
        end

        def refuse_unadmitted_word!(keywords, context, word)
          words = keywords.select { |row| row[:context] == context }.map { |row| row[:word] }
          legal = words.uniq.sort
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

          dispatched = GenericDispatch.try(self, context, word.to_s, GenericDispatch::Invocation.new(args, kwargs, block), rows)
          return dispatched unless dispatched.equal?(GenericDispatch::NOT_HANDLED)

          raise Malformed,
                "'#{word}' is admitted by #{context}'s own grammar, but #{self.class} has no " \
                "builder method for it yet — not yet implemented"
        end

        def respond_to_missing?(word, include_private = false)
          return super if MetaValidator.bootstrapping?

          _, admitted = word_gate_admitted(MetaValidator::SyntaxBoot.call[:keywords], self.class::GRAMMAR_CONTEXT, word)
          !admitted.empty? || super
        end

        # `method_missing` fires for every typo in a builder, so only words the grammar knows
        # anywhere get the rich refusal; other typos keep Ruby's ordinary `NoMethodError`.
        def admitted_anywhere?(rows, word)
          WordGate.words_of(rows).key?(word.to_s)
        end

        # The grammar table, indexed once. A bluebook speaks thousands of words as it loads, and
        # the table (`SyntaxBoot.call`) is one memoized array, so its identity names the index.
        #
        # @api private
        class << self
          # Every row admitting a word under a context: `[context, word]` and, where a row keeps
          # an older spelling, `[context, was]`, each to the rows in table order.
          #
          # @param keywords [Array<Hash>] the `:keywords` rows of the grammar table
          # @return [Hash{Array(String, String) => Array<Hash>}]
          def index_for(keywords)
            return @index if @index_keywords.equal?(keywords)

            index = Hash.new { |rows, key| rows[key] = [] }
            keywords.each do |row|
              index[[row[:context], row[:word]]] << row
              index[[row[:context], row[:was]]] << row if row[:was] && row[:was] != row[:word]
            end
            index.default_proc = nil
            @index_keywords = keywords
            @words = nil
            @index = index.freeze
          end

          # Every word or older spelling the table knows anywhere, as hash keys.
          #
          # @param keywords [Array<Hash>] the `:keywords` rows of the grammar table
          # @return [Hash{String => true}]
          def words_of(keywords)
            index_for(keywords)
            @words ||= keywords.each_with_object({}) do |row, words|
              words[row[:word]] = true
              words[row[:was]] = true if row[:was]
            end.freeze
          end
        end
      end
    end
  end
end
