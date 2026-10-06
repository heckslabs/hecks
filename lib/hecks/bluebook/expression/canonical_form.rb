require "json"
require_relative "../../vocabulary"

module Hecks
  module Bluebook
    module Expression
      # Rewrites predicate source into one canonical spelling (whitespace, admitted synonyms)
      # so equivalent predicates compare and hash alike. Quoted string literals are left alone.
      module CanonicalForm
        Rule = Struct.new(:strategy, :source_token, :replacement, :boundary, :position, keyword_init: true)

        STRATEGIES = Hecks::Vocabulary.fetch("NormalisationStrategy")

        # Normalisation rules projected from the grammar chapter by hecks project_expression_tables.
        RULES = JSON.parse(
          File.read(File.join(__dir__, "projection.json")), symbolize_names: true
        ).fetch(:normalisations).map { |row| Rule.new(**row) }.freeze

        module_function

        # The normalisation rules as plain Hashes, in `position` order, for a read-back contract.
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

        # Applies every `RULES` entry to `source` in `position` order; returns the stripped result.
        def apply(source)
          RULES.sort_by(&:position).reduce(source.to_s) { |text, rule| step(text, rule) }.strip
        end

        def step(text, rule)
          case rule.strategy
          when "collapse_whitespace" then map_outside_strings(text) { |segment| segment.gsub(/\s+/, " ") }
          when "replace"             then replace(text, rule)
          when "scale_call"          then scale_call(text, rule)
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

        # Folds a duration written as a call on a whole number into seconds: `days(730)` becomes
        # `63072000` when the rule's token is `days` and its replacement `86400`. A call on anything
        # but a literal whole number is left as written, and a method call (`x.days(3)`) is not a
        # duration.
        def scale_call(text, rule)
          call = /(?<![[:alnum:]_.])#{Regexp.escape(rule.source_token)}\(\s*(\d+)\s*\)/
          map_outside_strings(text) do |segment|
            segment.gsub(call) { (Regexp.last_match(1).to_i * rule.replacement.to_i).to_s }
          end
        end

        # One run of a predicate: a closed quoted literal, an unterminated one (to the end), or
        # the unquoted text between them.
        RUNS = /"[^"]*"|'[^']*'|["'].*\z|[^"']+/m
        private_constant :RUNS

        # Yields each run of `text` outside quoted literals, copying quoted runs through verbatim.
        # Quote-blind rewriting would change what a predicate compares a string against.
        # Handles `"` and `'`; an unterminated quote is passed through raw.
        def map_outside_strings(text)
          text.scan(RUNS).map { |run| run.start_with?('"', "'") ? run : yield(run) }.join
        end
      end
    end
  end
end
