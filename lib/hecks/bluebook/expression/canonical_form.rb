require "json"
require_relative "../../vocabulary"

module Hecks
  module Bluebook
    module Expression
      # Rewrites a predicate's source text into one canonical spelling
      # before it's ever parsed or hashed — collapsing whitespace and
      # folding admitted synonyms (e.g. `.length` → `.size`) via the
      # `RULES` table projected from the grammar chapter, so two byte-
      # different but equivalent predicates compare and cache identically.
      # Never touches text inside quoted string literals
      # (`map_outside_strings`).
      module CanonicalForm
        Rule = Struct.new(:strategy, :source_token, :replacement, :boundary, :position, keyword_init: true)

        STRATEGIES = Hecks::Vocabulary.fetch("NormalisationStrategy")

        # **Read, not restated** — the admitted normalisation rules, projected
        # from the grammar chapter by bin/expression_projection exactly as
        # the evaluator's operator table is. See Evaluator::PROJECTION for
        # why a projection rather than a boot.
        RULES = JSON.parse(
          File.read(File.join(__dir__, "projection.json")), symbolize_names: true
        ).fetch(:normalisations).map { |row| Rule.new(**row) }.freeze

        module_function

        # Returns the admitted normalisation rules as plain Hashes, for
        # embedding in a bluebook's read-back contract.
        #
        # @return [Array<Hash{Symbol => String}>] one hash per rule, in
        #   declared `position` order, with keys `:strategy`,
        #   `:source_token`, `:replacement`, `:boundary`, and `:position`
        #   (stringified)
        def table
          RULES.sort_by(&:position).map do |rule|
            {
              strategy:     rule.strategy,
              source_token: rule.source_token,
              replacement:  rule.replacement,
              boundary:     rule.boundary,
              position:     rule.position.to_s
            }
          end
        end

        # Rewrites `source` into its canonical spelling by applying every
        # admitted `RULES` entry, in declared `position` order.
        #
        # @param source [String] the raw predicate source to normalise
        # @return [String] the canonicalised text, stripped of leading and
        #   trailing whitespace
        def apply(source)
          RULES.sort_by(&:position).reduce(source.to_s) { |text, rule| step(text, rule) }.strip
        end

        # Applies one normalisation `rule` to `text`, dispatching on the
        # rule's strategy.
        #
        # @param text [String] the source text (or string-literal segment) to
        #   transform
        # @param rule [Rule] the normalisation rule to apply
        # @return [String] `text` after the rule is applied
        # @raise [ArgumentError] if `rule.strategy` names a strategy this
        #   method does not implement
        def step(text, rule)
          case rule.strategy
          when "collapse_whitespace" then map_outside_strings(text) { |segment| segment.gsub(/\s+/, " ") }
          when "replace"             then replace(text, rule)
          else
            raise ArgumentError, "#{rule.strategy.inspect} is not a linked normalisation strategy"
          end
        end

        # Substitutes every occurrence of `rule.source_token` in `text` with
        # `rule.replacement`, honoring the rule's word-boundary setting.
        #
        # @param text [String] the source text (or string-literal segment) to
        #   transform
        # @param rule [Rule] the `"replace"`-strategy rule supplying the
        #   token, replacement, and boundary
        # @return [String] `text` with the substitution applied
        def replace(text, rule)
          map_outside_strings(text) do |segment|
            if rule.boundary == "none"
              segment.gsub(rule.source_token, rule.replacement)
            else
              segment.gsub(/#{Regexp.escape(rule.source_token)}(?![[:alnum:]_])/, rule.replacement)
            end
          end
        end

        # Applies the given block to the text outside quoted string literals
        # only, copying every quoted run through byte-for-byte. Every rule
        # here (collapse_whitespace, the `.length`→`.size` fold) must stay
        # quote-aware: run it quote-blind and `"a  b"` collapses to `"a b"`,
        # `"a.length"` folds to `"a.size"`, just as readily as the real
        # source outside the quotes — silently rewriting what a predicate
        # compares a string attribute against, not merely how the predicate
        # itself is spelled. A canonical string literal's contents are data,
        # never syntax to normalise.
        #
        # Handles both `"` and `'` delimiters (this grammar's own
        # `Resolver.quoted?` admits either), quote-aware exactly the way
        # `Evaluator.top_level_index`/`Resolver.array_elements` already are
        # elsewhere in this sublanguage. An unterminated quote (malformed
        # input) is passed through raw rather than risk mangling it further.
        #
        # @param text [String] the source text to scan for quoted string
        #   literals
        # @yieldparam segment [String] a run of `text` outside any quoted
        #   literal
        # @yieldreturn [String] the transformed replacement for `segment`
        # @return [String] `text` with the block applied to every unquoted
        #   run, and every quoted run (`"`- or `'`-delimited) copied through
        #   unchanged
        def map_outside_strings(text)
          result = +""
          buffer = +""
          quote = nil

          text.each_char do |char|
            if quote
              buffer << char
              if char == quote
                result << buffer
                buffer = +""
                quote = nil
              end
            elsif ['"', "'"].include?(char)
              result << yield(buffer)
              # `char.dup`, not `char.to_s` (a no-op on a String — always
              # returns self, never a copy) and not `+char` either
              # (`String#+@` only dups a frozen receiver; `each_char`'s
              # yielded strings aren't frozen, so `+char` is just as
              # much a no-op here). Without a real copy, `buffer` and
              # `quote` alias the same mutable object: the very next
              # `buffer << char` grows `quote` right along with it, so
              # `char == quote` can only ever compare a single character
              # against an ever-lengthening string and never closes the
              # literal — everything after a predicate's first quoted
              # string silently skipped normalisation for the rest of
              # the text, undetected because passing text through
              # unnormalised is silent. Masked by every existing spec
              # here, which only checks that quoted contents survive
              # untouched (the M7 fix this method exists for) — that
              # still holds by accident once the bug makes the "outside"
              # branch unreachable. Found live: a multi-line `given`/
              # `ensures` block whose only quoted literal closes before a
              # later line — the newline and that later line's own
              # indentation went uncollapsed, diverging from
              # `hecks-parse`'s own (correct) single-space join.
              # `spec/parser_parity_spec.rb`, roster's "a front-row seat
              # takes a member of age".
              buffer = char.dup
              quote = char.dup
            else
              buffer << char
            end
          end

          result << (quote ? buffer : yield(buffer))
          result
        end
      end
    end
  end
end
