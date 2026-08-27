require "json"
require_relative "../../vocabulary"

module Hecks
  module Bluebook
    module Expression
      module CanonicalForm
        Rule = Struct.new(:strategy, :source_token, :replacement, :boundary, :position, keyword_init: true)

        STRATEGIES = Hecks::Vocabulary.fetch("NormalisationStrategy")

        # READ, NOT RESTATED — the admitted normalisation rules, projected
        # from the grammar chapter by bin/expression_projection exactly as
        # the evaluator's operator table is. See Evaluator::PROJECTION for
        # why a projection rather than a boot.
        RULES = JSON.parse(
          File.read(File.join(__dir__, "projection.json")), symbolize_names: true
        ).fetch(:normalisations).map { |row| Rule.new(**row) }.freeze

        module_function

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

        def apply(source)
          RULES.sort_by(&:position).reduce(source.to_s) { |text, rule| step(text, rule) }.strip
        end

        def step(text, rule)
          case rule.strategy
          when "collapse_whitespace" then map_outside_strings(text) { |segment| segment.gsub(/\s+/, " ") }
          when "replace"             then replace(text, rule)
          else
            raise ArgumentError, "#{rule.strategy.inspect} is not a linked normalisation strategy"
          end
        end

        def replace(text, rule)
          map_outside_strings(text) do |segment|
            if rule.boundary == "none"
              segment.gsub(rule.source_token, rule.replacement)
            else
              segment.gsub(/#{Regexp.escape(rule.source_token)}(?![[:alnum:]_])/, rule.replacement)
            end
          end
        end

        # Applies a normalisation rule to the text OUTSIDE quoted string
        # literals only, copying every quoted run through byte-for-byte.
        # Every rule here (collapse_whitespace, the `.length`→`.size` fold)
        # used to run quote-blind — `"a  b"` collapsed to `"a b"` and
        # `"a.length"` folded to `"a.size"` just as readily as the real
        # source outside the quotes, silently rewriting what a predicate
        # compares a string attribute against, not merely how the
        # predicate itself is spelled. A canonical string literal's
        # CONTENTS are data, never syntax to normalise.
        #
        # Handles both `"` and `'` delimiters (this grammar's own
        # `Resolver.quoted?` admits either), quote-aware exactly the way
        # `Evaluator.top_level_index`/`Resolver.array_elements` already are
        # elsewhere in this sublanguage. An unterminated quote (malformed
        # input) is passed through raw rather than risk mangling it further.
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
              # (`String#+@` only dups a FROZEN receiver; `each_char`'s
              # yielded strings aren't frozen, so `+char` is just as
              # much a no-op here). Without a REAL copy, `buffer` and
              # `quote` alias the same mutable object: the very next
              # `buffer << char` grows `quote` right along with it, so
              # `char == quote` can only ever compare a single character
              # against an ever-lengthening string and never closes the
              # literal — everything after a predicate's first quoted
              # string silently skipped normalisation for the rest of
              # the text, undetected because passing text through
              # unnormalised is silent.
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
